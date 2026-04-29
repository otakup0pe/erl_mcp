-module(mcp_transport).

%% @doc Server-side transport behaviour for MCP.
%%
%% Abstracts the wire format (stdio, HTTP, etc.) so protocol logic
%% never touches transport directly.

-callback send(Message :: term(), State :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

-callback recv(State :: term()) ->
    {ok, Message :: term(), NewState :: term()} |
    {error, Reason :: term()}.

-callback close(State :: term()) -> ok.
