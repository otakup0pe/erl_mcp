-module(erl_mcp_client_sup).
-behaviour(supervisor).

%% Optional simple_one_for_one supervisor for dynamic client children.
%% Consumers who want a dynamic set of MCP clients can include this
%% supervisor in their tree and spawn instances via start_client/2.

-export([start_link/0, start_link/1]).
-export([start_client/1, start_client/2, stop_client/2]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

-spec start_link({local, atom()} | {global, term()} | {via, module(), term()}) ->
    {ok, pid()} | {error, term()}.
start_link(Name) ->
    supervisor:start_link(Name, ?MODULE, []).

-spec start_client(map()) -> supervisor:startchild_ret().
start_client(Config) ->
    start_client(?MODULE, Config).

-spec start_client(supervisor:sup_ref(), map()) ->
    supervisor:startchild_ret().
start_client(Sup, Config) ->
    supervisor:start_child(Sup, [Config]).

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
