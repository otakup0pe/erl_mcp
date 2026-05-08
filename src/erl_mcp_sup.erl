-module(erl_mcp_sup).
%% @doc false
%% OTP infrastructure -- not part of the public API.
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
            id => erl_mcp_server_tool_registry,
            start => {erl_mcp_server_tool_registry, start_link, []},
            type => worker
        },
        #{
            id => erl_mcp_server_session_manager,
            start => {erl_mcp_server_session_manager, start_link, []},
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
