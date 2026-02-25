-module(mcp_transport).

%% Transport behaviour for MCP.
%% Abstracts stdio vs HTTP. Protocol logic never touches transport directly.

-callback send(Message :: term(), State :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

-callback recv(State :: term()) ->
    {ok, Message :: term(), NewState :: term()} |
    {error, Reason :: term()}.

-callback close(State :: term()) -> ok.
