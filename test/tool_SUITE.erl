-module(tool_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    register_and_list_tools/1,
    register_duplicate_fails/1,
    unregister_tool/1,
    unregister_nonexistent_fails/1,
    lookup_tool/1,
    lookup_nonexistent_fails/1,
    list_tools_pagination/1,
    call_tool_via_session/1,
    call_nonexistent_tool/1
]).

all() -> [{group, registry}, {group, session_dispatch}].

groups() ->
    [
     {registry, [sequence], [
        register_and_list_tools,
        register_duplicate_fails,
        unregister_tool,
        unregister_nonexistent_fails,
        lookup_tool,
        lookup_nonexistent_fails,
        list_tools_pagination
     ]},
     {session_dispatch, [sequence], [
        call_tool_via_session,
        call_nonexistent_tool
     ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(registry, Config) ->
    stop_if_alive(mcp_tool_registry),
    {ok, Pid} = mcp_tool_registry:start_link(),
    unlink(Pid),
    [{registry_pid, Pid} | Config];
init_per_group(session_dispatch, Config) ->
    stop_if_alive(mcp_tool_registry),
    {ok, RegPid} = mcp_tool_registry:start_link(),
    unlink(RegPid),
    {ok, Transport} = mock_transport:start_link(),
    %% Register a test tool
    EchoTool = #tool{
        name = <<"echo">>,
        description = <<"Echoes input back">>,
        input_schema = #{<<"type">> => <<"object">>,
                         <<"properties">> => #{
                             <<"message">> => #{<<"type">> => <<"string">>}
                         }}
    },
    EchoHandler = fun(Params, _State) ->
        Msg = maps:get(<<"message">>, maps:get(<<"arguments">>, Params, #{}), <<"no message">>),
        Content = mcp_content:text(Msg),
        {ok, #{<<"content">> => [mcp_content:to_map(Content)]}}
    end,
    ok = mcp_tool_registry:register_tool(EchoTool, EchoHandler),
    %% Create session with tools/call handler
    ToolsCallHandler = fun(Params, _SessionState) ->
        Name = maps:get(<<"name">>, Params),
        case mcp_tool_registry:lookup(Name) of
            {ok, _Tool, Handler} ->
                Handler(Params, undefined);
            {error, not_found} ->
                {error, ?METHOD_NOT_FOUND, <<"Tool not found">>}
        end
    end,
    ToolsListHandler = fun(_Params, _SessionState) ->
        Tools = mcp_tool_registry:list_tools(),
        ToolMaps = [tool_to_map(T) || T <- Tools],
        {ok, #{<<"tools">> => ToolMaps}}
    end,
    {ok, Session} = mcp_session:start_link(#{
        role => server,
        transport_pid => Transport,
        handlers => #{
            <<"tools/call">> => ToolsCallHandler,
            <<"tools/list">> => ToolsListHandler
        }
    }),
    unlink(Session),
    unlink(Transport),
    %% Initialize the session
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, _} = mcp_session:handle_message(Session, InitReq),
    InitNotif = mcp_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    ok = mcp_session:handle_message(Session, InitNotif),
    [{registry_pid, RegPid}, {session, Session}, {transport, Transport} | Config].

end_per_group(registry, Config) ->
    Pid = proplists:get_value(registry_pid, Config),
    gen_server:stop(Pid);
end_per_group(session_dispatch, Config) ->
    RegPid = proplists:get_value(registry_pid, Config),
    Session = proplists:get_value(session, Config),
    Transport = proplists:get_value(transport, Config),
    gen_server:stop(Session),
    gen_server:stop(RegPid),
    mock_transport:stop(Transport).

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Registry Tests
%%--------------------------------------------------------------------

register_and_list_tools(Config) ->
    _ = proplists:get_value(registry_pid, Config),
    Tool1 = #tool{name = <<"tool-a">>, input_schema = #{<<"type">> => <<"object">>}},
    Tool2 = #tool{name = <<"tool-b">>, input_schema = #{<<"type">> => <<"object">>}},
    Handler = fun(_Params, _State) -> {ok, []} end,
    ok = mcp_tool_registry:register_tool(Tool1, Handler),
    ok = mcp_tool_registry:register_tool(Tool2, Handler),
    Tools = mcp_tool_registry:list_tools(),
    Names = [T#tool.name || T <- Tools],
    ?assert(lists:member(<<"tool-a">>, Names)),
    ?assert(lists:member(<<"tool-b">>, Names)).

register_duplicate_fails(_Config) ->
    Tool = #tool{name = <<"tool-a">>, input_schema = #{<<"type">> => <<"object">>}},
    Handler = fun(_P, _S) -> {ok, []} end,
    ?assertEqual({error, already_registered},
                 mcp_tool_registry:register_tool(Tool, Handler)).

unregister_tool(_Config) ->
    ok = mcp_tool_registry:unregister_tool(<<"tool-b">>),
    Tools = mcp_tool_registry:list_tools(),
    Names = [T#tool.name || T <- Tools],
    ?assertNot(lists:member(<<"tool-b">>, Names)).

unregister_nonexistent_fails(_Config) ->
    ?assertEqual({error, not_found},
                 mcp_tool_registry:unregister_tool(<<"nope">>)).

lookup_tool(_Config) ->
    {ok, Tool, _Handler} = mcp_tool_registry:lookup(<<"tool-a">>),
    ?assertEqual(<<"tool-a">>, Tool#tool.name).

lookup_nonexistent_fails(_Config) ->
    ?assertEqual({error, not_found}, mcp_tool_registry:lookup(<<"nope">>)).

list_tools_pagination(_Config) ->
    %% Register more tools for pagination test
    Handler = fun(_P, _S) -> {ok, []} end,
    lists:foreach(fun(N) ->
        Name = iolist_to_binary([<<"page-tool-">>, integer_to_binary(N)]),
        Tool = #tool{name = Name, input_schema = #{<<"type">> => <<"object">>}},
        mcp_tool_registry:register_tool(Tool, Handler)
    end, lists:seq(1, 5)),
    %% Get first page
    {Page1, Cursor1} = mcp_tool_registry:list_tools(#{cursor => undefined,
                                                       page_size => 3}),
    ?assertEqual(3, length(Page1)),
    ?assertNotEqual(undefined, Cursor1),
    %% Get second page
    {Page2, _Cursor2} = mcp_tool_registry:list_tools(#{cursor => Cursor1,
                                                        page_size => 3}),
    ?assert(length(Page2) >= 1),
    %% No overlap
    Names1 = [T#tool.name || T <- Page1],
    Names2 = [T#tool.name || T <- Page2],
    Overlap = [N || N <- Names1, lists:member(N, Names2)],
    ?assertEqual([], Overlap).

%%--------------------------------------------------------------------
%% Session Dispatch Tests
%%--------------------------------------------------------------------

call_tool_via_session(Config) ->
    Session = proplists:get_value(session, Config),
    CallReq = mcp_jsonrpc:request(10, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"message">> => <<"hello world">>}
    }),
    {reply, Reply} = mcp_session:handle_message(Session, CallReq),
    ?assertMatch(#jsonrpc_response{id = 10}, Reply),
    Result = Reply#jsonrpc_response.result,
    Content = maps:get(<<"content">>, Result),
    ?assertEqual(1, length(Content)),
    [First] = Content,
    ?assertEqual(<<"text">>, maps:get(<<"type">>, First)),
    ?assertEqual(<<"hello world">>, maps:get(<<"text">>, First)).

call_nonexistent_tool(Config) ->
    Session = proplists:get_value(session, Config),
    CallReq = mcp_jsonrpc:request(11, <<"tools/call">>, #{
        <<"name">> => <<"nonexistent">>,
        <<"arguments">> => #{}
    }),
    {reply, Reply} = mcp_session:handle_message(Session, CallReq),
    ?assertMatch(#jsonrpc_error{id = 11, code = ?METHOD_NOT_FOUND}, Reply).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

stop_if_alive(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 5000)
    end.

tool_to_map(#tool{name = Name, description = Desc, input_schema = Schema,
                   annotations = Ann}) ->
    Base = #{<<"name">> => Name, <<"inputSchema">> => Schema},
    M1 = case Desc of
        undefined -> Base;
        _ -> Base#{<<"description">> => Desc}
    end,
    case map_size(Ann) of
        0 -> M1;
        _ -> M1#{<<"annotations">> => Ann}
    end.
