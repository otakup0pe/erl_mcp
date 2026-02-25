-module(mcp_protocol).

%% Ready-made MCP method handlers.
%% Returns handler functions suitable for mcp_session's handlers map.

-include("mcp.hrl").

-export([default_handlers/0, default_handlers/1]).
-export([handle_tools_list/2, handle_tools_call/2]).

%%--------------------------------------------------------------------
%% Default handler sets
%%--------------------------------------------------------------------

-spec default_handlers() -> map().
default_handlers() ->
    default_handlers(#{}).

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

%%--------------------------------------------------------------------
%% tools/list
%%--------------------------------------------------------------------

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

%%--------------------------------------------------------------------
%% tools/call
%%--------------------------------------------------------------------

-spec handle_tools_call(map(), term()) ->
    {ok, map()} | {error, integer(), binary()}.
handle_tools_call(Params, _State) ->
    Name = maps:get(<<"name">>, Params, undefined),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    case Name of
        undefined ->
            {error, ?INVALID_PARAMS, <<"Missing tool name">>};
        _ ->
            dispatch_tool_call(Name, Arguments)
    end.

dispatch_tool_call(Name, Arguments) ->
    case mcp_tool_registry:lookup(Name) of
        {ok, _Tool, Handler} ->
            invoke_tool_handler(Handler, Arguments);
        {error, not_found} ->
            {error, ?METHOD_NOT_FOUND,
             <<"Tool not found: ", Name/binary>>}
    end.

invoke_tool_handler(Handler, Arguments) ->
    try Handler(Arguments, undefined) of
        {ok, ContentList} when is_list(ContentList) ->
            Maps = [mcp_content:to_map(C) || C <- ContentList],
            {ok, #{<<"content">> => Maps}};
        {ok, ResultMap} when is_map(ResultMap) ->
            {ok, ResultMap};
        {error, Msg} when is_binary(Msg) ->
            wrap_tool_error(Msg)
    catch
        _:Reason ->
            ErrMsg = iolist_to_binary(
                io_lib:format("~p", [Reason])),
            wrap_tool_error(ErrMsg)
    end.

wrap_tool_error(Msg) ->
    ErrorContent = mcp_content:to_map(mcp_content:text(Msg)),
    {ok, #{<<"content">> => [ErrorContent], <<"isError">> => true}}.
