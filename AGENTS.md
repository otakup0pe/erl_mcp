# AGENTS.md

## Project

erl_mcp is an Erlang/OTP implementation of the Model Context Protocol (MCP),
providing both a server framework and an embeddable client. It targets the
MCP 2025-03-26 protocol version and requires OTP 27+ (uses the built-in
`json` module). The only external dependency is cowboy 2.12 for HTTP.

## Build and Test

```
make compile       # rebar3 compile
make test          # Docker-based: builds image, runs eunit + ct
make local-test    # runs eunit + ct directly (needs OTP 27 + rebar3)
make local-eunit   # eunit only
make local-ct      # common_test only
make dialyzer      # dialyzer
```

rebar3 is not vendored; the Docker image builds it from source.

## Public API

These modules are the supported public interface:

| Module | Description |
|--------|-------------|
| `mcp_tool` | Tool definition builder and map serialization |
| `mcp_tool_handler` | Behaviour for tool implementations (`handle_call/3`, `tool_definition/0`) |
| `mcp_tool_registry` | ETS-backed gen_server registry with pagination and change notifications |
| `mcp_content` | Content type builders (text, image, audio, embedded_resource) |
| `mcp_capability` | Capability record builders, serialization, negotiation |
| `mcp_protocol` | Ready-made MCP method handlers (tools/list, tools/call) |
| `mcp_http_handler` | Cowboy handler for streamable HTTP (POST/GET/DELETE) |
| `mcp_session` | Per-connection gen_server session state machine |
| `mcp_transport` | Server-side transport behaviour (send/recv/close) |
| `erl_mcp_client` | gen_statem MCP client with reconnect, tool cache, prefixing |
| `erl_mcp_client_sup` | simple_one_for_one supervisor for dynamic client pools |
| `erl_mcp_transport` | Client transport behaviour (connect/request/notify/close) |

## Internal Modules

These are exported for inter-module use but not part of the public API.
All marked `@private` in edoc.

| Module | Description |
|--------|-------------|
| `mcp_jsonrpc` | JSON-RPC 2.0 encode/decode with batch support |
| `mcp_json` | Thin wrapper over OTP 27 `json` module |
| `mcp_sse` | SSE event encoding and decoding |
| `mcp_session_manager` | Creates, tracks, and removes sessions by ID |
| `erl_mcp_transport_http_streamable` | httpc-based streamable HTTP client transport |

## OTP Infrastructure

| Module | Description |
|--------|-------------|
| `mcp_app` | OTP application callback, starts `mcp_sup` |
| `mcp_sup` | Top-level supervisor: tool_registry + session_manager |

## Include Files

- `include/mcp.hrl` -- Protocol version, JSON-RPC error codes, all record definitions
- `include/mcp_client.hrl` -- Client-specific records (`mcp_client_tool`)

## Test Layout (test/)

EUnit modules (suffix `_tests`):
- `mcp_jsonrpc_tests`, `mcp_tool_tests`, `mcp_capability_tests`,
  `mcp_content_tests`, `mcp_sse_tests`, `erl_mcp_client_tests`

Common Test suites (suffix `_SUITE`):
- `initialize_SUITE`, `ping_SUITE`, `tool_SUITE`, `http_SUITE`,
  `client_roundtrip_SUITE`

Test helpers:
- `mock_transport` -- server-side transport mock
- `mock_client_transport` -- client-side transport mock

## Key Design Decisions

1. **Transport abstraction** -- Two separate behaviours: `mcp_transport`
   (server-side send/recv/close) and `erl_mcp_transport` (client-side
   connect/request/notify/close). Transports only move bytes; protocol
   logic lives in session and client processes.

2. **Behaviour pattern** -- `mcp_tool_handler` defines callbacks for tool
   implementations. Tool handlers are registered as funs in the registry
   rather than requiring a module per tool.

3. **Registry** -- `mcp_tool_registry` is an ETS-backed gen_server with
   cursor-based pagination. Tools are registered with a handler fun, not
   a module reference. Change listeners receive `{mcp_tools_changed}`.

4. **Session model** -- Each HTTP connection gets a `mcp_session` gen_server
   tracked by `mcp_session_manager`. Sessions handle the initialize
   handshake, dispatch requests to handler funs, and manage in-flight
   handler processes with monitors. Tool handlers receive a context map
   (`#{session_id => Id}`) instead of raw session state. Sessions support
   an `on_close` callback (fired with the session ID on terminate) and
   idle timeout (30 min default, configurable via `session_idle_timeout`).

5. **Client state machine** -- `erl_mcp_client` is a gen_statem with states:
   connecting -> initialising -> ready, with reconnecting and failed as
   recovery/terminal states. Exponential backoff on reconnect.

6. **No jsx** -- JSON handled by OTP 27 built-in `json` module via
   `mcp_json` wrapper. No fallback.

## Conventions

- `warnings_as_errors` is enabled in rebar.config
- No catch-all clauses that silently swallow errors
- Prefer returning `{error, Reason}` tuples over throwing
- Tests use meck for mocking where needed
- Binary strings for all protocol-level data (tool names, methods, etc.)
