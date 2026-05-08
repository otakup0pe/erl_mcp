# erl_mcp

[![CI](https://github.com/otakup0pe/erl_mcp/actions/workflows/test.yml/badge.svg)](https://github.com/otakup0pe/erl_mcp/actions/workflows/test.yml)
[![Maintenance](https://img.shields.io/maintenance/yes/2026.svg)](https://github.com/otakup0pe/erl_mcp)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Erlang/OTP implementation of the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP).

**Protocol version**: `2025-06-18`

## Requirements

- OTP 27+
- rebar3

## Quick Start

Add the dependency to `rebar.config`:

```erlang
{deps, [{erl_mcp, "0.1.0"}]}.
```

### Server: register a tool and start the HTTP handler

```erlang
Tool = erl_mcp_server_tool:new(<<"echo">>, <<"Echoes input">>,
    #{<<"type">> => <<"object">>}),
Handler = fun(Args, _Ctx) ->
    {ok, [erl_mcp_protocol_content:text(maps:get(<<"input">>, Args))]}
end,
erl_mcp_server_tool_registry:register_tool(Tool, Handler),

Dispatch = cowboy_router:compile([
    {'_', [{"/mcp", erl_mcp_server_http_handler, #{
        handlers => erl_mcp_server_protocol:default_handlers()
    }}]}
]),
cowboy:start_clear(my_mcp, [{port, 8080}],
    #{env => #{dispatch => Dispatch}}).
```

### Client: connect to an external MCP server

```erlang
{ok, Pid} = erl_mcp_client:start_link(#{
    server_url => <<"https://example.com/mcp">>,
    auth => {bearer, <<"token">>}
}),
{ok, Tools} = erl_mcp_client:list_tools(Pid),
{ok, Result} = erl_mcp_client:call(Pid, <<"tool_name">>, #{}, 30000).
```

## Transports

| Transport | Side | Module | Status |
|-----------|------|--------|--------|
| HTTP streamable | Server | `erl_mcp_server_http_handler` | Shipped |
| HTTP streamable | Client | `erl_mcp_transport_http_streamable` | Shipped |
| SSE | -- | `erl_mcp_protocol_sse` | Encode/decode only |
| stdio | -- | -- | Deferred |

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `max_request_body` | `1048576` | Max POST body size in bytes |
| `session_idle_timeout` | `1800000` | Session idle timeout in ms (30 min) |
| `page_size` | `50` | Default tool list page size |

See `src/erl_mcp.app.src` for the full set.

## Features

- **Server framework** -- behaviour-based tool handlers with registry
- **Client** -- gen_statem client with reconnect, tool caching, prefixing
- **Tool registry** -- ETS-backed, paginated, change notifications
- **HTTP transport** -- Cowboy-based streamable HTTP (MCP 2025-06-18)
- **SSE** -- Server-Sent Events encoding and decoding
- **JSON-RPC 2.0** -- full encode/decode with batch support
- **Session management** -- per-connection state, capability negotiation, idle timeout
- **Session context** -- tool handlers receive `#{session_id => Id}` for multi-tenant routing
- **Lifecycle hooks** -- `on_close` callback for session teardown notifications

## Testing

```
make test          # Docker-based (recommended)
make local-test    # eunit + common_test directly
```

## Note on AI Usage

This project has been developed with AI assistance. Contributions making use of AI generated content are welcome, however they _must_ be human reviewed prior to submission as pull requests, or issues. All contributors must be able to fully explain and defend any AI generated code, documentation, issues, or tests they submit. Contributions making use of AI must have this explicitly declared in the pull request or issue. This also applies to utilization of AI for reviewing of pull requests.

## Feedback

Open an issue at https://github.com/otakup0pe/erl_mcp/issues

## License

Apache-2.0. See [LICENSE](LICENSE).
