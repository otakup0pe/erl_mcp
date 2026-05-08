# Usage Guide

## Implementing a Tool Handler

Tools are the primary extension point for MCP servers. The
`erl_mcp_server_tool_handler` behaviour defines two callbacks:

```erlang
-module(my_echo_handler).
-behaviour(erl_mcp_server_tool_handler).
-include_lib("erl_mcp/include/erl_mcp.hrl").

-export([tool_definition/0, handle_call/3]).

tool_definition() ->
    erl_mcp_server_tool:new(
        <<"echo">>,
        <<"Echoes the input text back">>,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"text">> => #{<<"type">> => <<"string">>}
          },
          <<"required">> => [<<"text">>]}
    ).

handle_call(<<"echo">>, #{<<"text">> := Text}, _Context) ->
    {ok, [erl_mcp_protocol_content:text(Text)]};
handle_call(<<"echo">>, _Args, _Context) ->
    {error, <<"Missing required argument: text">>}.
```

`handle_call/3` receives the tool name, arguments map, and a context map.
The context contains `#{session_id => BinaryId}` identifying the MCP
session that invoked the tool. It returns `{ok, ContentList}` or
`{error, Message}`. Content items are built with
`erl_mcp_protocol_content:text/1`, `erl_mcp_protocol_content:image/2`,
etc.

## Registering Tools and Starting the Server

The tool registry accepts a `#tool{}` record and a handler fun:

```erlang
start_my_server() ->
    %% Ensure the application is started (starts registry + session manager)
    application:ensure_all_started(erl_mcp),

    %% Register tools
    Tool = my_echo_handler:tool_definition(),
    Handler = fun(Args, Context) ->
        my_echo_handler:handle_call(Tool#tool.name, Args, Context)
    end,
    ok = erl_mcp_server_tool_registry:register_tool(Tool, Handler),

    %% Start cowboy with the MCP HTTP handler
    Dispatch = cowboy_router:compile([
        {'_', [{"/mcp", erl_mcp_server_http_handler, #{
            handlers => erl_mcp_server_protocol:default_handlers(),
            server_info => #implementation{
                name = <<"my_server">>,
                version = <<"1.0.0">>
            }
        }}]}
    ]),
    {ok, _} = cowboy:start_clear(mcp_listener, [{port, 8080}], #{
        env => #{dispatch => Dispatch}
    }).
```

The handler fun registered with `erl_mcp_server_tool_registry` takes
`(Args, Context)` where Context is `#{session_id => BinaryId}`. It
returns `{ok, ContentList} | {error, Binary}`. You can wrap a behaviour
module as shown above, or use an anonymous fun directly.

To unregister a tool:

```erlang
ok = erl_mcp_server_tool_registry:unregister_tool(<<"echo">>).
```

## Session Lifecycle Hooks

Sessions support an `on_close` callback, invoked with the session ID
when the session terminates (disconnect, idle timeout, or explicit
delete). Pass it through the cowboy handler state:

```erlang
Dispatch = cowboy_router:compile([
    {'_', [{"/mcp", erl_mcp_server_http_handler, #{
        handlers => erl_mcp_server_protocol:default_handlers(),
        server_info => #implementation{
            name = <<"my_server">>,
            version = <<"1.0.0">>
        },
        on_close => fun(SessionId) ->
            logger:info("Session ~s closed", [SessionId]),
            my_session_registry:remove(SessionId)
        end
    }}]}
]),
```

The callback runs in the session process during `terminate/2`. Keep it
fast and side-effect-safe -- exceptions are caught and discarded.

### Session Context in Tool Handlers

Tool handlers receive a context map instead of raw session state. Use
the session ID for per-session routing, audit logging, or multi-tenant
isolation:

```erlang
Handler = fun(Args, #{session_id := SessionId}) ->
    Result = my_app:do_work(SessionId, Args),
    {ok, [erl_mcp_protocol_content:text(Result)]}
end,
```

### Idle Timeout

Sessions expire after 30 minutes of inactivity by default. The timer
resets on every inbound message, outbound request, or notification.
Configure via application env:

```erlang
application:set_env(erl_mcp, session_idle_timeout, 3600000). %% 1 hour
```

## Using the Client

`erl_mcp_client` is a gen_statem that connects to an external MCP server,
performs the initialize handshake, and provides tool discovery and calling.

```erlang
%% Start a client
{ok, Client} = erl_mcp_client:start_link(#{
    server_url => <<"https://example.com/mcp">>,
    auth => {bearer, <<"my-token">>},
    tool_prefix => <<"remote">>,
    client_info => #{name => <<"my_app">>, version => <<"1.0.0">>}
}),

%% Discover available tools
{ok, Tools} = erl_mcp_client:list_tools(Client),
%% Tools is a list of #mcp_client_tool{} records

%% Call a tool (tool names are prefixed: "remote__tool_name")
{ok, Result} = erl_mcp_client:call(Client, <<"remote__some_tool">>,
                                   #{<<"arg">> => <<"value">>}, 30000),

%% Check client status
Status = erl_mcp_client:status(Client),
%% #{state => ready, server_info => ..., tool_count => ...}

%% Refresh tool cache after server-side changes
{ok, NewTools} = erl_mcp_client:refresh_tools(Client),

%% Update authentication without reconnecting
ok = erl_mcp_client:update_auth(Client, {bearer, <<"new-token">>}),

%% Stop the client
ok = erl_mcp_client:stop(Client).
```

### Client Supervisor

For applications managing multiple MCP clients dynamically:

```erlang
%% Add to your supervision tree
{ok, Sup} = erl_mcp_client_sup:start_link({local, my_mcp_clients}),

%% Start clients dynamically
{ok, Pid} = erl_mcp_client_sup:start_client(my_mcp_clients, #{
    server_url => <<"https://server-a.example.com/mcp">>,
    auth => {bearer, Token}
}),

%% Stop a specific client
ok = erl_mcp_client_sup:stop_client(my_mcp_clients, Pid).
```

### Authentication Options

The `auth` config key supports several forms:

```erlang
%% Bearer token
#{auth => {bearer, <<"token">>}}

%% Custom header
#{auth => {header, <<"X-Api-Key">>, <<"key">>}}

%% Multiple custom headers
#{auth => {custom_headers, [{<<"X-Api-Key">>, <<"key">>},
                            {<<"X-Org-Id">>, <<"org">>}]}}

%% No auth
#{auth => none}  %% default
```

## Error Handling

### Server Side

Tool handlers return `{error, Binary}` for tool-level errors. These are
wrapped into a successful JSON-RPC response with `isError: true`:

```erlang
handle_call(<<"risky_tool">>, _Args, _State) ->
    case do_risky_thing() of
        {ok, Value} ->
            {ok, [erl_mcp_protocol_content:text(Value)]};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("Failed: ~p", [Reason]))}
    end.
```

Crashes in handler funs are caught by the session process. Specific error
patterns (badarg, badkey, badmap, badarith) produce structured error
responses rather than crashing the session.

### Client Side

Client calls return `{error, Reason}` tuples:

```erlang
case erl_mcp_client:call(Client, ToolName, Args, Timeout) of
    {ok, Result} ->
        handle_result(Result);
    {error, session_not_found} ->
        %% Server invalidated session; client will reconnect automatically
        retry_later;
    {error, {jsonrpc_error, Code, Msg}} ->
        %% JSON-RPC level error from server
        log_error(Code, Msg);
    {error, {tool_error, ResultMap}} ->
        %% Tool returned isError: true
        handle_tool_error(ResultMap);
    {error, not_ready} ->
        %% Client still connecting or reconnecting
        retry_later
end.
```

## Configuration Reference

Application environment keys (set via `sys.config` or
`application:set_env/3`):

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_request_body` | integer | `1048576` | Maximum POST body size in bytes for the HTTP handler |
| `session_idle_timeout` | integer | `1800000` | Session idle timeout in milliseconds (default 30 min) |

Client config map keys (passed to `erl_mcp_client:start_link/1`):

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server_url` | binary | required | URL of the MCP server |
| `auth` | term | `none` | Authentication config (see above) |
| `transport` | module | `erl_mcp_transport_http_streamable` | Transport module |
| `protocol_version` | binary | `<<"2025-06-18">>` | MCP protocol version to request |
| `tool_prefix` | binary | `<<>>` | Prefix for tool names (joined with `__`) |
| `capabilities` | map | `#{}` | Client capabilities to advertise |
| `client_info` | map | `#{name => <<"erl_mcp">>, version => <<"0.1.0">>}` | Client identity |
| `timeout` | integer | `30000` | Default HTTP request timeout (ms) |
| `telemetry` | fun/1 or {M,F} | `undefined` | Telemetry callback for client events |
| `name` | term | `undefined` | Registration name for the gen_statem |
| `id` | term | `erl_mcp_client` | Child spec ID |

Protocol handler options (passed to `erl_mcp_server_protocol:default_handlers/1`):

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `page_size` | integer | `50` | Number of tools per page in tools/list |
