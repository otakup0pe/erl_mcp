-module(session_request_context_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

%%--------------------------------------------------------------------
%% Per-request context threading (S3)
%%
%% A per-request map (derived from HTTP request headers, e.g.
%% X-Consumer-Role) must reach the tool handler's Context argument.
%% RED until erl_mcp_server_session grows handle_message/3 that
%% threads a ReqCtx map into the handler Context, merged UNDER
%% session_id (so a rogue header cannot clobber session_id, and an
%% empty ReqCtx reproduces today's #{session_id => Id} exactly).
%%--------------------------------------------------------------------

setup_session(RoleHandler) ->
    Handlers = erl_mcp_server_protocol:default_handlers(),
    {ok, RegPid} = erl_mcp_server_tool_registry:start_link(),
    unlink(RegPid),
    Tool = #tool{name = <<"whoami">>,
                 input_schema = #{<<"type">> => <<"object">>}},
    ok = erl_mcp_server_tool_registry:register_tool(Tool, RoleHandler),
    Opts = #{role => server, handlers => Handlers,
             server_capabilities =>
                 erl_mcp_protocol_capability:server_capabilities(#{
                     tools => #{list_changed => true}})},
    {ok, Pid} = erl_mcp_server_session:start_link(Opts),
    Meta = #{client_info => #{name => <<"test">>, version => <<"0">>},
             client_capabilities => #{}},
    ok = erl_mcp_server_session:promote(Pid, Meta),
    {Pid, RegPid}.

teardown_session({Pid, RegPid}) ->
    gen_server:stop(Pid),
    gen_server:stop(RegPid).

role_echo_handler() ->
    fun(_Args, Ctx) ->
        Role = maps:get(consumer_role, Ctx, null),
        {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                   <<"text">> => Role}]}}
    end.

call_whoami(Pid, ReqCtx) ->
    CallMsg = erl_mcp_protocol_jsonrpc:request(1, <<"tools/call">>, #{
        <<"name">> => <<"whoami">>,
        <<"arguments">> => #{}
    }),
    {reply, Reply} = erl_mcp_server_session:handle_message(Pid, CallMsg, ReqCtx),
    Result = Reply#jsonrpc_response.result,
    [Content] = maps:get(<<"content">>, Result),
    maps:get(<<"text">>, Content).

%% Header-derived role reaches the tool handler's Context.
consumer_role_reaches_tool_handler_test() ->
    Ctx = setup_session(role_echo_handler()),
    {Pid, _} = Ctx,
    try
        ?assertEqual(<<"yopo-consumer">>,
                     call_whoami(Pid, #{consumer_role => <<"yopo-consumer">>}))
    after
        teardown_session(Ctx)
    end.

%% Empty ReqCtx yields today's context (no consumer_role -> null).
empty_req_ctx_has_no_role_test() ->
    Ctx = setup_session(role_echo_handler()),
    {Pid, _} = Ctx,
    try
        ?assertEqual(null, call_whoami(Pid, #{}))
    after
        teardown_session(Ctx)
    end.

%% session_id is merged LAST: a header claiming session_id cannot clobber it.
req_ctx_cannot_override_session_id_test() ->
    SidHandler = fun(_Args, Ctx) ->
        Sid = maps:get(session_id, Ctx, null),
        {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                   <<"text">> => Sid}]}}
    end,
    Ctx = setup_session(SidHandler),
    {Pid, _} = Ctx,
    try
        Got = call_whoami(Pid, #{session_id => <<"forged">>,
                                 consumer_role => <<"r">>}),
        ?assertNotEqual(<<"forged">>, Got),
        ?assert(is_binary(Got))
    after
        teardown_session(Ctx)
    end.
