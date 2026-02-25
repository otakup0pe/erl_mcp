-module(mcp_tool_registry).
-behaviour(gen_server).

%% ETS-backed registry for MCP tools.
%% Supports register, unregister, lookup, and list with pagination.
%% Emits notifications/tools/list_changed on changes.

-include("mcp.hrl").

-export([start_link/0]).
-export([register_tool/2, unregister_tool/1, lookup/1, list_tools/0,
         list_tools/1]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {
    table :: ets:tid(),
    change_listeners = [] :: [pid()]
}).

-record(tool_entry, {
    name :: binary(),
    tool :: #tool{},
    handler :: fun((map(), term()) -> {ok, [term()]} | {error, binary()})
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_tool(#tool{}, fun()) -> ok | {error, already_registered}.
register_tool(Tool, Handler) ->
    gen_server:call(?MODULE, {register, Tool, Handler}).

-spec unregister_tool(binary()) -> ok | {error, not_found}.
unregister_tool(Name) ->
    gen_server:call(?MODULE, {unregister, Name}).

-spec lookup(binary()) -> {ok, #tool{}, fun()} | {error, not_found}.
lookup(Name) ->
    case ets:lookup(?MODULE, Name) of
        [#tool_entry{tool = Tool, handler = Handler}] ->
            {ok, Tool, Handler};
        [] ->
            {error, not_found}
    end.

-spec list_tools() -> [#tool{}].
list_tools() ->
    [E#tool_entry.tool || E <- ets:tab2list(?MODULE)].

-spec list_tools(map()) -> {[#tool{}], undefined | binary()}.
list_tools(#{cursor := Cursor, page_size := PageSize}) ->
    %% Cursor-based pagination. Cursor is the tool name to start after.
    All = lists:sort(fun(A, B) ->
        A#tool_entry.name =< B#tool_entry.name
    end, ets:tab2list(?MODULE)),
    Filtered = case Cursor of
        undefined -> All;
        _ -> lists:dropwhile(fun(E) -> E#tool_entry.name =< Cursor end, All)
    end,
    Page = lists:sublist(Filtered, PageSize),
    NextCursor = case length(Page) =:= PageSize andalso length(Filtered) > PageSize of
        true ->
            Last = lists:last(Page),
            Last#tool_entry.name;
        false ->
            undefined
    end,
    {[E#tool_entry.tool || E <- Page], NextCursor};
list_tools(_) ->
    {list_tools(), undefined}.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    Table = ets:new(?MODULE, [named_table, set, {keypos, #tool_entry.name},
                               protected, {read_concurrency, true}]),
    {ok, #state{table = Table}}.

handle_call({register, #tool{name = Name} = Tool, Handler}, _From, State) ->
    case ets:lookup(State#state.table, Name) of
        [_] ->
            {reply, {error, already_registered}, State};
        [] ->
            Entry = #tool_entry{name = Name, tool = Tool, handler = Handler},
            ets:insert(State#state.table, Entry),
            notify_change(State),
            {reply, ok, State}
    end;

handle_call({unregister, Name}, _From, State) ->
    case ets:lookup(State#state.table, Name) of
        [_] ->
            ets:delete(State#state.table, Name),
            notify_change(State),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

notify_change(#state{change_listeners = Listeners}) ->
    [Pid ! {mcp_tools_changed} || Pid <- Listeners, is_process_alive(Pid)],
    ok.
