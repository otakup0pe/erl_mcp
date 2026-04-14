-module(client_roundtrip_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").
-include("mcp_client.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    initialize_and_list_tools/1,
    tools_call_round_trip/1,
    tools_call_tool_error/1
]).

all() -> [
    initialize_and_list_tools,
    tools_call_round_trip,
    tools_call_tool_error
].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    catch cowboy:stop_listener(client_roundtrip_listener),
    stop_if_alive(mcp_session_manager),
    stop_if_alive(mcp_tool_registry),
    {ok, MgrPid} = mcp_session_manager:start_link(),
    unlink(MgrPid),
    {ok, RegPid} = mcp_tool_registry:start_link(),
    unlink(RegPid),
    %% Register tools: echo (normal) and boom (always errors)
    EchoTool = #tool{
        name = <<"echo">>,
        description = <<"Echoes input">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    EchoHandler = fun(Args, _St) ->
        Msg = maps:get(<<"message">>, Args, <<"no message">>),
        {ok, #{<<"content">> =>
                   [mcp_content:to_map(mcp_content:text(Msg))]}}
    end,
    ok = mcp_tool_registry:register_tool(EchoTool, EchoHandler),
    BoomTool = #tool{
        name = <<"boom">>,
        description = <<"Always errors">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    BoomHandler = fun(_Args, _St) -> {error, <<"boom!">>} end,
    ok = mcp_tool_registry:register_tool(BoomTool, BoomHandler),
    ServerCaps = mcp_capability:server_capabilities(#{
        tools => #{list_changed => true}
    }),
    ServerInfo = #implementation{
        name = <<"test-mcp-server">>,
        version = <<"0.1.0">>
    },
    HandlerState = #{
        handlers => mcp_protocol:default_handlers(),
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    },
    Dispatch = cowboy_router:compile([
        {'_', [{"/mcp", mcp_http_handler, HandlerState}]}
    ]),
    {ok, _} = cowboy:start_clear(client_roundtrip_listener,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(client_roundtrip_listener),
    Url = iolist_to_binary(["http://localhost:", integer_to_list(Port), "/mcp"]),
    [{server_url, Url}, {mgr_pid, MgrPid}, {reg_pid, RegPid} | Config].

end_per_testcase(_TC, Config) ->
    cowboy:stop_listener(client_roundtrip_listener),
    MgrPid = proplists:get_value(mgr_pid, Config),
    RegPid = proplists:get_value(reg_pid, Config),
    gen_server:stop(MgrPid),
    gen_server:stop(RegPid).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

initialize_and_list_tools(Config) ->
    Url = proplists:get_value(server_url, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        server_url => Url,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    Status = erl_mcp_client:status(Client),
    ?assertEqual(ready, maps:get(state, Status)),
    {ok, Tools} = erl_mcp_client:list_tools(Client),
    Names = [T#mcp_client_tool.name || T <- Tools],
    ?assert(lists:member(<<"echo">>, Names)),
    ?assert(lists:member(<<"boom">>, Names)),
    erl_mcp_client:stop(Client).

tools_call_round_trip(Config) ->
    Url = proplists:get_value(server_url, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        server_url => Url,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    {ok, Result} = erl_mcp_client:call(
                     Client, <<"echo">>,
                     #{<<"message">> => <<"hello">>}, 5000),
    Content = maps:get(<<"content">>, Result),
    ?assertMatch([#{<<"text">> := <<"hello">>}], Content),
    erl_mcp_client:stop(Client).

tools_call_tool_error(Config) ->
    Url = proplists:get_value(server_url, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        server_url => Url,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    Res = erl_mcp_client:call(Client, <<"boom">>, #{}, 5000),
    ?assertMatch({error, {tool_error, _}}, Res),
    erl_mcp_client:stop(Client).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

stop_if_alive(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 5000)
    end.
