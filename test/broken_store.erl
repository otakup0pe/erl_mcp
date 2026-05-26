-module(broken_store).
-behaviour(erl_mcp_server_session_store).

%% A store that can be configured to fail in various ways.
%% Set failure modes via process dictionary or ETS before calling.

-export([init/1, persist/3, lookup/2, remove/2, prune/2, touch/2]).
-export([set_mode/1, set_mode/2, reset/0]).

-define(TABLE, broken_store_table).
-define(CTL, broken_store_ctl).

set_mode(Mode) ->
    set_mode(Mode, all).

set_mode(Mode, Op) ->
    case ets:info(?CTL) of
        undefined -> ets:new(?CTL, [named_table, public, set]);
        _ -> ok
    end,
    ets:insert(?CTL, {Op, Mode}),
    ok.

reset() ->
    catch ets:delete(?CTL),
    catch ets:delete(?TABLE),
    ok.

init(_Opts) ->
    case ets:info(?TABLE) of
        undefined -> ets:new(?TABLE, [named_table, public, set]);
        _ -> ok
    end,
    {ok, #{}}.

persist(SessionId, Meta, State) ->
    case get_mode(persist) of
        normal ->
            Now = erlang:system_time(second),
            ets:insert(?TABLE, {SessionId, Meta, Now, Now}),
            {ok, State};
        error_tuple ->
            {error, store_unavailable};
        crash ->
            %% Simulate DETS file error (badmatch on failed write)
            error({badmatch, {error, {file_error, "/tmp/gone", enospc}}});
        table_gone ->
            %% Simulate ETS table deleted out from under us
            ets:insert(nonexistent_table, {SessionId, Meta}),
            {ok, State};
        slow ->
            timer:sleep(6000),
            Now = erlang:system_time(second),
            ets:insert(?TABLE, {SessionId, Meta, Now, Now}),
            {ok, State}
    end.

lookup(SessionId, State) ->
    case get_mode(lookup) of
        normal ->
            case ets:lookup(?TABLE, SessionId) of
                [{SessionId, Meta, _CreatedAt, _LastActive}] ->
                    {ok, Meta, State};
                [] ->
                    {not_found, State}
            end;
        error_tuple ->
            {not_found, State};
        crash ->
            error(deliberate_crash)
    end.

remove(SessionId, State) ->
    case get_mode(remove) of
        normal ->
            ets:delete(?TABLE, SessionId),
            {ok, State};
        error_tuple ->
            {error, store_unavailable};
        crash ->
            error({badmatch, {error, {file_error, "/tmp/gone", enospc}}});
        table_gone ->
            ets:delete(nonexistent_table, SessionId),
            {ok, State}
    end.

prune(_MaxAgeSecs, State) ->
    {0, State}.

touch(SessionId, State) ->
    case get_mode(touch) of
        normal ->
            Now = erlang:system_time(second),
            case ets:lookup(?TABLE, SessionId) of
                [{SessionId, Meta, CreatedAt, _OldLastActive}] ->
                    ets:insert(?TABLE, {SessionId, Meta, CreatedAt, Now}),
                    {ok, State};
                [] ->
                    {ok, State}
            end;
        error_tuple ->
            {error, store_unavailable};
        crash ->
            error({badmatch, {error, {file_error, "/tmp/gone", enospc}}});
        table_gone ->
            ets:insert(nonexistent_table, {SessionId, dummy}),
            {ok, State}
    end.

get_mode(Op) ->
    case ets:info(?CTL) of
        undefined -> normal;
        _ ->
            case ets:lookup(?CTL, Op) of
                [{Op, Mode}] -> Mode;
                [] ->
                    case ets:lookup(?CTL, all) of
                        [{all, Mode}] -> Mode;
                        [] -> normal
                    end
            end
    end.
