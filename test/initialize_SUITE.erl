-module(initialize_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").

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
    ServerCaps = mcp_capability:server_capabilities(#{
        tools => #{list_changed => true}
    }),
    ServerInfo = #implementation{
        name = <<"test-server">>,
        version = <<"1.0.0">>
    },
    {ok, Session} = mcp_session:start_link(#{
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
    %% Send initialize request
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{
            <<"name">> => <<"test-client">>,
            <<"version">> => <<"0.1.0">>
        }
    }),
    {reply, Reply} = mcp_session:handle_message(Session, InitReq),
    %% Verify response is a jsonrpc_response
    ?assertMatch(#jsonrpc_response{id = 1}, Reply),
    %% Send initialized notification
    InitNotif = mcp_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    ok = mcp_session:handle_message(Session, InitNotif),
    %% Verify session is now initialized
    Info = mcp_session:get_state(Session),
    ?assertEqual(initialized, maps:get(status, Info)),
    %% Reply is returned directly to caller, not sent via transport
    %% (transport is for outbound requests/notifications from session)
    ok.

server_returns_capabilities(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        mcp_session:handle_message(Session, InitReq),
    Caps = maps:get(<<"capabilities">>, Result),
    ?assert(maps:is_key(<<"tools">>, Caps)).

server_returns_protocol_version(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        mcp_session:handle_message(Session, InitReq),
    ?assertEqual(?MCP_PROTOCOL_VERSION,
                 maps:get(<<"protocolVersion">>, Result)).

server_returns_server_info(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        mcp_session:handle_message(Session, InitReq),
    ServerInfo = maps:get(<<"serverInfo">>, Result),
    ?assertEqual(<<"test-server">>, maps:get(<<"name">>, ServerInfo)),
    ?assertEqual(<<"1.0.0">>, maps:get(<<"version">>, ServerInfo)).

server_rejects_double_initialize(Config) ->
    Session = proplists:get_value(session, Config),
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    %% First initialize succeeds
    {reply, #jsonrpc_response{}} =
        mcp_session:handle_message(Session, InitReq),
    %% Confirm initialized
    InitNotif = mcp_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    ok = mcp_session:handle_message(Session, InitNotif),
    %% Second initialize should be rejected (method not found -- not in uninitialized state)
    SecondReq = mcp_jsonrpc:request(2, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"test">>, <<"version">> => <<"0">>}
    }),
    {reply, Reply} = mcp_session:handle_message(Session, SecondReq),
    ?assertMatch(#jsonrpc_error{code = ?METHOD_NOT_FOUND}, Reply).

client_version_negotiation_known(Config) ->
    Session = proplists:get_value(session, Config),
    %% Client sends an older but known version -- server echoes it
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => <<"2024-11-05">>,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"old-client">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        mcp_session:handle_message(Session, InitReq),
    ?assertEqual(<<"2024-11-05">>,
                 maps:get(<<"protocolVersion">>, Result)).

client_version_negotiation_unknown(Config) ->
    Session = proplists:get_value(session, Config),
    %% Client sends an unrecognized version -- server responds with its latest
    InitReq = mcp_jsonrpc:request(1, <<"initialize">>, #{
        <<"protocolVersion">> => <<"2099-01-01">>,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"future-client">>, <<"version">> => <<"0">>}
    }),
    {reply, #jsonrpc_response{result = Result}} =
        mcp_session:handle_message(Session, InitReq),
    ?assertEqual(?MCP_PROTOCOL_VERSION,
                 maps:get(<<"protocolVersion">>, Result)).
