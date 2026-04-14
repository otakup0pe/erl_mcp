-ifndef(MCP_CLIENT_HRL).
-define(MCP_CLIENT_HRL, true).

-define(MCP_CLIENT_DEFAULT_PROTOCOL_VERSION, <<"2025-06-18">>).

-record(mcp_client_tool, {
    name :: binary(),
    raw_name :: binary(),
    description :: undefined | binary(),
    input_schema :: map(),
    annotations = #{} :: map()
}).

-endif.
