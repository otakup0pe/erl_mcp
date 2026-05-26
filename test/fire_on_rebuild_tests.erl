-module(fire_on_rebuild_tests).
-include_lib("eunit/include/eunit.hrl").

%% MFA callback targets invoked via apply/3 in fire_on_rebuild tests
-export([mfa_test_helper/2, mfa_no_extra_helper/1]).

%%--------------------------------------------------------------------
%% fire_on_rebuild/2 unit tests
%%--------------------------------------------------------------------

undefined_callback_is_noop_test() ->
    ?assertEqual(ok, erl_mcp_server_session_manager:fire_on_rebuild(
                       undefined, <<"session-1">>)).

fun_callback_receives_session_id_test() ->
    Self = self(),
    Fun = fun(SessionId) -> Self ! {got, SessionId}, ok end,
    ?assertEqual(ok, erl_mcp_server_session_manager:fire_on_rebuild(
                       Fun, <<"session-2">>)),
    receive
        {got, <<"session-2">>} -> ok
    after 1000 ->
        ?assert(false)
    end.

fun_callback_crash_is_caught_test() ->
    Fun = fun(_) -> error(boom) end,
    ?assertEqual(ok, erl_mcp_server_session_manager:fire_on_rebuild(
                       Fun, <<"session-3">>)).

mfa_callback_invoked_with_session_id_prepended_test() ->
    Self = self(),
    ets:new(fire_test, [named_table, public, set]),
    ets:insert(fire_test, {pid, Self}),
    Cb = {?MODULE, mfa_test_helper, [extra_arg]},
    ?assertEqual(ok, erl_mcp_server_session_manager:fire_on_rebuild(
                       Cb, <<"session-4">>)),
    receive
        {mfa_called, <<"session-4">>, extra_arg} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ets:delete(fire_test).

mfa_callback_crash_is_caught_test() ->
    Cb = {erlang, error, [kaboom]},
    ?assertEqual(ok, erl_mcp_server_session_manager:fire_on_rebuild(
                       Cb, <<"session-5">>)).

mfa_callback_empty_args_test() ->
    Self = self(),
    ets:new(fire_test2, [named_table, public, set]),
    ets:insert(fire_test2, {pid, Self}),
    Cb = {?MODULE, mfa_no_extra_helper, []},
    ?assertEqual(ok, erl_mcp_server_session_manager:fire_on_rebuild(
                       Cb, <<"session-6">>)),
    receive
        {mfa_no_extra, <<"session-6">>} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ets:delete(fire_test2).

%%--------------------------------------------------------------------
%% MFA callback targets
%%--------------------------------------------------------------------

mfa_test_helper(SessionId, Extra) ->
    [{pid, Pid}] = ets:lookup(fire_test, pid),
    Pid ! {mfa_called, SessionId, Extra},
    ok.

mfa_no_extra_helper(SessionId) ->
    [{pid, Pid}] = ets:lookup(fire_test2, pid),
    Pid ! {mfa_no_extra, SessionId},
    ok.
