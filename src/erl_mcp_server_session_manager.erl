-module(erl_mcp_server_session_manager).
%% @doc false
%% Internal module -- session lifecycle tracking for {@link erl_mcp_server_http_handler}.
%%
%% Optionally integrates with a session store (implementing the
%% {@link erl_mcp_server_session_store} behaviour) to persist
%% session IDs across server restarts. When a lookup misses in
%% memory but finds a persisted entry, the manager transparently
%% rebuilds the session process and promotes it to initialized.
-behaviour(gen_server).

-export([start_link/0]).
-export([create_session/1, get_session/1, remove_session/1, list_sessions/0,
         update_opts_template/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    sessions = #{} :: #{binary() => pid()},
    monitors = #{} :: #{reference() => binary()},
    store = undefined :: undefined | {module(), term()},
    session_opts_template = #{} :: map(),
    on_rebuild = undefined :: undefined | fun((binary()) -> any())
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec create_session(map()) -> {ok, binary(), pid()} | {error, term()}.
create_session(Opts) ->
    gen_server:call(?MODULE, {create_session, Opts}).

-spec get_session(binary()) -> {ok, pid()} | {error, not_found}.
get_session(SessionId) ->
    gen_server:call(?MODULE, {get_session, SessionId}).

-spec remove_session(binary()) -> ok | {error, not_found}.
remove_session(SessionId) ->
    gen_server:call(?MODULE, {remove_session, SessionId}).

-spec list_sessions() -> [binary()].
list_sessions() ->
    gen_server:call(?MODULE, list_sessions).

-spec update_opts_template(map()) -> ok.
update_opts_template(Template) when is_map(Template) ->
    gen_server:cast(?MODULE, {update_opts_template, Template}).

init([]) ->
    StoreConfig = application:get_env(erl_mcp, session_store, undefined),
    OnRebuild = application:get_env(erl_mcp, on_session_rebuild, undefined),
    OptsTemplate = application:get_env(erl_mcp, session_opts_template, #{}),
    Store = init_store(StoreConfig),
    PruneInterval = application:get_env(erl_mcp, session_store_prune_interval,
                                        3600000),
    case Store of
        undefined -> ok;
        _ -> erlang:send_after(PruneInterval, self(), prune_store)
    end,
    {ok, #state{store = Store,
                on_rebuild = OnRebuild,
                session_opts_template = OptsTemplate}}.

handle_call({create_session, Opts}, _From, State) ->
    case erl_mcp_server_session:start_link(Opts) of
        {ok, Pid} ->
            MonRef = monitor(process, Pid),
            unlink(Pid),
            Info = erl_mcp_server_session:get_state(Pid),
            SessionId = maps:get(id, Info),
            Sessions = maps:put(SessionId, Pid, State#state.sessions),
            Monitors = maps:put(MonRef, SessionId, State#state.monitors),
            NewState = State#state{sessions = Sessions, monitors = Monitors},
            {reply, {ok, SessionId, Pid}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({get_session, SessionId}, _From, State) ->
    case maps:get(SessionId, State#state.sessions, undefined) of
        undefined ->
            case try_rebuild(SessionId, State) of
                {ok, Pid, NewState} ->
                    {reply, {ok, Pid}, NewState};
                {error, not_found, NewState} ->
                    {reply, {error, not_found}, NewState}
            end;
        Pid ->
            {reply, {ok, Pid}, State}
    end;

handle_call({remove_session, SessionId}, _From, State) ->
    case maps:take(SessionId, State#state.sessions) of
        {Pid, Sessions} ->
            gen_server:stop(Pid, shutdown, 5000),
            State1 = State#state{sessions = Sessions},
            State2 = store_remove(SessionId, State1),
            {reply, ok, State2};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(list_sessions, _From, State) ->
    {reply, maps:keys(State#state.sessions), State};

handle_call({session_initialized, SessionId, Meta}, _From, State) ->
    {reply, ok, store_persist(SessionId, Meta, State)};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({update_opts_template, Template}, State) ->
    logger:info("session_manager: opts template updated"),
    {noreply, State#state{session_opts_template = Template}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, _Pid, Reason}, State) ->
    case maps:take(MonRef, State#state.monitors) of
        {SessionId, Monitors} ->
            Sessions = maps:remove(SessionId, State#state.sessions),
            State1 = State#state{sessions = Sessions, monitors = Monitors},
            State2 = maybe_remove_on_shutdown(Reason, SessionId, State1),
            {noreply, State2};
        error ->
            {noreply, State}
    end;

handle_info(prune_store, #state{store = undefined} = State) ->
    {noreply, State};
handle_info(prune_store, #state{store = {Mod, StoreState}} = State) ->
    MaxAge = application:get_env(erl_mcp, session_idle_timeout, 1800000)
             div 1000,
    {Pruned, StoreState1} = Mod:prune(MaxAge, StoreState),
    case Pruned > 0 of
        true ->
            logger:info("session_manager: pruned ~B expired sessions "
                        "from store", [Pruned]);
        false -> ok
    end,
    PruneInterval = application:get_env(erl_mcp, session_store_prune_interval,
                                        3600000),
    erlang:send_after(PruneInterval, self(), prune_store),
    {noreply, State#state{store = {Mod, StoreState1}}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

init_store(undefined) ->
    undefined;
init_store({Mod, Opts}) ->
    case Mod:init(Opts) of
        {ok, StoreState} ->
            MaxAge = application:get_env(erl_mcp, session_idle_timeout,
                                         1800000) div 1000,
            {Pruned, StoreState1} = Mod:prune(MaxAge, StoreState),
            case Pruned > 0 of
                true ->
                    logger:info("session_manager: pruned ~B expired "
                                "sessions on startup", [Pruned]);
                false -> ok
            end,
            {Mod, StoreState1};
        {error, Reason} ->
            logger:warning("session_manager: store init failed: ~p; "
                           "running without persistence", [Reason]),
            undefined
    end.

store_persist(_SessionId, _Meta, #state{store = undefined} = State) ->
    State;
store_persist(SessionId, Meta, #state{store = {Mod, StoreState}} = State) ->
    try Mod:persist(SessionId, Meta, StoreState) of
        {ok, StoreState1} ->
            State#state{store = {Mod, StoreState1}};
        {error, Reason} ->
            logger:warning("session_manager: persist failed for ~s: ~p",
                           [SessionId, Reason]),
            State
    catch
        error:badarg ->
            logger:warning("session_manager: persist store table missing "
                           "for ~s", [SessionId]),
            State;
        error:{badmatch, {error, DetsErr}} ->
            logger:warning("session_manager: persist storage error for "
                           "~s: ~p", [SessionId, DetsErr]),
            State
    end.

store_remove(_SessionId, #state{store = undefined} = State) ->
    State;
store_remove(SessionId, #state{store = {Mod, StoreState}} = State) ->
    try Mod:remove(SessionId, StoreState) of
        {ok, StoreState1} ->
            State#state{store = {Mod, StoreState1}};
        {error, Reason} ->
            logger:warning("session_manager: remove failed for ~s: ~p",
                           [SessionId, Reason]),
            State
    catch
        error:badarg ->
            logger:warning("session_manager: remove store table missing "
                           "for ~s", [SessionId]),
            State;
        error:{badmatch, {error, DetsErr}} ->
            logger:warning("session_manager: remove storage error for "
                           "~s: ~p", [SessionId, DetsErr]),
            State
    end.

try_rebuild(_SessionId, #state{store = undefined} = State) ->
    {error, not_found, State};
try_rebuild(SessionId, #state{store = {Mod, StoreState},
                              session_opts_template = Template,
                              on_rebuild = OnRebuild} = State) ->
    case Mod:lookup(SessionId, StoreState) of
        {ok, Meta, StoreState1} ->
            Opts = Template#{id => SessionId},
            case erl_mcp_server_session:start_link(Opts) of
                {ok, Pid} ->
                    MonRef = monitor(process, Pid),
                    unlink(Pid),
                    case erl_mcp_server_session:promote(Pid, Meta) of
                        ok ->
                            Sessions = maps:put(SessionId, Pid,
                                                State#state.sessions),
                            Monitors = maps:put(MonRef, SessionId,
                                                State#state.monitors),
                            logger:info("session_manager: rebuilt session ~s",
                                        [SessionId]),
                            fire_on_rebuild(OnRebuild, SessionId),
                            {ok, Pid,
                             State#state{sessions = Sessions,
                                         monitors = Monitors,
                                         store = {Mod, StoreState1}}};
                        {error, Reason} ->
                            demonitor(MonRef, [flush]),
                            gen_server:stop(Pid, shutdown, 1000),
                            logger:warning("session_manager: promote "
                                           "failed for ~s: ~p",
                                           [SessionId, Reason]),
                            {error, not_found,
                             State#state{store = {Mod, StoreState1}}}
                    end;
                {error, Reason} ->
                    logger:warning("session_manager: rebuild start_link "
                                   "failed for ~s: ~p",
                                   [SessionId, Reason]),
                    {error, not_found,
                     State#state{store = {Mod, StoreState1}}}
            end;
        {not_found, StoreState1} ->
            {error, not_found, State#state{store = {Mod, StoreState1}}}
    end.

maybe_remove_on_shutdown({shutdown, idle_timeout}, SessionId, State) ->
    store_remove(SessionId, State);
maybe_remove_on_shutdown(_Reason, _SessionId, State) ->
    State.

fire_on_rebuild(undefined, _SessionId) -> ok;
fire_on_rebuild(Fun, SessionId) when is_function(Fun, 1) ->
    try Fun(SessionId)
    catch _:_ -> ok
    end.
