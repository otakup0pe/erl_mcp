-module(http_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").

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
    %% Clean up any lingering processes from previous tests
    catch cowboy:stop_listener(test_mcp_listener),
    stop_if_alive(mcp_session_manager),
    stop_if_alive(mcp_tool_registry),
    %% Start session manager
    {ok, MgrPid} = mcp_session_manager:start_link(),
    unlink(MgrPid),
    %% Start tool registry and register a test tool
    {ok, RegPid} = mcp_tool_registry:start_link(),
    unlink(RegPid),
    EchoTool = #tool{
        name = <<"echo">>,
        description = <<"Echoes input">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    EchoHandler = fun(Args, _St) ->
        Msg = maps:get(<<"message">>, Args, <<"no message">>),
        {ok, #{<<"content">> => [mcp_content:to_map(mcp_content:text(Msg))]}}
    end,
    ok = mcp_tool_registry:register_tool(EchoTool, EchoHandler),
    %% Start cowboy with MCP HTTP handler
    ServerCaps = mcp_capability:server_capabilities(#{
        tools => #{list_changed => true}
    }),
    ServerInfo = #implementation{
        name = <<"test-mcp-server">>,
        version = <<"0.1.0">>
    },
    HandlerState = #{
        handlers => mcp_protocol:default_handlers(),
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    },
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/mcp", mcp_http_handler, HandlerState}
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
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {ok, Body, Headers} = post_json(BaseUrl ++ "/mcp", InitReq),
    %% Should have session ID in response headers
    SessionId = proplists:get_value("mcp-session-id", Headers),
    ?assertNotEqual(undefined, SessionId),
    %% Body should be valid JSON-RPC response
    {ok, Decoded} = mcp_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 1}, Decoded),
    Result = Decoded#jsonrpc_response.result,
    ?assert(maps:is_key(<<"protocolVersion">>, Result)),
    ?assert(maps:is_key(<<"capabilities">>, Result)),
    ?assert(maps:is_key(<<"serverInfo">>, Result)).

post_ping_requires_session(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    PingReq = mcp_jsonrpc:request(1, <<"ping">>, #{}),
    {ok, _Body, _Headers, Status} = post_json_full(BaseUrl ++ "/mcp", PingReq, []),
    %% Without session header, should get 404
    ?assertEqual(404, Status).

post_ping_with_session(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    %% First initialize to get a session
    SessionId = do_initialize(BaseUrl),
    %% Now ping with session header
    PingReq = mcp_jsonrpc:request(2, <<"ping">>, #{}),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _Headers, Status} = post_json_full(BaseUrl ++ "/mcp", PingReq, ExtraHeaders),
    ?assertEqual(200, Status),
    {ok, Decoded} = mcp_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 2, result = #{}}, Decoded).

post_notification_returns_202(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    Notif = mcp_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    {ok, Bin} = mcp_jsonrpc:encode(Notif),
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
    {ok, Decoded} = mcp_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_error{code = ?PARSE_ERROR}, Decoded).

post_tools_list(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    ListReq = mcp_jsonrpc:request(3, <<"tools/list">>, #{}),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _H, 200} = post_json_full(BaseUrl ++ "/mcp", ListReq, ExtraHeaders),
    {ok, Decoded} = mcp_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 3}, Decoded),
    Tools = maps:get(<<"tools">>, Decoded#jsonrpc_response.result),
    ?assert(length(Tools) >= 1),
    [First | _] = Tools,
    ?assertEqual(<<"echo">>, maps:get(<<"name">>, First)).

post_tools_call(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    CallReq = mcp_jsonrpc:request(4, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"message">> => <<"hi there">>}
    }),
    ExtraHeaders = [{"mcp-session-id", SessionId}],
    {ok, Body, _H, 200} = post_json_full(BaseUrl ++ "/mcp", CallReq, ExtraHeaders),
    {ok, Decoded} = mcp_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 4}, Decoded),
    Result = Decoded#jsonrpc_response.result,
    Content = maps:get(<<"content">>, Result),
    ?assertEqual(1, length(Content)),
    [C] = Content,
    ?assertEqual(<<"hi there">>, maps:get(<<"text">>, C)).

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
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
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
    {ok, Bin} = mcp_jsonrpc:encode(Message),
    {ok, {{_, _Status, _}, Headers, Body}} = httpc:request(post,
        {Url, [], "application/json", Bin},
        [], [{body_format, binary}]),
    {ok, Body, Headers}.

post_json_full(Url, Message, ExtraHeaders) ->
    {ok, Bin} = mcp_jsonrpc:encode(Message),
    AllHeaders = [{"content-type", "application/json"} | ExtraHeaders],
    {ok, {{_, Status, _}, Headers, Body}} = httpc:request(post,
        {Url, AllHeaders, "application/json", Bin},
        [], [{body_format, binary}]),
    {ok, Body, Headers, Status}.
