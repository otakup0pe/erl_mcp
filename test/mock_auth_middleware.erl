-module(mock_auth_middleware).
-behaviour(cowboy_middleware).

%% Stands in for an authenticating middleware placed in front of the MCP
%% handler: resolves a caller and stashes it on the req, which is how
%% cowboy expects a middleware to hand data to downstream handlers.

-export([execute/2, principal/0]).

-define(PRINCIPAL, <<"authenticated-caller">>).

%% The principal this middleware authenticates, so tests assert against
%% the producer rather than a retyped literal.
-spec principal() -> binary().
principal() -> ?PRINCIPAL.

execute(Req, Env) ->
    {ok, Req#{auth_principal => ?PRINCIPAL}, Env}.
