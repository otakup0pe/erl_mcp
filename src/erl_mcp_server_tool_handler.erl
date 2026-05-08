-module(erl_mcp_server_tool_handler).

%% @doc false
%% Behaviour for MCP tool implementations.
%%
%% Modules that implement this behaviour must export two callbacks:
%%
%% <ul>
%%   <li>`tool_definition/0' -- return the `#tool{}' record that
%%       describes this tool (name, schema, annotations).</li>
%%   <li>`handle_call/3' -- execute the tool given its name, argument
%%       map, and opaque state. Return one of:
%%     <ul>
%%       <li>`{ok, [Content]}' -- list of content records
%%           (see {@link erl_mcp_protocol_content}); the dispatcher
%%           wraps these into the standard `#{<<"content">> => [...]}'
%%           envelope.</li>
%%       <li>`{ok, ResultMap}' -- pre-built MCP result envelope as a
%%           map. Use when the tool needs control over fields the
%%           content-list shortcut does not expose (`structuredContent',
%%           etc.).</li>
%%       <li>`{error, Binary}' -- tool-level error; rendered as an
%%           `isError: true' MCP response.</li>
%%     </ul>
%%   </li>
%% </ul>
%%
%% Any other return shape is rejected by the dispatcher with an
%% INTERNAL_ERROR JSON-RPC response describing the offending value.

-include("erl_mcp.hrl").

-type content_list() ::
    [#text_content{} | #image_content{}
   | #audio_content{} | #embedded_resource{}].

-callback handle_call(Name :: binary(), Args :: map(), State :: term()) ->
    {ok, content_list()}
  | {ok, ResultMap :: map()}
  | {error, Reason :: binary()}
  | term().

-callback tool_definition() -> #tool{}.
