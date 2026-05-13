-module(session_persistence_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    session_survives_manager_restart/1,
    expired_session_not_rebuilt/1,
    no_store_unchanged_behavior/1,
    clean_delete_removes_from_store/1,
    tool_call_works_after_rebuild/1,
    prune_removes_expired/1
]).

all() -> [
    session_survives_manager_restart,
    expired_session_not_rebuilt,
    no_store_unchanged_behavior,
    clean_delete_removes_from_store,
    tool_call_works_after_rebuild,
    prune_removes_expired
].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(no_store_unchanged_behavior, Config) ->
    %% This test runs without a store configured
    application:unset_env(erl_mcp, session_store),
    application:unset_env(erl_mcp, on_session_rebuild),
    application:unset_env(erl_mcp, session_opts_template),
    init_common(Config);
init_per_testcase(expired_session_not_rebuilt, Config) ->
    %% Use a 1-second TTL so sessions expire immediately
    application:set_env(erl_mcp, session_idle_timeout, 1000),
    init_with_store(Config);
init_per_testcase(_TC, Config) ->
    application:set_env(erl_mcp, session_idle_timeout, 64800000),
    init_with_store(Config).

init_with_store(Config) ->
    TmpDir = make_tmp_dir(),
    DetsPath = filename:join(TmpDir, "test-sessions.dets"),
    application:set_env(erl_mcp, session_store,
                        {mock_session_store, #{path => DetsPath}}),
    Self = self(),
    application:set_env(erl_mcp, on_session_rebuild,
                        fun(SessionId) ->
                            Self ! {rebuilt, SessionId}
                        end),
    %% Create the ETS table from the test process so it survives
    %% manager restarts (table owner = test process, not manager).
    case ets:info(mock_session_store_table) of
        undefined ->
            ets:new(mock_session_store_table,
                    [named_table, public, set]);
        _ -> ok
    end,
    [{tmp_dir, TmpDir}, {dets_path, DetsPath} | init_common(Config)].

init_common(Config) ->
    catch cowboy:stop_listener(test_persist_listener),
    stop_if_alive(erl_mcp_server_session_manager),
    stop_if_alive(erl_mcp_server_tool_registry),
    {ok, RegPid} = erl_mcp_server_tool_registry:start_link(),
    unlink(RegPid),
    EchoTool = #tool{
        name = <<"echo">>,
        description = <<"Echoes input">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    EchoHandler = fun(Args, _Ctx) ->
        Msg = maps:get(<<"message">>, Args, <<"no message">>),
        {ok, #{<<"content">> =>
            [erl_mcp_protocol_content:to_map(
                erl_mcp_protocol_content:text(Msg))]}}
    end,
    ok = erl_mcp_server_tool_registry:register_tool(EchoTool, EchoHandler),
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{
        tools => #{list_changed => true}
    }),
    ServerInfo = #implementation{
        name = <<"test-persist-server">>,
        version = <<"0.1.0">>
    },
    HandlerState = #{
        handlers => erl_mcp_server_protocol:default_handlers(),
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    },
    application:set_env(erl_mcp, session_opts_template, HandlerState),
    {ok, MgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(MgrPid),
    Dispatch = cowboy_router:compile([
        {'_', [{"/mcp", erl_mcp_server_http_handler, HandlerState}]}
    ]),
    {ok, _} = cowboy:start_clear(test_persist_listener,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(test_persist_listener),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port),
    [{base_url, BaseUrl}, {mgr_pid, MgrPid}, {reg_pid, RegPid},
     {handler_state, HandlerState} | Config].

end_per_testcase(_TC, Config) ->
    cowboy:stop_listener(test_persist_listener),
    stop_if_alive(erl_mcp_server_session_manager),
    stop_if_alive(erl_mcp_server_tool_registry),
    case ets:info(mock_session_store_table) of
        undefined -> ok;
        _ -> ets:delete(mock_session_store_table)
    end,
    case proplists:get_value(tmp_dir, Config) of
        undefined -> ok;
        Dir -> cleanup_tmp_dir(Dir)
    end,
    application:unset_env(erl_mcp, session_store),
    application:unset_env(erl_mcp, on_session_rebuild),
    application:unset_env(erl_mcp, session_opts_template),
    application:unset_env(erl_mcp, session_idle_timeout),
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

session_survives_manager_restart(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    %% Session works before restart
    ?assertMatch({ok, _, _, 200}, do_ping(BaseUrl, SessionId)),
    %% Kill the session manager (simulates server restart)
    MgrPid = proplists:get_value(mgr_pid, Config),
    gen_server:stop(MgrPid, shutdown, 5000),
    %% Restart session manager — it should load the store
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    %% Same session ID should work — rebuilt from store
    {ok, _Body, _Headers, Status} = do_ping(BaseUrl, SessionId),
    ?assertEqual(200, Status),
    %% Should have received the on_rebuild callback
    %% (SessionId from httpc is a string; internal ID is binary)
    SessionIdBin = list_to_binary(SessionId),
    receive
        {rebuilt, SessionIdBin} -> ok
    after 1000 ->
        ct:fail("on_rebuild callback not fired")
    end.

expired_session_not_rebuilt(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    ?assertMatch({ok, _, _, 200}, do_ping(BaseUrl, SessionId)),
    %% Kill manager
    MgrPid = proplists:get_value(mgr_pid, Config),
    gen_server:stop(MgrPid, shutdown, 5000),
    %% Wait for TTL to expire (1 second configured in init_per_testcase).
    %% Sleep 2.5s to clear the integer-second boundary reliably.
    timer:sleep(2500),
    %% Restart manager
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    %% Session should NOT be rebuilt — expired
    {ok, _Body, _Headers, Status} = do_ping(BaseUrl, SessionId),
    ?assertEqual(404, Status).

no_store_unchanged_behavior(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    ?assertMatch({ok, _, _, 200}, do_ping(BaseUrl, SessionId)),
    %% Kill manager
    MgrPid = proplists:get_value(mgr_pid, Config),
    gen_server:stop(MgrPid, shutdown, 5000),
    %% Restart without store
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    %% Session should be gone — no store to rebuild from
    {ok, _Body, _Headers, Status} = do_ping(BaseUrl, SessionId),
    ?assertEqual(404, Status).

clean_delete_removes_from_store(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    %% DELETE the session
    {ok, {{_, 200, _}, _, _}} = httpc:request(delete,
        {BaseUrl ++ "/mcp", [{"mcp-session-id", SessionId}]},
        [], [{body_format, binary}]),
    %% Kill and restart manager
    MgrPid = proplists:get_value(mgr_pid, Config),
    gen_server:stop(MgrPid, shutdown, 5000),
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    %% Session should NOT be rebuilt — was explicitly deleted
    {ok, _Body, _Headers, Status} = do_ping(BaseUrl, SessionId),
    ?assertEqual(404, Status).

tool_call_works_after_rebuild(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    %% Kill and restart manager
    MgrPid = proplists:get_value(mgr_pid, Config),
    gen_server:stop(MgrPid, shutdown, 5000),
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    %% Tool call on rebuilt session should work
    CallReq = erl_mcp_protocol_jsonrpc:request(10, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"message">> => <<"after restart">>}
    }),
    {ok, Body, _H, 200} = post_json_full(BaseUrl ++ "/mcp", CallReq,
        [{"mcp-session-id", SessionId}]),
    {ok, Decoded} = erl_mcp_protocol_jsonrpc:decode(Body),
    ?assertMatch(#jsonrpc_response{id = 10}, Decoded),
    Result = Decoded#jsonrpc_response.result,
    [Content] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"after restart">>, maps:get(<<"text">>, Content)).

prune_removes_expired(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _SessionId = do_initialize(BaseUrl),
    %% Verify session is in the store
    Sessions = erl_mcp_server_session_manager:list_sessions(),
    ?assertEqual(1, length(Sessions)),
    %% Prune with a 0-second max age should remove everything
    MgrPid = proplists:get_value(mgr_pid, Config),
    timer:sleep(100),
    MgrPid ! prune_store,
    %% The prune uses the configured TTL (18h) so sessions won't
    %% be pruned yet. Override the TTL temporarily.
    application:set_env(erl_mcp, session_idle_timeout, 1),
    timer:sleep(100),
    MgrPid ! prune_store,
    timer:sleep(100),
    %% The in-memory session is still alive (prune only clears
    %% the store, not live sessions). Verify by checking the store
    %% directly: kill manager, restart, session should not rebuild.
    gen_server:stop(MgrPid, shutdown, 5000),
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    NewSessions = erl_mcp_server_session_manager:list_sessions(),
    ?assertEqual(0, length(NewSessions)).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

do_initialize(BaseUrl) ->
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test-client">>,
                              <<"version">> => <<"1.0">>}
    }),
    {ok, _Body, Headers} = post_json(BaseUrl ++ "/mcp", InitReq),
    proplists:get_value("mcp-session-id", Headers).

do_ping(BaseUrl, SessionId) ->
    PingReq = erl_mcp_protocol_jsonrpc:request(2, <<"ping">>, #{}),
    post_json_full(BaseUrl ++ "/mcp", PingReq,
        [{"mcp-session-id", SessionId}]).

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

make_tmp_dir() ->
    Base = filename:join(["/tmp", "erl_mcp_test_" ++
        integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_dir(filename:join(Base, "x")),
    Base.

cleanup_tmp_dir(Dir) ->
    os:cmd("rm -rf " ++ Dir).
