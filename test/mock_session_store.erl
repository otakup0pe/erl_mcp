-module(mock_session_store).
-behaviour(erl_mcp_server_session_store).

-export([init/1, persist/3, lookup/2, remove/2, prune/2, touch/2]).

-define(TABLE, mock_session_store_table).

init(_Opts) ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]);
        _ ->
            ok
    end,
    {ok, #{}}.

persist(SessionId, Meta, State) ->
    Now = erlang:system_time(second),
    ets:insert(?TABLE, {SessionId, Meta, Now, Now}),
    {ok, State}.

lookup(SessionId, State) ->
    case ets:lookup(?TABLE, SessionId) of
        [{SessionId, Meta, _CreatedAt, LastSeenAt}] ->
            MaxAge = application:get_env(erl_mcp,
                session_idle_timeout, 1800000) div 1000,
            Now = erlang:system_time(second),
            case (Now - LastSeenAt) =< MaxAge of
                true ->
                    ets:insert(?TABLE,
                        {SessionId, Meta, _CreatedAt, Now}),
                    {ok, Meta, State};
                false ->
                    ets:delete(?TABLE, SessionId),
                    {not_found, State}
            end;
        [] ->
            {not_found, State}
    end.

remove(SessionId, State) ->
    ets:delete(?TABLE, SessionId),
    {ok, State}.

prune(MaxAgeSecs, State) ->
    Now = erlang:system_time(second),
    Cutoff = Now - MaxAgeSecs,
    All = ets:tab2list(?TABLE),
    Pruned = lists:foldl(fun({Id, _Meta, _Created, LastSeen}, Count) ->
        case LastSeen < Cutoff of
            true ->
                ets:delete(?TABLE, Id),
                Count + 1;
            false ->
                Count
        end
    end, 0, All),
    {Pruned, State}.

touch(SessionId, State) ->
    Now = erlang:system_time(second),
    case ets:lookup(?TABLE, SessionId) of
        [{SessionId, Meta, CreatedAt, _OldLastSeen}] ->
            ets:insert(?TABLE, {SessionId, Meta, CreatedAt, Now}),
            {ok, State};
        [] ->
            {ok, State}
    end.
