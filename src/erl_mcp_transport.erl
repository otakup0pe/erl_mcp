-module(erl_mcp_transport).

%% Implementations provide synchronous request/response message
%% exchange plus a close hook. Higher-level state (session id,
%% protocol negotiation, cache) lives in the client process;
%% transports only move bytes.
%%
-callback connect(Config :: map()) ->
    {ok, Handle :: term()} | {error, Reason :: term()}.

-callback request(Handle :: term(),
                  Message :: iodata(),
                  Timeout :: timeout()) ->
    {ok, Body :: binary(), NewHandle :: term()} |
    {error, Reason :: term(), NewHandle :: term()}.

-callback notify(Handle :: term(), Message :: iodata()) ->
    {ok, NewHandle :: term()} | {error, Reason :: term(), NewHandle :: term()}.

-callback close(Handle :: term()) -> ok.

-callback update_auth(Handle :: term(), Auth :: term()) ->
    {ok, NewHandle :: term()} | {error, Reason :: term()}.

-optional_callbacks([update_auth/2]).
