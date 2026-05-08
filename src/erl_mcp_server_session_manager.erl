-module(erl_mcp_server_session_manager).
%% @doc false
%% Internal module -- session lifecycle tracking for {@link erl_mcp_server_http_handler}.
-behaviour(gen_server).

-export([start_link/0]).
-export([create_session/1, get_session/1, remove_session/1, list_sessions/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    sessions = #{} :: #{binary() => pid()},
    monitors = #{} :: #{reference() => binary()}
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

init([]) ->
    {ok, #state{}}.

handle_call({create_session, Opts}, _From, State) ->
    case erl_mcp_server_session:start_link(Opts) of
        {ok, Pid} ->
            unlink(Pid),
            Info = erl_mcp_server_session:get_state(Pid),
            SessionId = maps:get(id, Info),
            MonRef = monitor(process, Pid),
            Sessions = maps:put(SessionId, Pid, State#state.sessions),
            Monitors = maps:put(MonRef, SessionId, State#state.monitors),
            NewState = State#state{sessions = Sessions, monitors = Monitors},
            {reply, {ok, SessionId, Pid}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({get_session, SessionId}, _From, State) ->
    case maps:get(SessionId, State#state.sessions, undefined) of
        undefined -> {reply, {error, not_found}, State};
        Pid -> {reply, {ok, Pid}, State}
    end;

handle_call({remove_session, SessionId}, _From, State) ->
    case maps:take(SessionId, State#state.sessions) of
        {Pid, Sessions} ->
            gen_server:stop(Pid, shutdown, 5000),
            NewState = State#state{sessions = Sessions},
            {reply, ok, NewState};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(list_sessions, _From, State) ->
    {reply, maps:keys(State#state.sessions), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, _Pid, _Reason}, State) ->
    case maps:take(MonRef, State#state.monitors) of
        {SessionId, Monitors} ->
            Sessions = maps:remove(SessionId, State#state.sessions),
            {noreply, State#state{sessions = Sessions, monitors = Monitors}};
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
