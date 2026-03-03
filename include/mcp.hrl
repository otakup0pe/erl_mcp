-ifndef(MCP_HRL).
-define(MCP_HRL, true).

-define(MCP_PROTOCOL_VERSION, <<"2025-03-26">>).
-define(JSONRPC_VERSION, <<"2.0">>).

%% JSON-RPC 2.0 error codes
-define(PARSE_ERROR, -32700).
-define(INVALID_REQUEST, -32600).
-define(METHOD_NOT_FOUND, -32601).
-define(INVALID_PARAMS, -32602).
-define(INTERNAL_ERROR, -32603).
-define(RESOURCE_NOT_FOUND, -32002).
-define(REQUEST_CANCELLED, -32800).

%% JSON-RPC message types
-record(jsonrpc_request, {
    id :: binary() | integer(),
    method :: binary(),
    params = #{} :: map()
}).

-record(jsonrpc_response, {
    id :: binary() | integer(),
    result :: map()
}).

-record(jsonrpc_error, {
    id :: binary() | integer() | null,
    code :: integer(),
    message :: binary(),
    data :: term()
}).

-record(jsonrpc_notification, {
    method :: binary(),
    params = #{} :: map()
}).

%% MCP capability records
-record(client_capabilities, {
    experimental = #{} :: map(),
    roots :: undefined | #{list_changed => boolean()},
    sampling :: undefined | #{}
}).

-record(server_capabilities, {
    experimental = #{} :: map(),
    logging :: undefined | #{},
    completions :: undefined | #{},
    prompts :: undefined | #{list_changed => boolean()},
    resources :: undefined | #{subscribe => boolean(), list_changed => boolean()},
    tools :: undefined | #{list_changed => boolean()}
}).

%% MCP implementation info
-record(implementation, {
    name :: binary(),
    version :: binary()
}).

%% Content types
-record(text_content, {
    text :: binary(),
    annotations :: undefined | map()
}).

-record(image_content, {
    data :: binary(),       %% base64 encoded
    mime_type :: binary(),
    annotations :: undefined | map()
}).

-record(audio_content, {
    data :: binary(),       %% base64 encoded
    mime_type :: binary(),
    annotations :: undefined | map()
}).

-record(embedded_resource, {
    resource :: map(),      %% TextResourceContents | BlobResourceContents
    annotations :: undefined | map()
}).

%% Tool definition
-record(tool, {
    name :: binary(),
    description :: undefined | binary(),
    input_schema :: map(),
    annotations = #{} :: map()
}).

-endif.
