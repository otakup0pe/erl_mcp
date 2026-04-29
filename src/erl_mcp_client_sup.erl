-module(erl_mcp_client_sup).

%% @doc Supervisor for dynamic MCP client pools.
%%
%% Uses `simple_one_for_one' strategy. Add to your supervision tree,
%% then spawn clients with {@link start_client/2}.

-behaviour(supervisor).

-export([start_link/0, start_link/1]).
-export([start_client/1, start_client/2, stop_client/2]).
-export([init/1]).

%% @doc Start an unregistered client supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

%% @doc Start a named client supervisor.
-spec start_link({local, atom()} | {global, term()} | {via, module(), term()}) ->
    {ok, pid()} | {error, term()}.
start_link(Name) ->
    supervisor:start_link(Name, ?MODULE, []).

%% @doc Start a client under the default supervisor.
-spec start_client(map()) -> supervisor:startchild_ret().
start_client(Config) ->
    start_client(?MODULE, Config).

%% @doc Start a client under the given supervisor.
-spec start_client(supervisor:sup_ref(), map()) ->
    supervisor:startchild_ret().
start_client(Sup, Config) ->
    supervisor:start_child(Sup, [Config]).

%% @doc Stop a client by pid.
-spec stop_client(supervisor:sup_ref(), pid()) -> ok | {error, term()}.
stop_client(Sup, Pid) ->
    supervisor:terminate_child(Sup, Pid).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 10
    },
    ChildSpec = #{
        id => erl_mcp_client,
        start => {erl_mcp_client, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [erl_mcp_client]
    },
    {ok, {SupFlags, [ChildSpec]}}.
