-module(mcp_tool_handler).

%% @doc Behaviour for MCP tool implementations.
%%
%% Modules that implement this behaviour must export two callbacks:
%%
%% <ul>
%%   <li>`tool_definition/0' -- return the `#tool{}' record that
%%       describes this tool (name, schema, annotations).</li>
%%   <li>`handle_call/3' -- execute the tool given its name, argument
%%       map, and opaque state. Return a list of content records
%%       (see {@link mcp_content}) on success, or `{error, Msg}'.</li>
%% </ul>

-include("mcp.hrl").

-callback handle_call(Name :: binary(), Args :: map(), State :: term()) ->
    {ok, [#text_content{} | #image_content{} | #audio_content{} | #embedded_resource{}]} |
    {error, binary()}.

-callback tool_definition() -> #tool{}.
