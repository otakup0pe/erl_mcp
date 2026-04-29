-module(mcp_protocol).

%% @doc Ready-made MCP method handlers.
%%
%% `default_handlers/0,1' returns a map of `Method => fun/2' entries
%% suitable for the `handlers' option of {@link mcp_session:start_link/1}.
%% Covers `tools/list' and `tools/call'; extend with your own entries
%% for prompts, resources, or custom methods.

-include("mcp.hrl").

-export([default_handlers/0, default_handlers/1]).
-export([handle_tools_list/2, handle_tools_call/2]).

%% @doc Return the default handler map with standard page size (50).
-spec default_handlers() -> map().
default_handlers() ->
    default_handlers(#{}).

%% @doc Return the default handler map with configurable `page_size'.
-spec default_handlers(map()) -> map().
default_handlers(Opts) ->
    PageSize = maps:get(page_size, Opts, 50),
    #{
        <<"tools/list">> => fun(Params, State) ->
            handle_tools_list(Params#{page_size => PageSize}, State)
        end,
        <<"tools/call">> => fun(Params, State) ->
            handle_tools_call(Params, State)
        end
    }.

%% @doc Handle a `tools/list' request.
%%
%% Reads tools from {@link mcp_tool_registry} with cursor-based pagination.
-spec handle_tools_list(map(), term()) ->
    {ok, map()} | {error, integer(), binary()}.
handle_tools_list(Params, _State) ->
    Cursor = maps:get(<<"cursor">>, Params, undefined),
    PageSize = maps:get(page_size, Params, 50),
    {Tools, NextCursor} = mcp_tool_registry:list_tools(#{
        cursor => Cursor,
        page_size => PageSize
    }),
    ToolMaps = [mcp_tool:to_map(T) || T <- Tools],
    Result = #{<<"tools">> => ToolMaps},
    case NextCursor of
        undefined -> {ok, Result};
        _ -> {ok, Result#{<<"nextCursor">> => NextCursor}}
    end.

%% @doc Handle a `tools/call' request.
%%
%% Looks up the tool in {@link mcp_tool_registry}, invokes its handler,
%% and wraps the result (or any caught error) into the MCP response format.
-spec handle_tools_call(map(), term()) ->
    {ok, map()} | {error, integer(), binary()}.
handle_tools_call(Params, Context) ->
    Name = maps:get(<<"name">>, Params, undefined),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    case Name of
        undefined ->
            {error, ?INVALID_PARAMS, <<"Missing tool name">>};
        _ ->
            dispatch_tool_call(Name, Arguments, Context)
    end.

dispatch_tool_call(Name, Arguments, Context) ->
    case mcp_tool_registry:lookup(Name) of
        {ok, _Tool, Handler} ->
            invoke_tool_handler(Handler, Arguments, Context);
        {error, not_found} ->
            {error, ?METHOD_NOT_FOUND,
             <<"Tool not found: ", Name/binary>>}
    end.

invoke_tool_handler(Handler, Arguments, Context) ->
    try Handler(Arguments, Context) of
        {ok, ContentList} when is_list(ContentList) ->
            Maps = [mcp_content:to_map(C) || C <- ContentList],
            {ok, #{<<"content">> => Maps}};
        {ok, ResultMap} when is_map(ResultMap) ->
            {ok, ResultMap};
        {error, Msg} when is_binary(Msg) ->
            wrap_tool_error(Msg);
        Other ->
            ErrMsg = iolist_to_binary(
                io_lib:format("Handler returned invalid shape: ~p", [Other])),
            {error, ?INTERNAL_ERROR, ErrMsg}
    catch
        error:badarg ->
            wrap_tool_error(<<"error:badarg">>);
        error:{badkey, Key} ->
            ErrMsg = iolist_to_binary(
                io_lib:format("error:{badkey,~p}", [Key])),
            wrap_tool_error(ErrMsg);
        error:{badmap, Val} ->
            ErrMsg = iolist_to_binary(
                io_lib:format("error:{badmap,~p}", [Val])),
            wrap_tool_error(ErrMsg);
        error:badarith ->
            wrap_tool_error(<<"error:badarith">>)
    end.

wrap_tool_error(Msg) ->
    ErrorContent = mcp_content:to_map(mcp_content:text(Msg)),
    {ok, #{<<"content">> => [ErrorContent], <<"isError">> => true}}.
