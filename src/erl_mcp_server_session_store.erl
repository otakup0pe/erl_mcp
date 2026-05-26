-module(erl_mcp_server_session_store).

%% @doc Behaviour for pluggable MCP session persistence.
%%
%% Applications implement this behaviour to persist session IDs
%% across server restarts. When configured, the session manager
%% checks the store on lookup misses and transparently rebuilds
%% sessions from persisted state.
%%
%% `erl_mcp' does not ship a concrete implementation -- each
%% application provides its own backend (DETS, mnesia, Redis, etc.).

-callback init(Opts :: map()) -> {ok, State :: term()} | {error, term()}.

-callback persist(SessionId :: binary(), Meta :: map(),
                  State :: term()) -> {ok, State :: term()}.

-callback lookup(SessionId :: binary(), State :: term()) ->
    {ok, Meta :: map(), State :: term()} | {not_found, State :: term()}.

-callback remove(SessionId :: binary(), State :: term()) ->
    {ok, State :: term()}.

-callback prune(MaxAgeSecs :: pos_integer(), State :: term()) ->
    {Pruned :: non_neg_integer(), State :: term()}.

-callback touch(SessionId :: binary(), State :: term()) ->
    {ok, State :: term()}.

-optional_callbacks([touch/2]).
