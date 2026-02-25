-module(mcp_tool_handler).

%% Behaviour for MCP tool implementations.
%% Server applications implement these callbacks.

-include("mcp.hrl").

-callback handle_call(Name :: binary(), Args :: map(), State :: term()) ->
    {ok, [#text_content{} | #image_content{} | #audio_content{} | #embedded_resource{}]} |
    {error, binary()}.

-callback tool_definition() -> #tool{}.
