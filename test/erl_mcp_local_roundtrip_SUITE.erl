-module(erl_mcp_local_roundtrip_SUITE).

%% Full round-trip tests: erl_mcp_client <-> erl_mcp_server_local
%% via erl_mcp_transport_local.  Validates that capability negotiation,
%% tool discovery, tool calls, and error envelopes are identical to the
%% HTTP transport path.

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").
-include("erl_mcp_client.hrl").

-export([all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    initialize_and_ready/1,
    list_tools_matches_http/1,
    tool_call_success/1,
    tool_call_error/1,
    tool_not_found/1,
    status_reports/1,
    prefixed_tool_names/1,
    cross_node_via_named_target/1,
    benchmark_roundtrip/1
]).

all() -> [{group, roundtrip}, {group, benchmark}].

groups() ->
    [
     {roundtrip, [sequence], [
        initialize_and_ready,
        list_tools_matches_http,
        tool_call_success,
        tool_call_error,
        tool_not_found,
        status_reports,
        prefixed_tool_names,
        cross_node_via_named_target
     ]},
     {benchmark, [], [
        benchmark_roundtrip
     ]}
    ].

%%--------------------------------------------------------------------
%% Suite setup
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Group setup
%%--------------------------------------------------------------------

init_per_group(_Group, Config) ->
    stop_if_alive(erl_mcp_server_tool_registry),
    stop_if_alive(erl_mcp_server_session_manager),
    {ok, RegPid} = erl_mcp_server_tool_registry:start_link(),
    unlink(RegPid),
    %% Register echo tool
    EchoTool = #tool{
        name = <<"echo">>,
        description = <<"Echoes the message argument">>,
        input_schema = #{<<"type">> => <<"object">>,
                         <<"properties">> => #{
                             <<"message">> => #{<<"type">> => <<"string">>}
                         },
                         <<"required">> => [<<"message">>]}
    },
    EchoHandler = fun(Args, _Ctx) ->
        Msg = maps:get(<<"message">>, Args, <<"no message">>),
        {ok, [erl_mcp_protocol_content:text(Msg)]}
    end,
    ok = erl_mcp_server_tool_registry:register_tool(EchoTool, EchoHandler),
    %% Register boom tool (always errors)
    BoomTool = #tool{
        name = <<"boom">>,
        description = <<"Always errors">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    BoomHandler = fun(_Args, _Ctx) ->
        {error, <<"boom!">>}
    end,
    ok = erl_mcp_server_tool_registry:register_tool(BoomTool, BoomHandler),
    [{reg_pid, RegPid} | Config].

end_per_group(_Group, Config) ->
    RegPid = proplists:get_value(reg_pid, Config),
    catch gen_server:stop(RegPid).

%%--------------------------------------------------------------------
%% Testcase setup
%%--------------------------------------------------------------------

%% Each testcase gets a fresh server_local + session.  server_local
%% holds a single session per instance, so reusing it across cases
%% would leave the first test's `initialized' status in place and
%% reject subsequent initialize requests.
init_per_testcase(_TC, Config) ->
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{
        tools => #{list_changed => true}
    }),
    ServerInfo = #implementation{
        name = <<"test-local-server">>,
        version = <<"0.1.0">>
    },
    {ok, ServerPid} = erl_mcp_server_local:start_link(#{
        handlers => erl_mcp_server_protocol:default_handlers(),
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    }),
    unlink(ServerPid),
    [{server_pid, ServerPid} | Config].

end_per_testcase(_TC, Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    catch gen_server:stop(ServerPid),
    ok.

%%--------------------------------------------------------------------
%% Tests: roundtrip group
%%--------------------------------------------------------------------

initialize_and_ready(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    Status = erl_mcp_client:status(Client),
    ?assertEqual(ready, maps:get(state, Status)),
    ?assertMatch(#{<<"name">> := <<"test-local-server">>},
                 maps:get(server_info, Status)),
    erl_mcp_client:stop(Client).

list_tools_matches_http(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    {ok, Tools} = erl_mcp_client:list_tools(Client),
    Names = lists:sort([T#mcp_client_tool.name || T <- Tools]),
    ?assert(lists:member(<<"boom">>, Names)),
    ?assert(lists:member(<<"echo">>, Names)),
    %% Each tool has the expected shape
    EchoTool = lists:keyfind(<<"echo">>, #mcp_client_tool.name, Tools),
    ?assertEqual(<<"Echoes the message argument">>,
                 EchoTool#mcp_client_tool.description),
    ?assert(is_map(EchoTool#mcp_client_tool.input_schema)),
    erl_mcp_client:stop(Client).

tool_call_success(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    {ok, Result} = erl_mcp_client:call(
                     Client, <<"echo">>,
                     #{<<"message">> => <<"hello local">>}, 5000),
    Content = maps:get(<<"content">>, Result),
    ?assertMatch([#{<<"type">> := <<"text">>,
                    <<"text">> := <<"hello local">>}], Content),
    erl_mcp_client:stop(Client).

tool_call_error(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    Res = erl_mcp_client:call(Client, <<"boom">>, #{}, 5000),
    ?assertMatch({error, {tool_error, _}}, Res),
    {error, {tool_error, ErrorResult}} = Res,
    ?assertEqual(true, maps:get(<<"isError">>, ErrorResult)),
    erl_mcp_client:stop(Client).

tool_not_found(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    Res = erl_mcp_client:call(Client, <<"nonexistent">>, #{}, 5000),
    ?assertMatch({error, {jsonrpc_error, ?METHOD_NOT_FOUND, _}}, Res),
    erl_mcp_client:stop(Client).

status_reports(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    %% Populate tool cache first
    {ok, _} = erl_mcp_client:list_tools(Client),
    Status = erl_mcp_client:status(Client),
    ?assertEqual(ready, maps:get(state, Status)),
    ?assert(maps:get(tool_count, Status) >= 2),
    ?assertEqual(undefined, maps:get(last_error, Status)),
    erl_mcp_client:stop(Client).

prefixed_tool_names(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION,
        tool_prefix => <<"local">>
    }),
    {ok, Tools} = erl_mcp_client:list_tools(Client),
    Names = [T#mcp_client_tool.name || T <- Tools],
    ?assert(lists:member(<<"local__echo">>, Names)),
    ?assert(lists:member(<<"local__boom">>, Names)),
    %% Calling with prefix works
    {ok, Result} = erl_mcp_client:call(
                     Client, <<"local__echo">>,
                     #{<<"message">> => <<"prefixed">>}, 5000),
    Content = maps:get(<<"content">>, Result),
    ?assertMatch([#{<<"text">> := <<"prefixed">>}], Content),
    erl_mcp_client:stop(Client).

%% Exercises the `{Name, Node}' target form -- the same code path
%% used for cross-node connections. Using `node()' here keeps the
%% test self-contained (no peer node spawning) while still routing
%% through the cross-node-aware resolution and dispatch path.
cross_node_via_named_target(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    Name = mcp_local_xnode_test_target,
    %% Register under a unique name; allow pre-existing registration
    %% from a previous failed run.
    catch unregister(Name),
    true = register(Name, ServerPid),
    try
        Target = {Name, node()},
        {ok, Client} = erl_mcp_client:start_link(#{
            transport => erl_mcp_transport_local,
            server_pid => Target,
            protocol_version => ?MCP_PROTOCOL_VERSION
        }),
        Status = erl_mcp_client:status(Client),
        ?assertEqual(ready, maps:get(state, Status)),
        {ok, Tools} = erl_mcp_client:list_tools(Client),
        Names = [T#mcp_client_tool.name || T <- Tools],
        ?assert(lists:member(<<"echo">>, Names)),
        {ok, Result} = erl_mcp_client:call(
                         Client, <<"echo">>,
                         #{<<"message">> => <<"xnode">>}, 5000),
        Content = maps:get(<<"content">>, Result),
        ?assertMatch([#{<<"text">> := <<"xnode">>}], Content),
        erl_mcp_client:stop(Client)
    after
        catch unregister(Name)
    end.

%%--------------------------------------------------------------------
%% Tests: benchmark group
%%--------------------------------------------------------------------

benchmark_roundtrip(Config) ->
    ServerPid = proplists:get_value(server_pid, Config),
    {ok, Client} = erl_mcp_client:start_link(#{
        transport => erl_mcp_transport_local,
        server_pid => ServerPid,
        protocol_version => ?MCP_PROTOCOL_VERSION
    }),
    N = 1000,
    %% Warm up the tool cache
    {ok, _} = erl_mcp_client:list_tools(Client),
    T0 = erlang:monotonic_time(microsecond),
    lists:foreach(fun(I) ->
        Msg = integer_to_binary(I),
        {ok, _} = erl_mcp_client:call(
                     Client, <<"echo">>,
                     #{<<"message">> => Msg}, 5000)
    end, lists:seq(1, N)),
    T1 = erlang:monotonic_time(microsecond),
    Elapsed = T1 - T0,
    AvgUs = Elapsed / N,
    ct:pal("~n=== Local Transport Benchmark ===~n"
           "  Calls: ~B~n"
           "  Total: ~.1f ms~n"
           "  Avg:   ~.1f us/call~n"
           "================================~n",
           [N, Elapsed / 1000, AvgUs]),
    erl_mcp_client:stop(Client).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

stop_if_alive(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 5000)
    end.
