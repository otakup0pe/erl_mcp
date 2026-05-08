-module(erl_mcp_app).
%% @doc false
%% OTP infrastructure -- not part of the public API.
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    erl_mcp_sup:start_link().

stop(_State) ->
    ok.
