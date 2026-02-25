-module(ping_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    server_responds_to_ping/1,
    ping_before_initialize/1,
    ping_returns_empty_result/1
]).

all() -> [
    server_responds_to_ping,
    ping_before_initialize,
    ping_returns_empty_result
].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    {ok, Transport} = mock_transport:start_link(),
    {ok, Session} = mcp_session:start_link(#{
        role => server,
        transport_pid => Transport
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

server_responds_to_ping(Config) ->
    Session = proplists:get_value(session, Config),
    PingReq = mcp_jsonrpc:request(1, <<"ping">>, #{}),
    {reply, Reply} = mcp_session:handle_message(Session, PingReq),
    ?assertMatch(#jsonrpc_response{id = 1, result = #{}}, Reply).

ping_before_initialize(Config) ->
    %% Ping should work even before initialize (it's a utility method)
    Session = proplists:get_value(session, Config),
    PingReq = mcp_jsonrpc:request(42, <<"ping">>, #{}),
    {reply, Reply} = mcp_session:handle_message(Session, PingReq),
    ?assertMatch(#jsonrpc_response{id = 42}, Reply).

ping_returns_empty_result(Config) ->
    Session = proplists:get_value(session, Config),
    PingReq = mcp_jsonrpc:request(1, <<"ping">>, #{}),
    {reply, #jsonrpc_response{result = Result}} =
        mcp_session:handle_message(Session, PingReq),
    ?assertEqual(#{}, Result).
