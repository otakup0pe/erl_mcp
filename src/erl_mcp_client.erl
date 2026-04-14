-module(erl_mcp_client).
-behaviour(gen_statem).

%% MCP client: embeddable gen_statem that speaks JSON-RPC 2.0 to an
%% external MCP server over a pluggable transport. Consumers place
%% the child under their own supervisor via child_spec/1.
%%
%% States:
%%   connecting   - transport connect + initialize request
%%   initialising - waiting for initialize response
%%   ready        - handshake complete, tool discovery + calls allowed
%%   reconnecting - lost/invalidated session; will reinitialise
%%   failed       - startup or fatal error; terminal for this instance

-include("mcp.hrl").
-include("mcp_client.hrl").

-export([start_link/1, child_spec/1]).
-export([call/4, list_tools/1, refresh_tools/1, update_auth/2, status/1,
         stop/1]).

-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([connecting/3, initialising/3, ready/3, reconnecting/3, failed/3]).

-define(DEFAULT_CALL_TIMEOUT, 30000).
-define(DEFAULT_RECONNECT_BACKOFF_MS, 1000).
-define(MAX_RECONNECT_BACKOFF_MS, 30000).

-record(pending, {
    from :: gen_statem:from(),
    method :: binary(),
    deadline :: integer()
}).

-record(data, {
    config :: map(),
    transport_mod :: module(),
    transport_handle :: undefined | term(),
    protocol_version :: binary(),
    tool_prefix :: binary(),
    capabilities :: map(),
    telemetry :: undefined | {module(), atom()} | fun((term()) -> any()),
    server_capabilities = #{} :: map(),
    server_info = #{} :: map(),
    negotiated_version :: undefined | binary(),
    next_request_id = 1 :: pos_integer(),
    pending = #{} :: #{pos_integer() => #pending{}},
    tool_cache :: undefined | [#mcp_client_tool{}],
    last_error :: undefined | term(),
    reconnect_backoff = ?DEFAULT_RECONNECT_BACKOFF_MS :: pos_integer(),
    initialize_from :: undefined | gen_statem:from()
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Config) ->
    Id = maps:get(id, Config, ?MODULE),
    #{
        id => Id,
        start => {?MODULE, start_link, [Config]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    case maps:get(name, Config, undefined) of
        undefined ->
            gen_statem:start_link(?MODULE, Config, []);
        {local, _} = Name ->
            gen_statem:start_link(Name, ?MODULE, Config, []);
        {global, _} = Name ->
            gen_statem:start_link(Name, ?MODULE, Config, []);
        {via, _, _} = Name ->
            gen_statem:start_link(Name, ?MODULE, Config, [])
    end.

-spec call(pid() | atom(), binary(), map(), timeout()) ->
    {ok, map()} | {error, term()}.
call(Ref, ToolName, Arguments, Timeout) ->
    gen_statem:call(Ref, {tools_call, ToolName, Arguments, Timeout},
                    infinity).

-spec list_tools(pid() | atom()) -> {ok, [#mcp_client_tool{}]} | {error, term()}.
list_tools(Ref) ->
    gen_statem:call(Ref, list_tools, infinity).

-spec refresh_tools(pid() | atom()) ->
    {ok, [#mcp_client_tool{}]} | {error, term()}.
refresh_tools(Ref) ->
    gen_statem:call(Ref, refresh_tools, infinity).

-spec update_auth(pid() | atom(), term()) -> ok | {error, term()}.
update_auth(Ref, NewAuth) ->
    gen_statem:call(Ref, {update_auth, NewAuth}, infinity).

-spec status(pid() | atom()) -> map().
status(Ref) ->
    gen_statem:call(Ref, status, infinity).

-spec stop(pid() | atom()) -> ok.
stop(Ref) ->
    gen_statem:stop(Ref).

%%--------------------------------------------------------------------
%% gen_statem callbacks
%%--------------------------------------------------------------------

callback_mode() -> state_functions.

init(Config) ->
    process_flag(trap_exit, true),
    ProtoVsn = maps:get(protocol_version, Config,
                        ?MCP_CLIENT_DEFAULT_PROTOCOL_VERSION),
    TransportMod = maps:get(transport, Config,
                            erl_mcp_transport_http_streamable),
    Prefix = maps:get(tool_prefix, Config, <<>>),
    Caps = maps:get(capabilities, Config, #{}),
    Telemetry = maps:get(telemetry, Config, undefined),
    Data = #data{
        config = Config,
        transport_mod = TransportMod,
        protocol_version = ProtoVsn,
        tool_prefix = Prefix,
        capabilities = Caps,
        telemetry = Telemetry
    },
    {ok, connecting, Data, [{next_event, internal, connect}]}.

terminate(_Reason, _State, Data) ->
    _ = close_transport(Data),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%--------------------------------------------------------------------
%% State: connecting
%%--------------------------------------------------------------------

connecting(internal, connect, #data{transport_mod = Mod,
                                     config = Config0,
                                     protocol_version = Vsn} = Data) ->
    Config = Config0#{protocol_version => Vsn},
    emit(Data, #{event => connect_start}),
    case Mod:connect(Config) of
        {ok, Handle} ->
            emit(Data, #{event => connect_ok}),
            Data1 = Data#data{transport_handle = Handle,
                              reconnect_backoff = ?DEFAULT_RECONNECT_BACKOFF_MS},
            %% Fire initialize synchronously from connecting state.
            case send_initialize(Data1) of
                {ok, Data2} ->
                    {next_state, ready, handshake_done(Data2)};
                {error, Reason, Data2} ->
                    emit(Data2, #{event => initialize_failed,
                                  reason => Reason}),
                    {Data3, Act} = schedule_reconnect(
                                     Data2#data{last_error = Reason}),
                    {next_state, reconnecting, Data3, [Act]}
            end;
        {error, Reason} ->
            emit(Data, #{event => connect_failed, reason => Reason}),
            {Data1, Act} = schedule_reconnect(
                             Data#data{last_error = Reason}),
            {next_state, reconnecting, Data1, [Act]}
    end;
connecting({call, From}, Req, Data) ->
    queue_while_not_ready(From, Req, Data);
connecting(EventType, Event, Data) ->
    generic_event(EventType, Event, connecting, Data).

initialising({call, From}, Req, Data) ->
    queue_while_not_ready(From, Req, Data);
initialising(EventType, Event, Data) ->
    generic_event(EventType, Event, initialising, Data).

ready({call, From}, list_tools, Data) ->
    case Data#data.tool_cache of
        undefined ->
            case do_tools_list(Data) of
                {ok, Tools, Data1} ->
                    {keep_state, Data1#data{tool_cache = Tools},
                     [{reply, From, {ok, Tools}}]};
                {error, Reason, Data1} ->
                    handle_tools_error(From, Reason, Data1)
            end;
        Tools ->
            {keep_state_and_data, [{reply, From, {ok, Tools}}]}
    end;
ready({call, From}, refresh_tools, Data) ->
    case do_tools_list(Data) of
        {ok, Tools, Data1} ->
            {keep_state, Data1#data{tool_cache = Tools},
             [{reply, From, {ok, Tools}}]};
        {error, Reason, Data1} ->
            handle_tools_error(From, Reason, Data1)
    end;
ready({call, From}, {tools_call, ToolName, Args, Timeout}, Data) ->
    RawName = resolve_raw_name(ToolName, Data),
    case do_tools_call(RawName, Args, Timeout, Data) of
        {ok, Result, Data1} ->
            {keep_state, Data1, [{reply, From, {ok, Result}}]};
        {error, session_not_found, Data1} ->
            %% Session rotated -- reconnect and surface a retryable
            %% error to the caller.
            Data2 = Data1#data{tool_cache = undefined,
                               last_error = session_not_found},
            {Data3, Act} = schedule_reconnect(Data2),
            {next_state, reconnecting, Data3,
             [Act, {reply, From, {error, session_not_found}}]};
        {error, Reason, Data1} ->
            {keep_state, Data1#data{last_error = Reason},
             [{reply, From, {error, Reason}}]}
    end;
ready({call, From}, {update_auth, NewAuth}, Data) ->
    case do_update_auth(NewAuth, Data) of
        {ok, Data1} ->
            {keep_state, Data1, [{reply, From, ok}]};
        {error, Reason, Data1} ->
            {keep_state, Data1, [{reply, From, {error, Reason}}]}
    end;
ready({call, From}, status, Data) ->
    {keep_state_and_data, [{reply, From, status_map(ready, Data)}]};
ready(EventType, Event, Data) ->
    generic_event(EventType, Event, ready, Data).

reconnecting({call, From}, status, Data) ->
    {keep_state_and_data, [{reply, From, status_map(reconnecting, Data)}]};
reconnecting({call, From}, {update_auth, NewAuth}, Data) ->
    case do_update_auth(NewAuth, Data) of
        {ok, Data1} -> {keep_state, Data1, [{reply, From, ok}]};
        {error, Reason, Data1} ->
            {keep_state, Data1, [{reply, From, {error, Reason}}]}
    end;
reconnecting({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
reconnecting(state_timeout, reconnect, Data) ->
    _ = close_transport(Data),
    Data1 = Data#data{transport_handle = undefined,
                      pending = #{},
                      tool_cache = undefined},
    {next_state, connecting, Data1, [{next_event, internal, connect}]};
reconnecting(EventType, Event, Data) ->
    generic_event(EventType, Event, reconnecting, Data).

failed({call, From}, status, Data) ->
    {keep_state_and_data, [{reply, From, status_map(failed, Data)}]};
failed({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, failed}}]};
failed(EventType, Event, Data) ->
    generic_event(EventType, Event, failed, Data).

generic_event(info, {'EXIT', _Pid, _Reason}, _State, _Data) ->
    keep_state_and_data;
generic_event(_, _, _, _) ->
    keep_state_and_data.

queue_while_not_ready(From, status, Data) ->
    {keep_state_and_data,
     [{reply, From, status_map(current_state_atom(Data), Data)}]};
queue_while_not_ready(From, {update_auth, NewAuth}, Data) ->
    case do_update_auth(NewAuth, Data) of
        {ok, Data1} -> {keep_state, Data1, [{reply, From, ok}]};
        {error, Reason, Data1} ->
            {keep_state, Data1, [{reply, From, {error, Reason}}]}
    end;
queue_while_not_ready(From, _Other, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

current_state_atom(#data{transport_handle = undefined}) ->
    connecting;
current_state_atom(_) ->
    initialising.

handshake_done(Data) ->
    Data#data{reconnect_backoff = ?DEFAULT_RECONNECT_BACKOFF_MS,
              last_error = undefined}.

handle_tools_error(From, session_not_found, Data) ->
    Data1 = Data#data{tool_cache = undefined,
                      last_error = session_not_found},
    {Data2, Act} = schedule_reconnect(Data1),
    {next_state, reconnecting, Data2,
     [Act, {reply, From, {error, session_not_found}}]};
handle_tools_error(From, Reason, Data) ->
    {keep_state, Data#data{last_error = Reason},
     [{reply, From, {error, Reason}}]}.

schedule_reconnect(#data{reconnect_backoff = B} = Data) ->
    NextB = min(B * 2, ?MAX_RECONNECT_BACKOFF_MS),
    {Data#data{reconnect_backoff = NextB},
     {state_timeout, B, reconnect}}.

send_initialize(#data{} = Data) ->
    {Id, Data1} = next_id(Data),
    Params = #{
        <<"protocolVersion">> => Data1#data.protocol_version,
        <<"capabilities">> => Data1#data.capabilities,
        <<"clientInfo">> => client_info(Data1)
    },
    Req = mcp_jsonrpc:request(Id, <<"initialize">>, Params),
    case send_request_sync(Req, Data1) of
        {ok, #jsonrpc_response{result = Result}, Data2} ->
            Data3 = Data2#data{
                server_capabilities = maps:get(<<"capabilities">>, Result, #{}),
                server_info = maps:get(<<"serverInfo">>, Result, #{}),
                negotiated_version = maps:get(<<"protocolVersion">>, Result,
                                              Data2#data.protocol_version)
            },
            case send_initialized(Data3) of
                {ok, Data4} -> {ok, Data4};
                {error, R, Data4} -> {error, R, Data4}
            end;
        {ok, #jsonrpc_error{code = Code, message = Msg}, Data2} ->
            {error, {initialize_error, Code, Msg}, Data2};
        {error, Reason, Data2} ->
            {error, Reason, Data2}
    end.

send_initialized(Data) ->
    Notif = mcp_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    send_notification(Notif, Data).

client_info(#data{config = Config}) ->
    Info = maps:get(client_info, Config, #{}),
    Name = maps:get(name, Info, <<"erl_mcp">>),
    Vsn = maps:get(version, Info, <<"0.1.0">>),
    #{<<"name">> => Name, <<"version">> => Vsn}.

do_tools_list(Data) ->
    {Id, Data1} = next_id(Data),
    Req = mcp_jsonrpc:request(Id, <<"tools/list">>, #{}),
    case send_request_sync(Req, Data1) of
        {ok, #jsonrpc_response{result = Result}, Data2} ->
            Raw = maps:get(<<"tools">>, Result, []),
            Tools = [to_client_tool(T, Data2#data.tool_prefix) || T <- Raw],
            {ok, Tools, Data2};
        {ok, #jsonrpc_error{code = Code, message = Msg}, Data2} ->
            {error, {jsonrpc_error, Code, Msg}, Data2};
        {error, Reason, Data2} ->
            {error, Reason, Data2}
    end.

to_client_tool(Map, Prefix) when is_map(Map) ->
    Name = maps:get(<<"name">>, Map, <<>>),
    Prefixed = case Prefix of
        <<>> -> Name;
        _ -> <<Prefix/binary, "__", Name/binary>>
    end,
    #mcp_client_tool{
        name = Prefixed,
        raw_name = Name,
        description = maps:get(<<"description">>, Map, undefined),
        input_schema = maps:get(<<"inputSchema">>, Map,
                                #{<<"type">> => <<"object">>}),
        annotations = maps:get(<<"annotations">>, Map, #{})
    }.

resolve_raw_name(ToolName, #data{tool_prefix = <<>>}) ->
    ToolName;
resolve_raw_name(ToolName, #data{tool_prefix = Prefix, tool_cache = Cache}) ->
    case lists:keyfind(ToolName, #mcp_client_tool.name,
                       list_or_empty(Cache)) of
        #mcp_client_tool{raw_name = Raw} -> Raw;
        false ->
            case ToolName of
                <<P:(byte_size(Prefix))/binary, "__", Rest/binary>>
                  when P =:= Prefix ->
                    Rest;
                _ ->
                    ToolName
            end
    end.

list_or_empty(undefined) -> [];
list_or_empty(L) -> L.

do_tools_call(Name, Args, Timeout, Data) ->
    {Id, Data1} = next_id(Data),
    Params = #{<<"name">> => Name, <<"arguments">> => Args},
    Req = mcp_jsonrpc:request(Id, <<"tools/call">>, Params),
    emit(Data1, #{event => tools_call_start, tool => Name}),
    case send_request_sync(Req, Data1, Timeout) of
        {ok, #jsonrpc_response{result = Result}, Data2} ->
            emit(Data2, #{event => tools_call_ok, tool => Name}),
            case Result of
                #{<<"isError">> := true} ->
                    {error, {tool_error, Result}, Data2};
                _ ->
                    {ok, Result, Data2}
            end;
        {ok, #jsonrpc_error{code = Code, message = Msg}, Data2} ->
            emit(Data2, #{event => tools_call_jsonrpc_error,
                          tool => Name, code => Code}),
            {error, {jsonrpc_error, Code, Msg}, Data2};
        {error, session_not_found, Data2} ->
            emit(Data2, #{event => tools_call_session_lost, tool => Name}),
            {error, session_not_found, Data2};
        {error, Reason, Data2} ->
            emit(Data2, #{event => tools_call_error,
                          tool => Name, reason => Reason}),
            {error, Reason, Data2}
    end.

do_update_auth(NewAuth, #data{transport_mod = Mod,
                              transport_handle = H,
                              config = Config} = Data)
  when H =/= undefined ->
    case erlang:function_exported(Mod, update_auth, 2) of
        true ->
            case Mod:update_auth(H, NewAuth) of
                {ok, H1} ->
                    {ok, Data#data{transport_handle = H1,
                                   config = Config#{auth => NewAuth}}};
                {error, Reason} ->
                    {error, Reason, Data}
            end;
        false ->
            {error, not_supported, Data}
    end;
do_update_auth(NewAuth, #data{config = Config} = Data) ->
    {ok, Data#data{config = Config#{auth => NewAuth}}}.

send_request_sync(Req, Data) ->
    send_request_sync(Req, Data, ?DEFAULT_CALL_TIMEOUT).

send_request_sync(Req, #data{transport_mod = Mod,
                              transport_handle = H} = Data,
                  Timeout)
  when H =/= undefined ->
    case mcp_jsonrpc:encode(Req) of
        {ok, Body} ->
            case Mod:request(H, Body, Timeout) of
                {ok, RespBody, H1} ->
                    Data1 = Data#data{transport_handle = H1},
                    decode_response(RespBody, Data1);
                {error, Reason, H1} ->
                    {error, Reason, Data#data{transport_handle = H1}}
            end;
        {error, Reason} ->
            {error, {encode_error, Reason}, Data}
    end;
send_request_sync(_Req, Data, _Timeout) ->
    {error, no_transport, Data}.

send_notification(Notif, #data{transport_mod = Mod,
                                transport_handle = H} = Data)
  when H =/= undefined ->
    case mcp_jsonrpc:encode(Notif) of
        {ok, Body} ->
            case Mod:notify(H, Body) of
                {ok, H1} ->
                    {ok, Data#data{transport_handle = H1}};
                {error, Reason, H1} ->
                    {error, Reason, Data#data{transport_handle = H1}}
            end;
        {error, Reason} ->
            {error, {encode_error, Reason}, Data}
    end;
send_notification(_Notif, Data) ->
    {error, no_transport, Data}.

decode_response(Body, Data) ->
    case mcp_jsonrpc:decode(Body) of
        {ok, #jsonrpc_response{} = Resp} ->
            {ok, Resp, Data};
        {ok, #jsonrpc_error{} = Err} ->
            {ok, Err, Data};
        {ok, #jsonrpc_notification{method = Method, params = Params}} ->
            handle_inbound_notification(Method, Params, Data),
            {error, {unexpected_notification, Method}, Data};
        {ok, _Other} ->
            {error, {malformed_response, unexpected_shape}, Data};
        {error, Reason} ->
            {error, {malformed_response, Reason}, Data}
    end.

handle_inbound_notification(<<"notifications/tools/list_changed">>, _P,
                            _Data) ->
    %% placeholder for future expansion on tool list cache strategy
    ok;
handle_inbound_notification(_Method, _Params, _Data) ->
    ok.

close_transport(#data{transport_mod = Mod, transport_handle = H})
  when H =/= undefined ->
    _ = Mod:close(H),
    ok;
close_transport(_) ->
    ok.

next_id(#data{next_request_id = Id} = Data) ->
    {Id, Data#data{next_request_id = Id + 1}}.

status_map(State, Data) ->
    TC = case Data#data.tool_cache of
        undefined -> 0;
        L -> length(L)
    end,
    #{
        state => State,
        server_info => Data#data.server_info,
        negotiated_version => Data#data.negotiated_version,
        tool_count => TC,
        last_error => Data#data.last_error
    }.

emit(#data{telemetry = undefined}, _Event) -> ok;
emit(#data{telemetry = Fun}, Event) when is_function(Fun, 1) ->
    _ = spawn(fun() -> Fun(Event) end),
    ok;
emit(#data{telemetry = {Mod, Fun}}, Event) ->
    _ = spawn(Mod, Fun, [Event]),
    ok;
emit(_, _) -> ok.
