-module(mcp_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    Children = [
        #{
            id => mcp_tool_registry,
            start => {mcp_tool_registry, start_link, []},
            type => worker
        },
        #{
            id => mcp_session_manager,
            start => {mcp_session_manager, start_link, []},
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
