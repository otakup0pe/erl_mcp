-module(mcp_session).
-behaviour(gen_server).

%% MCP session state machine.
%% One session per client-server connection.
%% Tracks capabilities, pending requests, and request IDs.

-include("mcp.hrl").

-export([start_link/1, start_link/2]).
-export([handle_message/2, send_request/3, send_notification/2]).
-export([get_state/1, get_capabilities/1]).

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
    %% In-flight handler processes: MonitorRef => {From, RequestId, Ref, Pid}
    in_flight = #{} :: #{reference() => {term(), integer(), reference(), pid()}}
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

start_link(Name, Opts) ->
    gen_server:start_link(Name, ?MODULE, Opts, []).

-spec handle_message(pid(), term()) -> ok | {reply, term()}.
handle_message(Session, Message) ->
    gen_server:call(Session, {handle_message, Message}, 300000).

-spec send_request(pid(), binary(), map()) ->
    {ok, reference()} | {error, term()}.
send_request(Session, Method, Params) ->
    gen_server:call(Session, {send_request, Method, Params}).

-spec send_notification(pid(), #jsonrpc_notification{}) -> ok.
send_notification(Session, Notification) ->
    gen_server:cast(Session, {send_notification, Notification}).

-spec get_state(pid()) -> map().
get_state(Session) ->
    gen_server:call(Session, get_state).

-spec get_capabilities(pid()) -> {ok, map()} | {error, not_initialized}.
get_capabilities(Session) ->
    gen_server:call(Session, get_capabilities).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init(Opts) ->
    Id = maps:get(id, Opts, generate_session_id()),
    Role = maps:get(role, Opts, server),
    Handlers = maps:get(handlers, Opts, #{}),
    ServerInfo = maps:get(server_info, Opts, undefined),
    ServerCaps = maps:get(server_capabilities, Opts, undefined),
    TransportPid = maps:get(transport_pid, Opts, undefined),
    {ok, #state{
        id = Id,
        role = Role,
        handlers = Handlers,
        server_info = ServerInfo,
        server_capabilities = ServerCaps,
        transport_pid = TransportPid
    }}.

handle_call({handle_message, Message}, From, State) ->
    case dispatch(Message, From, State) of
        {reply, Reply, NewState} ->
            {reply, {reply, Reply}, NewState};
        {noreply, NewState} ->
            {reply, ok, NewState};
        {noreply_async, NewState} ->
            %% Handler spawned async -- reply comes via handle_info
            {noreply, NewState};
        {error, Reason, NewState} ->
            {reply, {error, Reason}, NewState}
    end;

handle_call({send_request, Method, Params}, From, State) ->
    Id = State#state.next_request_id,
    Ref = make_ref(),
    Request = mcp_jsonrpc:request(Id, Method, Params),
    Pending = maps:put(Id, {From, Ref}, State#state.pending_requests),
    NewState = State#state{
        next_request_id = Id + 1,
        pending_requests = Pending
    },
    case send_to_transport(Request, NewState) of
        ok ->
            {reply, {ok, Ref}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
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

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({send_notification, Notification}, State) ->
    send_to_transport(Notification, State),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({handler_result, Ref, Result}, State) ->
    case find_in_flight_by_ref(Ref, State#state.in_flight) of
        {ok, MonRef, From, Id} ->
            demonitor(MonRef, [flush]),
            Reply = case Result of
                {ok, ResultMap} ->
                    mcp_jsonrpc:response(Id, ResultMap);
                {error, Code, Msg} ->
                    mcp_jsonrpc:error_response(Id, Code, Msg)
            end,
            gen_server:reply(From, {reply, Reply}),
            Remaining = maps:remove(MonRef, State#state.in_flight),
            {noreply, State#state{in_flight = Remaining}};
        error ->
            %% Already cancelled or unknown
            {noreply, State}
    end;
handle_info({'DOWN', MonRef, process, _Pid, normal}, State) ->
    %% Normal exit after sending result -- just clean up if still tracked
    case maps:take(MonRef, State#state.in_flight) of
        {{From, Id, _Ref, _HPid}, Remaining} ->
            Reply = mcp_jsonrpc:error_response(
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
            Reply = mcp_jsonrpc:error_response(
                Id, ?INTERNAL_ERROR, ErrMsg),
            gen_server:reply(From, {reply, Reply}),
            {noreply, State#state{in_flight = Remaining}};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Message dispatch
%%--------------------------------------------------------------------

dispatch(#jsonrpc_request{method = <<"initialize">>, params = Params, id = Id},
         _From, #state{role = server, status = uninitialized} = State) ->
    handle_initialize(Id, Params, State);

dispatch(#jsonrpc_notification{method = <<"notifications/initialized">>},
         _From, #state{role = server, status = initialized} = State) ->
    %% Client confirmed initialization. Session is fully ready.
    {noreply, State};

dispatch(#jsonrpc_request{method = <<"ping">>, id = Id}, _From, State) ->
    Reply = mcp_jsonrpc:response(Id, #{}),
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
            ErrResp = mcp_jsonrpc:error_response(
                Id, ?METHOD_NOT_FOUND, <<"Method not found">>),
            {reply, ErrResp, State};
        Handler when is_function(Handler, 2) ->
            spawn_handler(Handler, Params, From, Id, State)
    end;

dispatch(#jsonrpc_notification{}, _From, State) ->
    %% Unknown notifications are silently ignored per spec
    {noreply, State};

dispatch(_, _From, State) ->
    {error, invalid_message, State}.

%%--------------------------------------------------------------------
%% Async handler execution
%%--------------------------------------------------------------------

spawn_handler(Handler, Params, From, Id, State) ->
    SessionPid = self(),
    Ref = make_ref(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        %% Handler is a protocol-level fun (e.g. handle_tools_call)
        %% that already returns {ok, Map} | {error, Code, Msg}
        %% and has its own try/catch for tool-level crashes.
        Result = try Handler(Params, State) of
            {ok, ResultMap} ->
                {ok, ResultMap};
            {ok, ResultMap, _NewState} ->
                {ok, ResultMap};
            {error, Code, Msg} ->
                {error, Code, Msg}
        catch
            _:Reason ->
                ErrMsg = iolist_to_binary(
                    io_lib:format("~p", [Reason])),
                {error, ?INTERNAL_ERROR, ErrMsg}
        end,
        SessionPid ! {handler_result, Ref, Result}
    end),
    InFlight = maps:put(MonRef, {From, Id, Ref, Pid},
                        State#state.in_flight),
    {noreply_async, State#state{in_flight = InFlight}}.

%%--------------------------------------------------------------------
%% Initialize handshake (server side)
%%--------------------------------------------------------------------

handle_initialize(Id, Params, State) ->
    ClientVersion = maps:get(<<"protocolVersion">>, Params, undefined),
    ClientCapsMap = maps:get(<<"capabilities">>, Params, #{}),
    ClientInfoMap = maps:get(<<"clientInfo">>, Params, #{}),
    ClientCaps = mcp_capability:parse_client(ClientCapsMap),
    ClientInfo = #implementation{
        name = maps:get(<<"name">>, ClientInfoMap, <<"unknown">>),
        version = maps:get(<<"version">>, ClientInfoMap, <<"0.0.0">>)
    },
    %% Negotiate capabilities
    ServerCaps = case State#state.server_capabilities of
        undefined -> mcp_capability:server_capabilities(#{});
        Caps -> Caps
    end,
    NegotiatedCaps = mcp_capability:negotiate(ClientCaps, ServerCaps),
    %% Build response
    ServerInfoMap = case State#state.server_info of
        undefined ->
            #{<<"name">> => <<"erl_mcp">>, <<"version">> => <<"0.1.0">>};
        #implementation{name = N, version = V} ->
            #{<<"name">> => N, <<"version">> => V}
    end,
    %% Use client's protocol version if we support it, otherwise ours
    ResponseVersion = case ClientVersion of
        ?MCP_PROTOCOL_VERSION -> ?MCP_PROTOCOL_VERSION;
        _ -> ?MCP_PROTOCOL_VERSION
    end,
    Result = #{
        <<"protocolVersion">> => ResponseVersion,
        <<"capabilities">> => mcp_capability:server_to_map(NegotiatedCaps),
        <<"serverInfo">> => ServerInfoMap
    },
    Reply = mcp_jsonrpc:response(Id, Result),
    NewState = State#state{
        status = initialized,
        client_capabilities = ClientCaps,
        client_info = ClientInfo,
        server_capabilities = NegotiatedCaps
    },
    {reply, Reply, NewState}.

%%--------------------------------------------------------------------
%% Cancellation
%%--------------------------------------------------------------------

handle_cancellation(Params, State) ->
    RequestId = maps:get(<<"requestId">>, Params, undefined),
    _Reason = maps:get(<<"reason">>, Params, undefined),
    %% Check pending outbound requests first
    case maps:take(RequestId, State#state.pending_requests) of
        {{Pid, _Ref}, Remaining} ->
            Pid ! {mcp_cancelled, RequestId},
            {noreply, State#state{pending_requests = Remaining}};
        error ->
            %% Check in-flight handler processes
            cancel_in_flight(RequestId, State)
    end.

cancel_in_flight(RequestId, State) ->
    case find_in_flight_by_id(RequestId, State#state.in_flight) of
        {ok, MonRef, From, HPid} ->
            demonitor(MonRef, [flush]),
            exit(HPid, cancelled),
            ErrResp = mcp_jsonrpc:error_response(
                RequestId, ?REQUEST_CANCELLED, <<"Request cancelled">>),
            gen_server:reply(From, {reply, ErrResp}),
            Remaining = maps:remove(MonRef, State#state.in_flight),
            {noreply, State#state{in_flight = Remaining}};
        error ->
            {noreply, State}
    end.

%%--------------------------------------------------------------------
%% Progress
%%--------------------------------------------------------------------

handle_progress(Params, State) ->
    Token = maps:get(<<"progressToken">>, Params, undefined),
    case maps:get(Token, State#state.progress_handlers, undefined) of
        undefined ->
            {noreply, State};
        Pid ->
            Pid ! {mcp_progress, Token, Params},
            {noreply, State}
    end.

%%--------------------------------------------------------------------
%% Pending response handling
%%--------------------------------------------------------------------

handle_pending_response(Id, Result, State) ->
    case maps:take(Id, State#state.pending_requests) of
        {{Pid, Ref}, Remaining} ->
            Pid ! {mcp_response, Ref, Result},
            {noreply, State#state{pending_requests = Remaining}};
        error ->
            {noreply, State}
    end.

%%--------------------------------------------------------------------
%% Transport
%%--------------------------------------------------------------------

send_to_transport(_Message, #state{transport_pid = undefined}) ->
    {error, no_transport};
send_to_transport(Message, #state{transport_pid = Pid}) ->
    case mcp_jsonrpc:encode(Message) of
        {ok, Bin} ->
            Pid ! {mcp_send, Bin},
            ok;
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% Internal: in-flight handler lookup
%%--------------------------------------------------------------------

%% Find in-flight entry by the handler's correlation Ref
find_in_flight_by_ref(Ref, InFlight) ->
    Result = maps:fold(fun
        (MonRef, {From, Id, R, _Pid}, error) when R =:= Ref ->
            {ok, MonRef, From, Id};
        (_MonRef, _Val, Acc) ->
            Acc
    end, error, InFlight),
    Result.

%% Find in-flight entry by JSON-RPC request Id
find_in_flight_by_id(RequestId, InFlight) ->
    maps:fold(fun
        (MonRef, {From, Id, _Ref, Pid}, error) when Id =:= RequestId ->
            {ok, MonRef, From, Pid};
        (_MonRef, _Val, Acc) ->
            Acc
    end, error, InFlight).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

generate_session_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    base64:encode(Bytes, #{mode => urlsafe, padding => false}).
