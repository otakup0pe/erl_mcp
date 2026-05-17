-module(http_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    post_initialize/1,
    post_ping_requires_session/1,
    post_ping_with_session/1,
    post_notification_returns_202/1,
    post_invalid_json_returns_parse_error/1,
    post_tools_list/1,
    post_tools_call/1,
    post_large_body_tools_call/1,
    post_oversized_body/1,
    post_handler_exception/1,
    delete_session/1,
    delete_nonexistent_session/1
]).

all() -> [
    post_initialize,
    post_ping_requires_session,
    post_ping_with_session,
    post_notification_returns_202,
    post_invalid_json_returns_parse_error,
    post_tools_list,
    post_tools_call,
    post_large_body_tools_call,
    post_oversized_body,
    post_handler_exception,
    delete_session,
    delete_nonexistent_session
].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    catch cowboy:stop_listener(test_mcp_listener),
    stop_if_alive(erl_mcp_server_session_manager),
    stop_if_alive(erl_mcp_server_tool_registry),
    {ok, MgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(MgrPid),
    {ok, RegPid} = erl_mcp_server_tool_registry:start_link(),
    unlink(RegPid),
    EchoTool = #tool{
        name = <<"echo">>,
        description = <<"Echoes input">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    EchoHandler = fun(Args, _St) ->
        Msg = maps:get(<<"message">>, Args, <<"no message">>),
        {ok, #{<<"content">> => [erl_mcp_protocol_content:to_map(erl_mcp_protocol_content:text(Msg))]}}
    end,
    ok = erl_mcp_server_tool_registry:register_tool(EchoTool, EchoHandler),
    CrashTool = #tool{
        name = <<"crash">>,
        description = <<"Always throws">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    CrashHandler = fun(_Args, _St) ->
        error(deliberate_test_crash)
    end,
    ok = erl_mcp_server_tool_registry:register_tool(CrashTool, CrashHandler),
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{
        tools => #{list_changed => true}
    }),
    ServerInfo = #implementation{
        name = <<"test-mcp-server">>,
        version = <<"0.1.0">>
    },
    HandlerState = #{
        handlers => erl_mcp_server_protocol:default_handlers(),
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    },
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/mcp", erl_mcp_server_http_handler, HandlerState}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(test_mcp_listener,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(test_mcp_listener),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port),
    [{base_url, BaseUrl}, {mgr_pid, MgrPid}, {reg_pid, RegPid} | Config].

end_per_testcase(_TC, Config) ->
    cowboy:stop_listener(test_mcp_listener),
    MgrPid = proplists:get_value(mgr_pid, Config),
    RegPid = proplists:get_value(reg_pid, Config),
    gen_server:stop(MgrPid),
    gen_server:stop(RegPid).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

post_initialize(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {ok, Body, Headers} = post_json(BaseUrl ++ "/mcp", InitReq),
    SessionId = proplists:get_value("mcp-session-id", Headers),
    ?assertNotEqual(undefined, SessionId),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 1}, Decoded),
    Result = Decoded#jsonrpc_response.result,
    ?assert(maps:is_key(<<"protocolVersion">>, Result)),
    ?assert(maps:is_key(<<"capabilities">>, Result)),
    ?assert(maps:is_key(<<"serverInfo">>, Result)).

post_ping_requires_session(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    PingReq = erl_mcp_protocol_jsonrpc:request(1, <<"ping">>, #{}),
    {ok, _Body, _Headers, Status} = post_json_full(BaseUrl ++ "/mcp", PingReq, []),
    ?assertEqual(404, Status).

post_ping_with_session(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    PingReq = erl_mcp_protocol_jsonrpc:request(2, <<"ping">>, #{}),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _Headers, Status} = post_json_full(BaseUrl ++ "/mcp", PingReq, ExtraHeaders),
    ?assertEqual(200, Status),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 2, result = #{}}, Decoded).

post_notification_returns_202(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    Notif = erl_mcp_protocol_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    {ok, Bin} = erl_mcp_protocol_jsonrpc:encode(Notif),
    ExtraHeaders = [{"mcp-session-id", SessionId},
                    {"content-type", "application/json"}],
    {ok, {{_, Status, _}, _, _}} = httpc:request(post,
        {BaseUrl ++ "/mcp", ExtraHeaders, "application/json", Bin},
        [], [{body_format, binary}]),
    ?assertEqual(202, Status).

post_invalid_json_returns_parse_error(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, {{_, 200, _}, _, Body}} = httpc:request(post,
        {BaseUrl ++ "/mcp", [], "application/json", <<"not json">>},
        [], [{body_format, binary}]),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_error{code = ?PARSE_ERROR}, Decoded).

post_tools_list(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    ListReq = erl_mcp_protocol_jsonrpc:request(3, <<"tools/list">>, #{}),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _H, 200} = post_json_full(BaseUrl ++ "/mcp", ListReq, ExtraHeaders),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 3}, Decoded),
    Tools = maps:get(<<"tools">>, Decoded#jsonrpc_response.result),
    ?assert(length(Tools) >= 1),
    ToolNames = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"echo">>, ToolNames)).

post_tools_call(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    CallReq = erl_mcp_protocol_jsonrpc:request(4, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"message">> => <<"hi there">>}
    }),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _H, 200} = post_json_full(BaseUrl ++ "/mcp", CallReq, ExtraHeaders),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 4}, Decoded),
    Result = Decoded#jsonrpc_response.result,
    Content = maps:get(<<"content">>, Result),
    ?assertEqual(1, length(Content)),
    [C] = Content,
    ?assertEqual(<<"hi there">>, maps:get(<<"text">>, C)).

post_large_body_tools_call(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    %% Build a large argument (~60KB) that stays under the default 1MB limit.
    LargeValue = list_to_binary(lists:duplicate(60000, $x)),
    CallReq = erl_mcp_protocol_jsonrpc:request(5, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"message">> => LargeValue}
    }),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _H, Status} = post_json_full(BaseUrl ++ "/mcp", CallReq, ExtraHeaders),
    ?assertEqual(200, Status),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 5}, Decoded),
    Result = Decoded#jsonrpc_response.result,
    Content = maps:get(<<"content">>, Result),
    [C] = Content,
    ?assertEqual(LargeValue, maps:get(<<"text">>, C)).

post_oversized_body(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    %% Set a very small max_request_body so we can trigger the limit easily.
    OldVal = application:get_env(erl_mcp, max_request_body),
    application:set_env(erl_mcp, max_request_body, 256),
    try
        OversizedPayload = list_to_binary(lists:duplicate(1024, $a)),
        ExtraHeaders = [{"content-type", "application/json"}],
        {ok, {{_, Status, _}, _, _}} = httpc:request(post,
            {BaseUrl ++ "/mcp", ExtraHeaders, "application/json", OversizedPayload},
            [], [{body_format, binary}]),
        ?assertEqual(413, Status)
    after
        case OldVal of
            undefined -> application:unset_env(erl_mcp, max_request_body);
            {ok, V} -> application:set_env(erl_mcp, max_request_body, V)
        end
    end.

post_handler_exception(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    CallReq = erl_mcp_protocol_jsonrpc:request(6, <<"tools/call">>, #{
        <<"name">> => <<"crash">>,
        <<"arguments">> => #{}
    }),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _H, 200} = post_json_full(BaseUrl ++ "/mcp", CallReq, ExtraHeaders),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_error{id = 6, code = ?INTERNAL_ERROR}, Decoded).

delete_session(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    {ok, {{_, Status, _}, _, _}} = httpc:request(delete,
        {BaseUrl ++ "/mcp", [{"mcp-session-id", SessionId}]},
        [], [{body_format, binary}]),
    ?assertEqual(200, Status).

delete_nonexistent_session(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, {{_, Status, _}, _, _}} = httpc:request(delete,
        {BaseUrl ++ "/mcp", [{"mcp-session-id", "bogus-id"}]},
        [], [{body_format, binary}]),
    ?assertEqual(404, Status).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

do_initialize(BaseUrl) ->
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {ok, _Body, Headers} = post_json(BaseUrl ++ "/mcp", InitReq),
    proplists:get_value("mcp-session-id", Headers).

stop_if_alive(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 5000)
    end.

post_json(Url, Message) ->
    {ok, Bin} = erl_mcp_protocol_jsonrpc:encode(Message),
    {ok, {{_, _Status, _}, Headers, Body}} = httpc:request(post,
        {Url, [], "application/json", Bin},
        [], [{body_format, binary}]),
    {ok, Body, Headers}.

post_json_full(Url, Message, ExtraHeaders) ->
    {ok, Bin} = erl_mcp_protocol_jsonrpc:encode(Message),
    AllHeaders = [{"content-type", "application/json"} | ExtraHeaders],
    {ok, {{_, Status, _}, Headers, Body}} = httpc:request(post,
        {Url, AllHeaders, "application/json", Bin},
        [], [{body_format, binary}]),
    {ok, Body, Headers, Status}.
