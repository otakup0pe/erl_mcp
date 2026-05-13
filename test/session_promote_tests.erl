-module(session_promote_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

%%--------------------------------------------------------------------
%% promote/2
%%--------------------------------------------------------------------

promote_transitions_to_initialized_test() ->
    Opts = #{role => server,
             handlers => #{},
             server_capabilities =>
                 erl_mcp_protocol_capability:server_capabilities(#{}),
             server_info => #implementation{name = <<"test">>,
                                            version = <<"0">>}},
    {ok, Pid} = erl_mcp_server_session:start_link(Opts),
    Info = erl_mcp_server_session:get_state(Pid),
    ?assertEqual(uninitialized, maps:get(status, Info)),
    Meta = #{client_info => #{name => <<"claude">>, version => <<"1.0">>},
             client_capabilities => #{}},
    ?assertEqual(ok, erl_mcp_server_session:promote(Pid, Meta)),
    Info2 = erl_mcp_server_session:get_state(Pid),
    ?assertEqual(initialized, maps:get(status, Info2)),
    gen_server:stop(Pid).

promote_rejects_already_initialized_test() ->
    Opts = #{role => server, handlers => #{}},
    {ok, Pid} = erl_mcp_server_session:start_link(Opts),
    Meta = #{client_info => #{name => <<"test">>, version => <<"0">>},
             client_capabilities => #{}},
    ok = erl_mcp_server_session:promote(Pid, Meta),
    ?assertEqual({error, already_initialized},
                 erl_mcp_server_session:promote(Pid, Meta)),
    gen_server:stop(Pid).

promote_accepts_tool_call_after_test() ->
    EchoHandler = fun(Args, _Ctx) ->
        Msg = maps:get(<<"message">>, Args, <<"default">>),
        {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                   <<"text">> => Msg}]}}
    end,
    Handlers = erl_mcp_server_protocol:default_handlers(),
    {ok, RegPid} = erl_mcp_server_tool_registry:start_link(),
    unlink(RegPid),
    Tool = #tool{name = <<"echo">>,
                 input_schema = #{<<"type">> => <<"object">>}},
    ok = erl_mcp_server_tool_registry:register_tool(Tool, EchoHandler),
    Opts = #{role => server, handlers => Handlers,
             server_capabilities =>
                 erl_mcp_protocol_capability:server_capabilities(#{
                     tools => #{list_changed => true}})},
    {ok, Pid} = erl_mcp_server_session:start_link(Opts),
    Meta = #{client_info => #{name => <<"test">>, version => <<"0">>},
             client_capabilities => #{}},
    ok = erl_mcp_server_session:promote(Pid, Meta),
    CallMsg = erl_mcp_protocol_jsonrpc:request(1, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"message">> => <<"hello">>}
    }),
    {reply, Reply} = erl_mcp_server_session:handle_message(Pid, CallMsg),
    ?assertMatch(#jsonrpc_response{id = 1}, Reply),
    Result = Reply#jsonrpc_response.result,
    [Content] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Content)),
    gen_server:stop(Pid),
    gen_server:stop(RegPid).

promote_with_undefined_fields_test() ->
    Opts = #{role => server, handlers => #{}},
    {ok, Pid} = erl_mcp_server_session:start_link(Opts),
    Meta = #{},
    ?assertEqual(ok, erl_mcp_server_session:promote(Pid, Meta)),
    Info = erl_mcp_server_session:get_state(Pid),
    ?assertEqual(initialized, maps:get(status, Info)),
    gen_server:stop(Pid).
