-module(session_adversarial_SUITE).
-compile(nowarn_export_all).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("erl_mcp.hrl").

%%--------------------------------------------------------------------
%% Suite setup
%%--------------------------------------------------------------------

all() ->
    [persist_error_no_crash,
     persist_dets_error_no_crash,
     persist_table_gone_no_crash,
     remove_error_no_crash,
     remove_dets_error_no_crash,
     remove_table_gone_no_crash,
     notify_timeout_no_crash,
     monitor_before_unlink,
     idle_timeout_cleans_store,
     rebuild_after_idle_no_zombie,
     promote_failure_cleans_monitor,
     concurrent_get_session_same_id].

init_per_suite(Config) ->
    application:stop(erl_mcp),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    broken_store:reset(),
    stop_manager(),
    application:set_env(erl_mcp, session_idle_timeout, 1800000),
    Config.

end_per_testcase(_TC, _Config) ->
    broken_store:reset(),
    stop_manager(),
    application:unset_env(erl_mcp, session_store),
    application:unset_env(erl_mcp, session_opts_template),
    application:unset_env(erl_mcp, on_session_rebuild),
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

%% Store returns {error, _} from persist — manager must survive
persist_error_no_crash(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    {ok, SessionId, Pid} = create_and_initialize(),
    ?assert(is_process_alive(Pid)),
    broken_store:set_mode(error_tuple, persist),
    {ok, _SessionId2, Pid2} = create_and_initialize(),
    ?assert(is_process_alive(Pid2)),
    ?assert(is_process_alive(whereis(erl_mcp_server_session_manager))),
    %% First session still alive
    ?assert(is_process_alive(Pid)),
    ?assertMatch({ok, Pid}, erl_mcp_server_session_manager:get_session(SessionId)).

%% DETS file error in persist (badmatch on storage op) — manager must survive
persist_dets_error_no_crash(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(crash, persist),
    {ok, _SessionId, Pid} = create_and_initialize(),
    ?assert(is_process_alive(Pid)),
    ?assert(is_process_alive(whereis(erl_mcp_server_session_manager))).

%% ETS table vanishes under the store — manager must survive
persist_table_gone_no_crash(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(table_gone, persist),
    {ok, _SessionId, Pid} = create_and_initialize(),
    ?assert(is_process_alive(Pid)),
    ?assert(is_process_alive(whereis(erl_mcp_server_session_manager))).

%% Store returns {error, _} from remove — manager must survive
remove_error_no_crash(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    {ok, SessionId, _Pid} = create_and_initialize(),
    broken_store:set_mode(error_tuple, remove),
    Result = erl_mcp_server_session_manager:remove_session(SessionId),
    ?assertEqual(ok, Result),
    ?assert(is_process_alive(whereis(erl_mcp_server_session_manager))).

%% DETS file error in remove — manager must survive
remove_dets_error_no_crash(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    {ok, SessionId, _Pid} = create_and_initialize(),
    broken_store:set_mode(crash, remove),
    Result = erl_mcp_server_session_manager:remove_session(SessionId),
    ?assertEqual(ok, Result),
    ?assert(is_process_alive(whereis(erl_mcp_server_session_manager))).

%% ETS table vanishes during remove — manager must survive
remove_table_gone_no_crash(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    {ok, SessionId, _Pid} = create_and_initialize(),
    broken_store:set_mode(table_gone, remove),
    Result = erl_mcp_server_session_manager:remove_session(SessionId),
    ?assertEqual(ok, Result),
    ?assert(is_process_alive(whereis(erl_mcp_server_session_manager))).

%% Session survives when manager is slow (simulates timeout in notify)
notify_timeout_no_crash(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(slow, persist),
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{}),
    ServerInfo = #implementation{name = <<"test-adversarial">>,
                                 version = <<"1.0.0">>},
    {ok, _SessionId, Pid} = erl_mcp_server_session_manager:create_session(
        #{role => server,
          server_info => ServerInfo,
          server_capabilities => ServerCaps}),
    InitMsg = init_request(1),
    %% This will trigger notify_initialized which hits the slow store.
    %% The session should NOT crash — it catches the timeout.
    Result = erl_mcp_server_session:handle_message(Pid, InitMsg),
    ?assertMatch({reply, _}, Result),
    ?assert(is_process_alive(Pid)).

%% Verify monitor is established before unlink (session can't disappear unnoticed)
monitor_before_unlink(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    {ok, SessionId, Pid} = erl_mcp_server_session_manager:create_session(
        #{role => server}),
    %% Kill session abruptly
    exit(Pid, kill),
    timer:sleep(100),
    %% Manager should have noticed and cleaned up
    ?assertEqual({error, not_found},
                 erl_mcp_server_session_manager:get_session(SessionId)).

%% Session that idle-times out gets removed from store
idle_timeout_cleans_store(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    application:set_env(erl_mcp, session_idle_timeout, 200),
    {ok, SessionId, Pid} = create_and_initialize(),
    ?assert(is_process_alive(Pid)),
    %% Wait for idle timeout
    timer:sleep(400),
    ?assertNot(is_process_alive(Pid)),
    %% Store entry should be gone — rebuild should fail
    ?assertEqual({error, not_found},
                 erl_mcp_server_session_manager:get_session(SessionId)),
    application:set_env(erl_mcp, session_idle_timeout, 1800000).

%% After idle timeout + store cleanup, no zombie rebuild loop
rebuild_after_idle_no_zombie(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    application:set_env(erl_mcp, session_idle_timeout, 200),
    {ok, SessionId, Pid} = create_and_initialize(),
    ?assert(is_process_alive(Pid)),
    timer:sleep(400),
    ?assertNot(is_process_alive(Pid)),
    %% Multiple lookups should all return not_found, not spawn zombies
    ?assertEqual({error, not_found},
                 erl_mcp_server_session_manager:get_session(SessionId)),
    ?assertEqual({error, not_found},
                 erl_mcp_server_session_manager:get_session(SessionId)),
    ?assertEqual({error, not_found},
                 erl_mcp_server_session_manager:get_session(SessionId)),
    %% No orphaned sessions
    ?assertEqual([], erl_mcp_server_session_manager:list_sessions()),
    application:set_env(erl_mcp, session_idle_timeout, 1800000).

%% Promote failure demonitors and cleans up
promote_failure_cleans_monitor(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    {ok, _SessionId, Pid} = create_and_initialize(),
    ?assert(is_process_alive(Pid)),
    %% Kill session so it's gone from memory
    exit(Pid, kill),
    timer:sleep(100),
    %% Verify the manager cleaned up — no leaked monitors
    ?assertEqual([], erl_mcp_server_session_manager:list_sessions()).

%% Concurrent get_session calls for same persisted ID don't create orphans
concurrent_get_session_same_id(_Config) ->
    start_manager_with_broken_store(),
    broken_store:set_mode(normal),
    application:set_env(erl_mcp, session_idle_timeout, 300000),
    {ok, SessionId, Pid} = create_and_initialize(),
    %% Kill session to force rebuild path
    exit(Pid, kill),
    timer:sleep(100),
    %% Concurrent lookups (serialized by gen_server, but exercises the path)
    Self = self(),
    lists:foreach(fun(_) ->
        spawn(fun() ->
            Result = erl_mcp_server_session_manager:get_session(SessionId),
            Self ! {lookup_result, Result}
        end)
    end, lists:seq(1, 5)),
    Results = collect_results(5, []),
    %% All should succeed with the same pid (or first succeeds, rest find in memory)
    OkResults = [P || {ok, P} <- Results],
    ?assert(length(OkResults) >= 1),
    UniquePids = lists:usort(OkResults),
    ?assertEqual(1, length(UniquePids)),
    %% Only one session in the manager
    ?assertEqual(1, length(erl_mcp_server_session_manager:list_sessions())),
    application:set_env(erl_mcp, session_idle_timeout, 1800000).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

start_manager_with_broken_store() ->
    application:set_env(erl_mcp, session_store, {broken_store, #{}}),
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{}),
    ServerInfo = #implementation{name = <<"test-adversarial">>,
                                 version = <<"1.0.0">>},
    application:set_env(erl_mcp, session_opts_template,
                        #{role => server,
                          server_info => ServerInfo,
                          server_capabilities => ServerCaps}),
    {ok, Pid} = erl_mcp_server_session_manager:start_link(),
    unlink(Pid),
    ok.

stop_manager() ->
    case whereis(erl_mcp_server_session_manager) of
        undefined -> ok;
        Pid ->
            catch unlink(Pid),
            MRef = monitor(process, Pid),
            exit(Pid, kill),
            receive {'DOWN', MRef, process, _, _} -> ok
            after 2000 -> ok
            end
    end.

create_and_initialize() ->
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{}),
    ServerInfo = #implementation{name = <<"test-adversarial">>,
                                 version = <<"1.0.0">>},
    {ok, SessionId, Pid} = erl_mcp_server_session_manager:create_session(
        #{role => server,
          server_info => ServerInfo,
          server_capabilities => ServerCaps}),
    InitMsg = init_request(1),
    {reply, _} = erl_mcp_server_session:handle_message(Pid, InitMsg),
    {ok, SessionId, Pid}.

init_request(Id) ->
    #jsonrpc_request{
        id = Id,
        method = <<"initialize">>,
        params = #{
            <<"protocolVersion">> => <<"2025-03-26">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{
                <<"name">> => <<"adversarial-test">>,
                <<"version">> => <<"1.0.0">>
            }
        }
    }.

collect_results(0, Acc) -> Acc;
collect_results(N, Acc) ->
    receive
        {lookup_result, Result} -> collect_results(N - 1, [Result | Acc])
    after 5000 ->
        Acc
    end.
