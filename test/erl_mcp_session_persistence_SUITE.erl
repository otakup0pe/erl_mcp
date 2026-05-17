-module(erl_mcp_session_persistence_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    session_survives_manager_restart/1,
    expired_session_not_rebuilt/1,
    clean_close_removes_from_store/1,
    concurrent_rebuild_same_id/1,
    session_process_dies_after_persist/1,
    no_store_configured_unchanged_behavior/1,
    promote_already_initialized_returns_error/1
]).

all() -> [
    session_survives_manager_restart,
    expired_session_not_rebuilt,
    clean_close_removes_from_store,
    concurrent_rebuild_same_id,
    session_process_dies_after_persist,
    no_store_configured_unchanged_behavior,
    promote_already_initialized_returns_error
].

%%--------------------------------------------------------------------
%% Suite setup / teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Per-testcase setup / teardown
%%--------------------------------------------------------------------

init_per_testcase(no_store_configured_unchanged_behavior, Config) ->
    application:unset_env(erl_mcp, session_store),
    application:unset_env(erl_mcp, on_session_rebuild),
    application:unset_env(erl_mcp, session_opts_template),
    application:set_env(erl_mcp, session_idle_timeout, 30000),
    init_common(Config);
init_per_testcase(expired_session_not_rebuilt, Config) ->
    %% Use a 1-second TTL so sessions expire quickly
    application:set_env(erl_mcp, session_idle_timeout, 1000),
    init_with_store(Config);
init_per_testcase(promote_already_initialized_returns_error, Config) ->
    %% This test does not need cowboy or the session manager;
    %% it exercises the session process directly.
    application:set_env(erl_mcp, session_idle_timeout, 30000),
    Config;
init_per_testcase(_TC, Config) ->
    application:set_env(erl_mcp, session_idle_timeout, 30000),
    init_with_store(Config).

init_with_store(Config) ->
    application:set_env(erl_mcp, session_store,
                        {test_memory_store, #{}}),
    Self = self(),
    application:set_env(erl_mcp, on_session_rebuild,
                        fun(SessionId) ->
                            Self ! {rebuilt, SessionId}
                        end),
    %% Create the ETS table from the test process so it survives
    %% session manager restarts (table owner = test process).
    ensure_store_table(),
    init_common(Config).

init_common(Config) ->
    catch cowboy:stop_listener(test_persist2_listener),
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
        name = <<"test-persist2-server">>,
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
    {ok, _} = cowboy:start_clear(test_persist2_listener,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(test_persist2_listener),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port),
    [{base_url, BaseUrl}, {mgr_pid, MgrPid}, {reg_pid, RegPid},
     {handler_state, HandlerState} | Config].

end_per_testcase(promote_already_initialized_returns_error, _Config) ->
    ok;
end_per_testcase(_TC, _Config) ->
    %% Stop the listener first so no new HTTP requests can reach the
    %% session manager while we are tearing down.
    catch cowboy:stop_listener(test_persist2_listener),
    %% Kill any orphaned session processes (they are unlinked from the
    %% manager so stopping the manager alone does not terminate them).
    kill_all_sessions(),
    stop_if_alive(erl_mcp_server_session_manager),
    stop_if_alive(erl_mcp_server_tool_registry),
    case ets:info(test_memory_store_table) of
        undefined -> ok;
        _ -> ets:delete(test_memory_store_table)
    end,
    application:unset_env(erl_mcp, session_store),
    application:unset_env(erl_mcp, on_session_rebuild),
    application:unset_env(erl_mcp, session_opts_template),
    application:unset_env(erl_mcp, session_idle_timeout),
    ok.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

%% 1. Create session via initialize handshake, kill manager, restart,
%%    verify the session is rebuilt from the store.
session_survives_manager_restart(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    %% Confirm session is alive
    ?assertMatch({ok, _, _, 200}, do_ping(BaseUrl, SessionId)),
    %% Stop listener first, then kill manager (prevents noproc from
    %% in-flight cowboy requests hitting a dead manager).
    stop_listener_and_manager(Config),
    %% Restart manager and listener
    {NewBaseUrl, _NewMgrPid} = restart_manager_and_listener(Config),
    %% Session should be rebuilt from the store on first access
    {ok, _Body, _Headers, Status} = do_ping(NewBaseUrl, SessionId),
    ?assertEqual(200, Status),
    %% Verify the on_rebuild callback fired
    SessionIdBin = list_to_binary(SessionId),
    receive
        {rebuilt, SessionIdBin} -> ok
    after 2000 ->
        ct:fail("on_rebuild callback not fired for ~s", [SessionId])
    end.

%% 2. Create session, wait for TTL expiry, kill manager, restart,
%%    verify session is NOT rebuilt.
expired_session_not_rebuilt(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    ?assertMatch({ok, _, _, 200}, do_ping(BaseUrl, SessionId)),
    %% Stop listener first, then kill manager
    stop_listener_and_manager(Config),
    %% Wait beyond the 1-second TTL (session_idle_timeout = 1000ms).
    %% The store's lookup will reject the expired entry on restart.
    timer:sleep(2500),
    %% Restart manager and listener
    {NewBaseUrl, _NewMgrPid} = restart_manager_and_listener(Config),
    %% Session should be gone -- TTL expired in the store
    {ok, _Body, _Headers, Status} = do_ping(NewBaseUrl, SessionId),
    ?assertEqual(404, Status).

%% 3. Create session, DELETE it via HTTP, kill manager, restart,
%%    verify session is NOT rebuilt (store entry was removed).
clean_close_removes_from_store(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    %% DELETE the session (clean close)
    {ok, {{_, 200, _}, _, _}} = httpc:request(delete,
        {BaseUrl ++ "/mcp", [{"mcp-session-id", SessionId}]},
        [], [{body_format, binary}]),
    %% Stop listener and manager
    stop_listener_and_manager(Config),
    %% Restart manager and listener
    {NewBaseUrl, _NewMgrPid} = restart_manager_and_listener(Config),
    %% Session should NOT be rebuilt -- was explicitly deleted
    {ok, _Body, _Headers, Status} = do_ping(NewBaseUrl, SessionId),
    ?assertEqual(404, Status).

%% 4. Create and persist a session, kill manager, restart, then spawn
%%    two concurrent get_session calls for the same ID. Both must
%%    succeed and return the same pid (serialized by the gen_server).
concurrent_rebuild_same_id(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    ?assertMatch({ok, _, _, 200}, do_ping(BaseUrl, SessionId)),
    SessionIdBin = list_to_binary(SessionId),
    %% Stop listener and manager
    stop_listener_and_manager(Config),
    %% Restart manager (no cowboy needed -- uses direct API)
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    %% Spawn two concurrent get_session calls
    Parent = self(),
    Ref1 = make_ref(),
    Ref2 = make_ref(),
    spawn_link(fun() ->
        Result = erl_mcp_server_session_manager:get_session(SessionIdBin),
        Parent ! {Ref1, Result}
    end),
    spawn_link(fun() ->
        Result = erl_mcp_server_session_manager:get_session(SessionIdBin),
        Parent ! {Ref2, Result}
    end),
    %% Collect results
    Result1 = receive {Ref1, R1} -> R1 after 5000 -> ct:fail("timeout on get_session 1") end,
    Result2 = receive {Ref2, R2} -> R2 after 5000 -> ct:fail("timeout on get_session 2") end,
    %% Both must succeed
    ?assertMatch({ok, _}, Result1),
    ?assertMatch({ok, _}, Result2),
    {ok, Pid1} = Result1,
    {ok, Pid2} = Result2,
    %% Both must return the same pid (second call finds it in-memory
    %% after the first call rebuilt and registered it).
    ?assertEqual(Pid1, Pid2).

%% 5. Create session (persisted), kill the session process directly
%%    (not via remove_session). The DOWN monitor removes it from the
%%    in-memory map but NOT from the store. Then call get_session and
%%    verify it rebuilds from the store.
session_process_dies_after_persist(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    SessionIdBin = list_to_binary(SessionId),
    %% Get the session pid
    {ok, OrigPid} = erl_mcp_server_session_manager:get_session(SessionIdBin),
    ?assert(is_process_alive(OrigPid)),
    %% Kill the session process directly (simulates a crash)
    exit(OrigPid, kill),
    %% Give the manager time to process the DOWN message
    timer:sleep(200),
    ?assertNot(is_process_alive(OrigPid)),
    %% get_session should rebuild from the store
    {ok, NewPid} = erl_mcp_server_session_manager:get_session(SessionIdBin),
    ?assert(is_process_alive(NewPid)),
    ?assertNotEqual(OrigPid, NewPid),
    %% Rebuilt session should be functional (ping via HTTP)
    {ok, _Body, _Headers, Status} = do_ping(BaseUrl, SessionId),
    ?assertEqual(200, Status).

%% 6. Start manager without any store configured. Create session, kill
%%    manager, restart. Session should be gone (no persistence = old
%%    behavior baseline).
no_store_configured_unchanged_behavior(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    SessionId = do_initialize(BaseUrl),
    ?assertMatch({ok, _, _, 200}, do_ping(BaseUrl, SessionId)),
    %% Stop listener and manager
    stop_listener_and_manager(Config),
    %% Restart manager and listener (env was unset in init_per_testcase
    %% so manager starts without a store)
    {NewBaseUrl, _NewMgrPid} = restart_manager_and_listener(Config),
    %% Session should be gone
    {ok, _Body, _Headers, Status} = do_ping(NewBaseUrl, SessionId),
    ?assertEqual(404, Status).

%% 7. Create a session, initialize it via the full handshake, then
%%    call promote/2 on it. Must return {error, already_initialized}.
promote_already_initialized_returns_error(_Config) ->
    %% Start a bare session with handlers -- no cowboy needed
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{}),
    ServerInfo = #implementation{name = <<"test">>, version = <<"0">>},
    Opts = #{
        role => server,
        handlers => #{},
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    },
    {ok, Pid} = erl_mcp_server_session:start_link(Opts),
    %% Promote the first time should succeed
    Meta = #{
        client_info => #{name => <<"test-client">>, version => <<"1.0">>},
        client_capabilities => #{}
    },
    ?assertEqual(ok, erl_mcp_server_session:promote(Pid, Meta)),
    %% Verify it is now initialized
    Info = erl_mcp_server_session:get_state(Pid),
    ?assertEqual(initialized, maps:get(status, Info)),
    %% Second promote must fail
    ?assertEqual({error, already_initialized},
                 erl_mcp_server_session:promote(Pid, Meta)),
    gen_server:stop(Pid).

%%--------------------------------------------------------------------
%% Internal helpers
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

%% Kill all session processes tracked by the session manager.
%% Falls back to a no-op if the manager is already dead.
kill_all_sessions() ->
    case whereis(erl_mcp_server_session_manager) of
        undefined ->
            ok;
        _ ->
            try erl_mcp_server_session_manager:list_sessions() of
                Ids ->
                    lists:foreach(fun(Id) ->
                        case (catch erl_mcp_server_session_manager:get_session(Id)) of
                            {ok, Pid} when is_pid(Pid) ->
                                catch gen_server:stop(Pid, shutdown, 1000);
                            _ ->
                                ok
                        end
                    end, Ids)
            catch
                _:_ -> ok
            end
    end.

%% Stop the cowboy listener and kill the session manager cleanly.
%% Returns the handler state needed to restart cowboy afterward.
stop_listener_and_manager(Config) ->
    catch cowboy:stop_listener(test_persist2_listener),
    kill_all_sessions(),
    MgrPid = proplists:get_value(mgr_pid, Config),
    gen_server:stop(MgrPid, shutdown, 5000),
    ok.

%% Restart the session manager and cowboy listener after a
%% stop_listener_and_manager/1 call. Returns the new BaseUrl.
restart_manager_and_listener(Config) ->
    {ok, NewMgrPid} = erl_mcp_server_session_manager:start_link(),
    unlink(NewMgrPid),
    HandlerState = proplists:get_value(handler_state, Config),
    Dispatch = cowboy_router:compile([
        {'_', [{"/mcp", erl_mcp_server_http_handler, HandlerState}]}
    ]),
    {ok, _} = cowboy:start_clear(test_persist2_listener,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(test_persist2_listener),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port),
    {BaseUrl, NewMgrPid}.

ensure_store_table() ->
    case ets:info(test_memory_store_table) of
        undefined ->
            ets:new(test_memory_store_table, [named_table, public, set]);
        _ ->
            ets:delete_all_objects(test_memory_store_table),
            ok
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
