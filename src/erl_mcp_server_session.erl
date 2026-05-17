-module(erl_mcp_server_session).

%% @doc false
%% MCP session state machine.
%%
%% Each client-server connection gets its own session process.
%% Tracks capabilities, pending requests, and dispatches protocol methods.
%% Use {@link erl_mcp_server_protocol} to build the handler map passed via `Opts'.

-behaviour(gen_server).

-include("erl_mcp.hrl").

-export([start_link/1, start_link/2]).
-export([handle_message/2, send_request/3, send_notification/2]).
-export([get_state/1, get_capabilities/1, promote/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    id :: binary(),
    role :: server | client,
    status = uninitialized :: uninitialized | initialized | closed,
    server_info :: undefined | #implementation{},
    client_info :: undefined | #implementation{},
    server_capabilities :: undefined | #server_capabilities{},
    client_capabilities :: undefined | #client_capabilities{},
    next_request_id = 1 :: integer(),
    pending_requests = #{} :: #{integer() => {pid(), reference()}},
    handlers :: map(),
    transport_pid :: undefined | pid(),
    progress_handlers = #{} :: #{binary() => pid()},
    in_flight = #{} :: #{reference() => {term(), integer(), reference(), pid()}},
    idle_timeout :: pos_integer(),
    idle_timer :: undefined | reference(),
    on_close :: undefined | fun((binary()) -> any())
}).

%% @doc Start an unregistered MCP session.
%%
%% `Opts' must include `role' (`server' or `client') and may include
%% `server_capabilities', `server_info', `transport_pid', and `handlers'.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% @doc Start a named MCP session.
start_link(Name, Opts) ->
    gen_server:start_link(Name, ?MODULE, Opts, []).

%% @doc Dispatch an inbound JSON-RPC message through the session.
%%
%% Returns `{reply, Term}' when the message produces a response,
%% `ok' for notifications and fire-and-forget messages, or
%% `{error, Reason}' when dispatch fails (handler error, malformed
%% message, etc.). Errors propagate through the response envelope
%% so transport-layer code can surface them as JSON-RPC errors
%% instead of crashing the session.
-spec handle_message(pid(), term()) ->
    ok | {reply, term()} | {error, term()}.
handle_message(Session, Message) ->
    gen_server:call(Session, {handle_message, Message}, 300000).

%% @doc Send an outbound JSON-RPC request to the remote peer.
%%
%% Returns `{ok, Ref}' immediately; the response arrives as
%% `{mcp_response, Ref, Result}' in the caller's mailbox.
-spec send_request(pid(), binary(), map()) ->
    {ok, reference()} | {error, term()}.
send_request(Session, Method, Params) ->
    gen_server:call(Session, {send_request, Method, Params}).

%% @doc Send a JSON-RPC notification (no response expected).
-spec send_notification(pid(), #jsonrpc_notification{}) -> ok.
send_notification(Session, Notification) ->
    gen_server:cast(Session, {send_notification, Notification}).

%% @doc Return a snapshot of session metadata (id, role, status, pending count).
-spec get_state(pid()) -> map().
get_state(Session) ->
    gen_server:call(Session, get_state).

%% @doc Return negotiated server capabilities, or error if not yet initialized.
-spec get_capabilities(pid()) -> {ok, map()} | {error, not_initialized}.
get_capabilities(Session) ->
    gen_server:call(Session, get_capabilities).

%% @doc Promote a rebuilt session to initialized status.
%%
%% Used by the session manager when restoring a persisted session.
%% Injects the client info and capabilities from the original
%% handshake so the session can accept tool calls without
%% re-initialization. Only succeeds when the session is in
%% `uninitialized' status.
-spec promote(pid(), map()) -> ok | {error, already_initialized}.
promote(Session, Meta) ->
    gen_server:call(Session, {promote, Meta}).

init(Opts) ->
    Id = maps:get(id, Opts, generate_session_id()),
    Role = maps:get(role, Opts, server),
    Handlers = maps:get(handlers, Opts, #{}),
    ServerInfo = maps:get(server_info, Opts, undefined),
    ServerCaps = maps:get(server_capabilities, Opts, undefined),
    TransportPid = maps:get(transport_pid, Opts, undefined),
    OnClose = maps:get(on_close, Opts, undefined),
    IdleTimeout = application:get_env(erl_mcp, session_idle_timeout, 1800000),
    Timer = erlang:send_after(IdleTimeout, self(), session_idle_timeout),
    {ok, #state{
        id = Id,
        role = Role,
        handlers = Handlers,
        server_info = ServerInfo,
        server_capabilities = ServerCaps,
        transport_pid = TransportPid,
        on_close = OnClose,
        idle_timeout = IdleTimeout,
        idle_timer = Timer
    }}.

handle_call({handle_message, Message}, From, State) ->
    State1 = reset_idle_timer(State),
    case dispatch(Message, From, State1) of
        {reply, Reply, NewState} ->
            {reply, {reply, Reply}, NewState};
        {noreply, NewState} ->
            {reply, ok, NewState};
        {noreply_async, NewState} ->
            {noreply, NewState};
        {error, Reason, NewState} ->
            {reply, {error, Reason}, NewState}
    end;

handle_call({send_request, Method, Params}, From, State) ->
    State0 = reset_idle_timer(State),
    Id = State0#state.next_request_id,
    Ref = make_ref(),
    Request = erl_mcp_protocol_jsonrpc:request(Id, Method, Params),
    Pending = maps:put(Id, {From, Ref}, State0#state.pending_requests),
    NewState = State0#state{
        next_request_id = Id + 1,
        pending_requests = Pending
    },
    case send_to_transport(Request, NewState) of
        ok ->
            {reply, {ok, Ref}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;

handle_call(get_state, _From, State) ->
    Info = #{
        id => State#state.id,
        role => State#state.role,
        status => State#state.status,
        pending_count => maps:size(State#state.pending_requests)
    },
    {reply, Info, State};

handle_call(get_capabilities, _From, #state{status = initialized} = State) ->
    Caps = case State#state.role of
        server -> State#state.server_capabilities;
        client -> State#state.server_capabilities
    end,
    {reply, {ok, Caps}, State};
handle_call(get_capabilities, _From, State) ->
    {reply, {error, not_initialized}, State};

handle_call({promote, Meta}, _From,
            #state{status = uninitialized} = State) ->
    ClientInfo = case maps:get(client_info, Meta, undefined) of
        undefined -> undefined;
        CI when is_map(CI) ->
            #implementation{
                name = maps:get(<<"name">>, CI, maps:get(name, CI, <<"unknown">>)),
                version = maps:get(<<"version">>, CI, maps:get(version, CI, <<"0.0.0">>))
            };
        #implementation{} = CI -> CI
    end,
    ClientCaps = case maps:get(client_capabilities, Meta, undefined) of
        undefined -> undefined;
        CC when is_map(CC) ->
            erl_mcp_protocol_capability:parse_client(CC);
        CC -> CC
    end,
    {reply, ok, State#state{
        status = initialized,
        client_info = ClientInfo,
        client_capabilities = ClientCaps
    }};
handle_call({promote, _Meta}, _From, State) ->
    {reply, {error, already_initialized}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({send_notification, Notification}, State) ->
    State1 = reset_idle_timer(State),
    send_to_transport(Notification, State1),
    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({handler_result, Ref, Result}, State) ->
    case find_in_flight_by_ref(Ref, State#state.in_flight) of
        {ok, MonRef, From, Id} ->
            demonitor(MonRef, [flush]),
            Reply = case Result of
                {ok, ResultMap} ->
                    erl_mcp_protocol_jsonrpc:response(Id, ResultMap);
                {error, Code, Msg} ->
                    erl_mcp_protocol_jsonrpc:error_response(Id, Code, Msg)
            end,
            gen_server:reply(From, {reply, Reply}),
            Remaining = maps:remove(MonRef, State#state.in_flight),
            {noreply, State#state{in_flight = Remaining}};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', MonRef, process, _Pid, normal}, State) ->
    case maps:take(MonRef, State#state.in_flight) of
        {{From, Id, _Ref, _HPid}, Remaining} ->
            Reply = erl_mcp_protocol_jsonrpc:error_response(
                Id, ?INTERNAL_ERROR, <<"Handler exited without result">>),
            gen_server:reply(From, {reply, Reply}),
            {noreply, State#state{in_flight = Remaining}};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', MonRef, process, _Pid, Reason}, State) ->
    case maps:take(MonRef, State#state.in_flight) of
        {{From, Id, _Ref, _HPid}, Remaining} ->
            ErrMsg = iolist_to_binary(io_lib:format("~p", [Reason])),
            Reply = erl_mcp_protocol_jsonrpc:error_response(
                Id, ?INTERNAL_ERROR, ErrMsg),
            gen_server:reply(From, {reply, Reply}),
            {noreply, State#state{in_flight = Remaining}};
        error ->
            {noreply, State}
    end;
handle_info(session_idle_timeout, State) ->
    {stop, {shutdown, idle_timeout}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    maps:foreach(fun(MonRef, {From, Id, _Ref, HPid}) ->
        demonitor(MonRef, [flush]),
        exit(HPid, kill),
        case From of
            {Pid, _Tag} when is_pid(Pid) ->
                ErrResp = erl_mcp_protocol_jsonrpc:error_response(
                    Id, ?INTERNAL_ERROR, <<"Session terminated">>),
                gen_server:reply(From, {reply, ErrResp});
            _ ->
                ok
        end
    end, State#state.in_flight),
    maps:foreach(fun(_Id, {Pid, _Ref}) ->
        Pid ! {mcp_error, Reason}
    end, State#state.pending_requests),
    case State#state.on_close of
        undefined -> ok;
        Fun when is_function(Fun, 1) ->
            try Fun(State#state.id)
            catch _:_ -> ok
            end
    end,
    ok.

dispatch(#jsonrpc_request{method = <<"initialize">>, params = Params, id = Id},
         _From, #state{role = server, status = uninitialized} = State) ->
    handle_initialize(Id, Params, State);

dispatch(#jsonrpc_notification{method = <<"notifications/initialized">>},
         _From, #state{role = server, status = initialized} = State) ->
    {noreply, State};

dispatch(#jsonrpc_request{method = <<"ping">>, id = Id}, _From, State) ->
    Reply = erl_mcp_protocol_jsonrpc:response(Id, #{}),
    {reply, Reply, State};

dispatch(#jsonrpc_request{method = <<"notifications/cancelled">>,
                           params = Params},
         _From, State) ->
    handle_cancellation(Params, State);

dispatch(#jsonrpc_notification{method = <<"notifications/progress">>,
                                params = Params},
         _From, State) ->
    handle_progress(Params, State);

dispatch(#jsonrpc_response{id = Id} = Resp, _From, State) ->
    handle_pending_response(Id, {ok, Resp}, State);

dispatch(#jsonrpc_error{id = Id} = Err, _From, State) ->
    handle_pending_response(Id, {error, Err}, State);

dispatch(#jsonrpc_request{method = Method, id = Id, params = Params},
         From, State) ->
    case maps:get(Method, State#state.handlers, undefined) of
        undefined ->
            ErrResp = erl_mcp_protocol_jsonrpc:error_response(
                Id, ?METHOD_NOT_FOUND, <<"Method not found">>),
            {reply, ErrResp, State};
        Handler when is_function(Handler, 2) ->
            spawn_handler(Handler, Params, From, Id, State)
    end;

dispatch(#jsonrpc_notification{}, _From, State) ->
    {noreply, State};

dispatch(_, _From, State) ->
    {error, invalid_message, State}.

spawn_handler(Handler, Params, From, Id, State) ->
    SessionPid = self(),
    Ref = make_ref(),
    Context = #{session_id => State#state.id},
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result = try Handler(Params, Context) of
            {ok, ResultMap} ->
                {ok, ResultMap};
            {ok, ResultMap, _NewState} ->
                {ok, ResultMap};
            {error, Code, Msg} ->
                {error, Code, Msg}
        catch
            error:badarg ->
                ErrMsg = iolist_to_binary(
                    io_lib:format("error:badarg", [])),
                {error, ?INTERNAL_ERROR, ErrMsg};
            error:{badkey, Key} ->
                ErrMsg = iolist_to_binary(
                    io_lib:format("error:{badkey,~p}", [Key])),
                {error, ?INTERNAL_ERROR, ErrMsg};
            error:{badmap, Val} ->
                ErrMsg = iolist_to_binary(
                    io_lib:format("error:{badmap,~p}", [Val])),
                {error, ?INTERNAL_ERROR, ErrMsg};
            error:badarith ->
                ErrMsg = iolist_to_binary(
                    io_lib:format("error:badarith", [])),
                {error, ?INTERNAL_ERROR, ErrMsg};
            Class:Reason:Stacktrace ->
                logger:error("handler exception ~p:~p~n~p",
                             [Class, Reason, Stacktrace]),
                ErrMsg = iolist_to_binary(
                    io_lib:format("~p:~p", [Class, Reason])),
                {error, ?INTERNAL_ERROR, ErrMsg}
        end,
        SessionPid ! {handler_result, Ref, Result}
    end),
    InFlight = maps:put(MonRef, {From, Id, Ref, Pid},
                        State#state.in_flight),
    {noreply_async, State#state{in_flight = InFlight}}.

handle_initialize(Id, Params, State) ->
    ClientVersion = maps:get(<<"protocolVersion">>, Params, undefined),
    ClientCapsMap = maps:get(<<"capabilities">>, Params, #{}),
    ClientInfoMap = maps:get(<<"clientInfo">>, Params, #{}),
    ClientCaps = erl_mcp_protocol_capability:parse_client(ClientCapsMap),
    ClientInfo = #implementation{
        name = maps:get(<<"name">>, ClientInfoMap, <<"unknown">>),
        version = maps:get(<<"version">>, ClientInfoMap, <<"0.0.0">>)
    },
    ServerCaps = case State#state.server_capabilities of
        undefined -> erl_mcp_protocol_capability:server_capabilities(#{});
        Caps -> Caps
    end,
    NegotiatedCaps = erl_mcp_protocol_capability:negotiate(ClientCaps, ServerCaps),
    ServerInfoMap = case State#state.server_info of
        undefined ->
            #{<<"name">> => <<"erl_mcp">>, <<"version">> => <<"0.1.0">>};
        #implementation{name = N, version = V} ->
            #{<<"name">> => N, <<"version">> => V}
    end,
    ResponseVersion = case lists:member(ClientVersion, ?MCP_SUPPORTED_VERSIONS) of
        true -> ClientVersion;
        false -> ?MCP_PROTOCOL_VERSION
    end,
    Result = #{
        <<"protocolVersion">> => ResponseVersion,
        <<"capabilities">> => erl_mcp_protocol_capability:server_to_map(NegotiatedCaps),
        <<"serverInfo">> => ServerInfoMap
    },
    Reply = erl_mcp_protocol_jsonrpc:response(Id, Result),
    NewState = State#state{
        status = initialized,
        client_capabilities = ClientCaps,
        client_info = ClientInfo,
        server_capabilities = NegotiatedCaps
    },
    notify_initialized(NewState),
    {reply, Reply, NewState}.

handle_cancellation(Params, State) ->
    RequestId = maps:get(<<"requestId">>, Params, undefined),
    _Reason = maps:get(<<"reason">>, Params, undefined),
    case maps:take(RequestId, State#state.pending_requests) of
        {{Pid, _Ref}, Remaining} ->
            Pid ! {mcp_cancelled, RequestId},
            {noreply, State#state{pending_requests = Remaining}};
        error ->
            cancel_in_flight(RequestId, State)
    end.

cancel_in_flight(RequestId, State) ->
    case find_in_flight_by_id(RequestId, State#state.in_flight) of
        {ok, MonRef, From, HPid} ->
            demonitor(MonRef, [flush]),
            exit(HPid, cancelled),
            ErrResp = erl_mcp_protocol_jsonrpc:error_response(
                RequestId, ?REQUEST_CANCELLED, <<"Request cancelled">>),
            gen_server:reply(From, {reply, ErrResp}),
            Remaining = maps:remove(MonRef, State#state.in_flight),
            {noreply, State#state{in_flight = Remaining}};
        error ->
            {noreply, State}
    end.

handle_progress(Params, State) ->
    Token = maps:get(<<"progressToken">>, Params, undefined),
    case maps:get(Token, State#state.progress_handlers, undefined) of
        undefined ->
            {noreply, State};
        Pid ->
            Pid ! {mcp_progress, Token, Params},
            {noreply, State}
    end.

handle_pending_response(Id, Result, State) ->
    case maps:take(Id, State#state.pending_requests) of
        {{Pid, Ref}, Remaining} ->
            Pid ! {mcp_response, Ref, Result},
            {noreply, State#state{pending_requests = Remaining}};
        error ->
            {noreply, State}
    end.

send_to_transport(_Message, #state{transport_pid = undefined}) ->
    {error, no_transport};
send_to_transport(Message, #state{transport_pid = Pid}) ->
    case erl_mcp_protocol_jsonrpc:encode(Message) of
        {ok, Bin} ->
            Pid ! {mcp_send, Bin},
            ok;
        {error, _} = Err ->
            Err
    end.

find_in_flight_by_ref(Ref, InFlight) ->
    Result = maps:fold(fun
        (MonRef, {From, Id, R, _Pid}, error) when R =:= Ref ->
            {ok, MonRef, From, Id};
        (_MonRef, _Val, Acc) ->
            Acc
    end, error, InFlight),
    Result.

find_in_flight_by_id(RequestId, InFlight) ->
    maps:fold(fun
        (MonRef, {From, Id, _Ref, Pid}, error) when Id =:= RequestId ->
            {ok, MonRef, From, Pid};
        (_MonRef, _Val, Acc) ->
            Acc
    end, error, InFlight).

reset_idle_timer(#state{idle_timer = OldTimer,
                        idle_timeout = Timeout} = State) ->
    case OldTimer of
        undefined -> ok;
        _ -> erlang:cancel_timer(OldTimer)
    end,
    NewTimer = erlang:send_after(Timeout, self(), session_idle_timeout),
    State#state{idle_timer = NewTimer}.

generate_session_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    base64:encode(Bytes, #{mode => urlsafe, padding => false}).

notify_initialized(#state{id = SessionId,
                          client_info = ClientInfo,
                          client_capabilities = ClientCaps}) ->
    Meta = #{client_info => format_client_info(ClientInfo),
             client_capabilities => ClientCaps},
    case whereis(erl_mcp_server_session_manager) of
        undefined ->
            ok;
        _Pid ->
            try gen_server:call(erl_mcp_server_session_manager,
                                {session_initialized, SessionId, Meta}, 5000)
            catch
                exit:{noproc, _} ->
                    logger:warning("session ~s: manager not running for "
                                   "persist", [SessionId]),
                    ok;
                exit:{timeout, _} ->
                    logger:warning("session ~s: manager timed out for "
                                   "persist", [SessionId]),
                    ok;
                exit:{shutdown, _} ->
                    ok;
                exit:{normal, _} ->
                    ok
            end
    end.

format_client_info(#implementation{name = N, version = V}) ->
    #{name => N, version => V}.
