-module(initialize_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    server_initialize_handshake/1,
    server_returns_capabilities/1,
    server_returns_protocol_version/1,
    server_returns_server_info/1,
    server_rejects_double_initialize/1,
    client_version_negotiation_known/1,
    client_version_negotiation_unknown/1
]).

all() -> [
    server_initialize_handshake,
    server_returns_capabilities,
    server_returns_protocol_version,
    server_returns_server_info,
    server_rejects_double_initialize,
    client_version_negotiation_known,
    client_version_negotiation_unknown
].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    {ok, Transport} = mock_transport:start_link(),
    ServerCaps = erl_mcp_protocol_capability:server_capabilities(#{
        tools => #{list_changed => true}
    }),
    ServerInfo = #implementation{
        name = <<"test-server">>,
        version = <<"1.0.0">>
    },
    {ok, Session} = erl_mcp_server_session:start_link(#{
        role => server,
        transport_pid => Transport,
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    }),
    [{session, Session}, {transport, Transport} | Config].

end_per_testcase(_TC, Config) ->
    Session = proplists:get_value(session, Config),
    Transport = proplists:get_value(transport, Config),
    gen_server:stop(Session),
    mock_transport:stop(Transport).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

server_initialize_handshake(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{
            <<"name">> => <<"test-client">>,
            <<"version">> => <<"0.1.0">>
        }
    }),
    {reply, Reply} = erl_mcp_server_session:handle_message(Session, InitReq),
    ?assertMatch(#jsonrpc_response{id = 1}, Reply),
    InitNotif = erl_mcp_protocol_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    ok = erl_mcp_server_session:handle_message(Session, InitNotif),
    Info = erl_mcp_server_session:get_state(Session),
    ?assertEqual(initialized, maps:get(status, Info)),
    ok.

server_returns_capabilities(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        erl_mcp_server_session:handle_message(Session, InitReq),
    Caps = maps:get(<<"capabilities">>, Result),
    ?assert(maps:is_key(<<"tools">>, Caps)).

server_returns_protocol_version(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        erl_mcp_server_session:handle_message(Session, InitReq),
    ?assertEqual(?MCP_PROTOCOL_VERSION,
                 maps:get(<<"protocolVersion">>, Result)).

server_returns_server_info(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        erl_mcp_server_session:handle_message(Session, InitReq),
    ServerInfo = maps:get(<<"serverInfo">>, Result),
    ?assertEqual(<<"test-server">>, maps:get(<<"name">>, ServerInfo)),
    ?assertEqual(<<"1.0.0">>, maps:get(<<"version">>, ServerInfo)).

server_rejects_double_initialize(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{}} =
        erl_mcp_server_session:handle_message(Session, InitReq),
    InitNotif = erl_mcp_protocol_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    ok = erl_mcp_server_session:handle_message(Session, InitNotif),
    SecondReq = erl_mcp_protocol_jsonrpc:request(2, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, Reply} = erl_mcp_server_session:handle_message(Session, SecondReq),
    ?assertMatch(#jsonrpc_error{code = ?METHOD_NOT_FOUND}, Reply).

client_version_negotiation_known(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => <<"2024-11-05">>,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"old-client">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        erl_mcp_server_session:handle_message(Session, InitReq),
    ?assertEqual(<<"2024-11-05">>,
                 maps:get(<<"protocolVersion">>, Result)).

client_version_negotiation_unknown(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => <<"2099-01-01">>,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"future-client">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        erl_mcp_server_session:handle_message(Session, InitReq),
    ?assertEqual(?MCP_PROTOCOL_VERSION,
                 maps:get(<<"protocolVersion">>, Result)).
