-module(mcp_capability_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

%%--------------------------------------------------------------------
%% Client capability tests
%%--------------------------------------------------------------------

client_defaults_test() ->
    C = erl_mcp_protocol_capability:client_capabilities(#{}),
    ?assertEqual(#{}, C#client_capabilities.experimental),
    ?assertEqual(undefined, C#client_capabilities.roots),
    ?assertEqual(undefined, C#client_capabilities.sampling).

client_with_roots_test() ->
    C = erl_mcp_protocol_capability:client_capabilities(#{roots => #{list_changed => true}}),
    ?assertEqual(#{list_changed => true}, C#client_capabilities.roots).

client_with_sampling_test() ->
    C = erl_mcp_protocol_capability:client_capabilities(#{sampling => #{}}),
    ?assertEqual(#{}, C#client_capabilities.sampling).

client_to_map_empty_test() ->
    C = erl_mcp_protocol_capability:client_capabilities(#{}),
    Map = erl_mcp_protocol_capability:client_to_map(C),
    ?assertEqual(#{}, Map).

client_to_map_with_roots_test() ->
    C = erl_mcp_protocol_capability:client_capabilities(#{roots => #{list_changed => true}}),
    Map = erl_mcp_protocol_capability:client_to_map(C),
    ?assert(maps:is_key(<<"roots">>, Map)).

client_roundtrip_test() ->
    Orig = erl_mcp_protocol_capability:client_capabilities(#{
        roots => #{list_changed => true},
        sampling => #{}
    }),
    Map = erl_mcp_protocol_capability:client_to_map(Orig),
    Parsed = erl_mcp_protocol_capability:parse_client(Map),
    ?assertEqual(Orig#client_capabilities.roots,
                 Parsed#client_capabilities.roots).

%%--------------------------------------------------------------------
%% Server capability tests
%%--------------------------------------------------------------------

server_defaults_test() ->
    S = erl_mcp_protocol_capability:server_capabilities(#{}),
    ?assertEqual(#{}, S#server_capabilities.experimental),
    ?assertEqual(undefined, S#server_capabilities.tools),
    ?assertEqual(undefined, S#server_capabilities.resources).

server_with_tools_test() ->
    S = erl_mcp_protocol_capability:server_capabilities(#{tools => #{list_changed => true}}),
    ?assertEqual(#{list_changed => true}, S#server_capabilities.tools).

server_to_map_empty_test() ->
    S = erl_mcp_protocol_capability:server_capabilities(#{}),
    Map = erl_mcp_protocol_capability:server_to_map(S),
    ?assertEqual(#{}, Map).

server_to_map_with_tools_test() ->
    S = erl_mcp_protocol_capability:server_capabilities(#{
        tools => #{list_changed => true},
        logging => #{}
    }),
    Map = erl_mcp_protocol_capability:server_to_map(S),
    ?assert(maps:is_key(<<"tools">>, Map)),
    ?assertNot(maps:is_key(<<"logging">>, Map)).

server_roundtrip_test() ->
    Orig = erl_mcp_protocol_capability:server_capabilities(#{
        tools => #{list_changed => true},
        resources => #{subscribe => true, list_changed => false}
    }),
    Map = erl_mcp_protocol_capability:server_to_map(Orig),
    Parsed = erl_mcp_protocol_capability:parse_server(Map),
    ?assertEqual(Orig#server_capabilities.tools,
                 Parsed#server_capabilities.tools).

%%--------------------------------------------------------------------
%% Negotiation tests
%%--------------------------------------------------------------------

negotiate_passthrough_test() ->
    Client = erl_mcp_protocol_capability:client_capabilities(#{roots => #{}}),
    Server = erl_mcp_protocol_capability:server_capabilities(#{tools => #{list_changed => true}}),
    Result = erl_mcp_protocol_capability:negotiate(Client, Server),
    ?assertEqual(Server, Result).
