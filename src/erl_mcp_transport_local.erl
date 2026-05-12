-module(erl_mcp_transport_local).

%% @doc Erlang-message-passing transport for MCP client/server communication.
%%
%% Implements the {@link erl_mcp_transport} behaviour by sending
%% JSON-RPC messages directly to an {@link erl_mcp_server_local}
%% process via `gen_server:call' and `gen_server:cast'.  No HTTP,
%% no serialization beyond JSON-RPC -- just Erlang message passing.
%%
%% Works **in-VM and across nodes within an Erlang cluster**.  When
%% the server lives on a different node, the underlying primitives
%% (`gen_server:call/3', `gen_server:cast/2', `monitor/2') already
%% handle remote dispatch and node-down detection -- this transport
%% just supplies the right target term.
%%
%% Config keys:
%% <ul>
%%   <li>`server_pid' -- the target {@link erl_mcp_server_local}
%%       process.  Accepted forms:
%%       <ul>
%%         <li>`pid()' (local OR remote)</li>
%%         <li>`atom()' -- locally-registered name on the current node</li>
%%         <li>`{Name :: atom(), Node :: node()}' -- registered name on
%%             a remote node within the cluster</li>
%%         <li>`{global, term()}' -- globally-registered name</li>
%%         <li>`{via, Module, Name}' -- arbitrary registry</li>
%%       </ul>
%%   </li>
%% </ul>
%%
%% Cross-node failure surfaces: when the remote server dies or its
%% node disconnects, the monitor fires `'DOWN'' to the client and
%% the next `request/3' returns `{error, server_down, ...}'.  Net
%% partitions look identical to a remote crash from the client's
%% perspective, which is the right semantic.
%%
%% Example (local):
%% ```
%% {ok, Client} = erl_mcp_client:start_link(#{
%%     transport => erl_mcp_transport_local,
%%     server_pid => MyServerPid
%% }).
%% '''
%%
%% Example (cross-node):
%% ```
%% {ok, Client} = erl_mcp_client:start_link(#{
%%     transport => erl_mcp_transport_local,
%%     server_pid => {erl_mcp_server, 'agent@host.example.com'}
%% }).
%% '''

-behaviour(erl_mcp_transport).

-export([connect/1, request/3, notify/2, close/1]).

-type server_target() :: pid()
                       | atom()
                       | {atom(), node()}
                       | {global, term()}
                       | {via, module(), term()}.

-record(handle, {
    target :: server_target(),
    monitor_ref :: reference()
}).

%% @doc Connect to a local MCP server.
%%
%% Resolves and validates the `server_pid' config and installs a
%% monitor so the client sees a `'DOWN'' if the server (or its
%% node, for cross-node targets) goes away.
-spec connect(map()) -> {ok, #handle{}} | {error, term()}.
connect(Config) ->
    case maps:find(server_pid, Config) of
        {ok, Ref} ->
            case resolve_target(Ref) of
                {ok, Target} ->
                    MonRef = monitor(process, Target),
                    {ok, #handle{target = Target, monitor_ref = MonRef}};
                {error, _} = Err ->
                    Err
            end;
        error ->
            {error, {missing_config, server_pid}}
    end.

%% @doc Send a JSON-RPC request and return the response synchronously.
-spec request(#handle{}, iodata(), timeout()) ->
    {ok, binary(), #handle{}} | {error, term(), #handle{}}.
request(#handle{target = Target} = H, Message, Timeout) ->
    Body = iolist_to_binary(Message),
    try gen_server:call(Target, {erl_mcp_local_request, Body}, Timeout) of
        {ok, RespBody} ->
            {ok, RespBody, H};
        {error, Reason} ->
            {error, Reason, H}
    catch
        exit:{noproc, _} ->
            {error, server_down, H};
        exit:{timeout, _} ->
            {error, timeout, H};
        exit:{normal, _} ->
            {error, server_down, H};
        exit:{shutdown, _} ->
            {error, server_down, H};
        exit:{{shutdown, _}, _} ->
            {error, server_down, H};
        exit:{nodedown, _} ->
            {error, server_down, H};
        exit:{{nodedown, _}, _} ->
            {error, server_down, H}
    end.

%% @doc Send a JSON-RPC notification (fire-and-forget).
-spec notify(#handle{}, iodata()) ->
    {ok, #handle{}} | {error, term(), #handle{}}.
notify(#handle{target = Target} = H, Message) ->
    Body = iolist_to_binary(Message),
    gen_server:cast(Target, {erl_mcp_local_notify, Body}),
    {ok, H}.

%% @doc Close the local transport connection.
-spec close(#handle{}) -> ok.
close(#handle{monitor_ref = MonRef}) ->
    demonitor(MonRef, [flush]),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec resolve_target(server_target()) ->
    {ok, server_target()} | {error, term()}.
resolve_target(Pid) when is_pid(Pid) ->
    case node(Pid) =:= node() of
        true ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> {error, server_down}
            end;
        false ->
            %% Remote pid: can't safely is_process_alive without an
            %% rpc round-trip, and the answer would race anyway.  The
            %% monitor catches death/disconnect; the first request
            %% fails clearly if the process is gone.
            {ok, Pid}
    end;
resolve_target(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> {error, {not_registered, Name}};
        Pid -> {ok, Pid}
    end;
resolve_target({Name, Node}) when is_atom(Name), is_atom(Node) ->
    %% Remote registered name.  Don't resolve to a pid here: that
    %% would need an rpc:call (latency) and would race with remote
    %% restart.  monitor/2, gen_server:call/3, and gen_server:cast/2
    %% all accept {Name, Node} natively and will fire `'DOWN''
    %% (or return an exit) on remote process death OR nodedown.
    {ok, {Name, Node}};
resolve_target({global, Name}) ->
    case global:whereis_name(Name) of
        undefined -> {error, {not_registered, {global, Name}}};
        Pid -> {ok, Pid}
    end;
resolve_target({via, Mod, Name}) ->
    case Mod:whereis_name(Name) of
        undefined -> {error, {not_registered, {via, Mod, Name}}};
        Pid -> {ok, Pid}
    end;
resolve_target(Other) ->
    {error, {invalid_server_pid, Other}}.
