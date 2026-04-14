-module(erl_mcp_client_tests).

-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").
-include("mcp_client.hrl").

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

encode(Msg) ->
    {ok, Bin} = mcp_jsonrpc:encode(Msg),
    Bin.

initialize_response(Id) ->
    encode(mcp_jsonrpc:response(Id, #{
        <<"protocolVersion">> => <<"2025-06-18">>,
        <<"capabilities">> => #{<<"tools">> => #{<<"listChanged">> => true}},
        <<"serverInfo">> => #{<<"name">> => <<"mock-server">>,
                              <<"version">> => <<"1.0">>}
    })).

tools_list_response(Id, Tools) ->
    encode(mcp_jsonrpc:response(Id, #{<<"tools">> => Tools})).

tools_call_response(Id, Content) ->
    encode(mcp_jsonrpc:response(Id, #{<<"content">> => Content,
                                       <<"isError">> => false})).

tools_call_error_response(Id, Content) ->
    encode(mcp_jsonrpc:response(Id, #{<<"content">> => Content,
                                       <<"isError">> => true})).

start_client(MockPid, ExtraConfig) ->
    Config = maps:merge(#{
        server_url => <<"mock://ignored">>,
        transport => mock_client_transport,
        mock_pid => MockPid
    }, ExtraConfig),
    erl_mcp_client:start_link(Config).

queue_initialize(MockPid) ->
    %% initialize (id=1) -> init response
    %% initialized notification (no response needed, but the mock
    %% still consumes a queued entry via the send path)
    ok = mock_client_transport:queue_response(MockPid, initialize_response(1)),
    ok = mock_client_transport:queue_response(MockPid, no_response).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

handshake_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    {ok, Pid} = start_client(Mock, #{}),
    Status = erl_mcp_client:status(Pid),
    ?assertEqual(ready, maps:get(state, Status)),
    ?assertEqual(<<"mock-server">>,
                 maps:get(<<"name">>, maps:get(server_info, Status))),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

list_tools_caches_results_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    Tools = [#{<<"name">> => <<"echo">>,
               <<"description">> => <<"Echoes input">>,
               <<"inputSchema">> => #{<<"type">> => <<"object">>}}],
    %% tools/list is id=2 after initialize (id=1)
    ok = mock_client_transport:queue_response(Mock, tools_list_response(2, Tools)),
    {ok, Pid} = start_client(Mock, #{}),
    {ok, [Tool]} = erl_mcp_client:list_tools(Pid),
    ?assertEqual(<<"echo">>, Tool#mcp_client_tool.name),
    ?assertEqual(<<"echo">>, Tool#mcp_client_tool.raw_name),
    %% Second call hits cache -- no new request sent
    SentBefore = length(mock_client_transport:sent_messages(Mock)),
    {ok, [Tool]} = erl_mcp_client:list_tools(Pid),
    SentAfter = length(mock_client_transport:sent_messages(Mock)),
    ?assertEqual(SentBefore, SentAfter),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

tool_prefix_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    Tools = [#{<<"name">> => <<"echo">>,
               <<"inputSchema">> => #{<<"type">> => <<"object">>}}],
    ok = mock_client_transport:queue_response(Mock, tools_list_response(2, Tools)),
    {ok, Pid} = start_client(Mock, #{tool_prefix => <<"mcp__srv">>}),
    {ok, [Tool]} = erl_mcp_client:list_tools(Pid),
    ?assertEqual(<<"mcp__srv__echo">>, Tool#mcp_client_tool.name),
    ?assertEqual(<<"echo">>, Tool#mcp_client_tool.raw_name),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

tools_call_success_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    Content = [#{<<"type">> => <<"text">>, <<"text">> => <<"hi">>}],
    ok = mock_client_transport:queue_response(Mock,
                                              tools_call_response(2, Content)),
    {ok, Pid} = start_client(Mock, #{}),
    {ok, Result} = erl_mcp_client:call(Pid, <<"echo">>, #{}, 5000),
    ?assertEqual(Content, maps:get(<<"content">>, Result)),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

tools_call_isError_returns_error_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    Content = [#{<<"type">> => <<"text">>, <<"text">> => <<"boom">>}],
    ok = mock_client_transport:queue_response(
           Mock, tools_call_error_response(2, Content)),
    {ok, Pid} = start_client(Mock, #{}),
    Res = erl_mcp_client:call(Pid, <<"fail">>, #{}, 5000),
    ?assertMatch({error, {tool_error, _}}, Res),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

tools_call_jsonrpc_error_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    ErrResp = encode(mcp_jsonrpc:error_response(2, ?METHOD_NOT_FOUND,
                                                 <<"nope">>)),
    ok = mock_client_transport:queue_response(Mock, ErrResp),
    {ok, Pid} = start_client(Mock, #{}),
    Res = erl_mcp_client:call(Pid, <<"missing">>, #{}, 5000),
    ?assertMatch({error, {jsonrpc_error, ?METHOD_NOT_FOUND, <<"nope">>}}, Res),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

tools_call_transport_error_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    ok = mock_client_transport:queue_error(Mock, {transport_error, timeout}),
    {ok, Pid} = start_client(Mock, #{}),
    Res = erl_mcp_client:call(Pid, <<"x">>, #{}, 5000),
    ?assertMatch({error, {transport_error, timeout}}, Res),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

tools_call_malformed_response_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    ok = mock_client_transport:queue_response(Mock, <<"not json at all">>),
    {ok, Pid} = start_client(Mock, #{}),
    Res = erl_mcp_client:call(Pid, <<"x">>, #{}, 5000),
    ?assertMatch({error, {malformed_response, _}}, Res),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

refresh_tools_bypasses_cache_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    ToolsA = [#{<<"name">> => <<"a">>,
                <<"inputSchema">> => #{<<"type">> => <<"object">>}}],
    ToolsB = [#{<<"name">> => <<"b">>,
                <<"inputSchema">> => #{<<"type">> => <<"object">>}}],
    ok = mock_client_transport:queue_response(Mock,
                                              tools_list_response(2, ToolsA)),
    ok = mock_client_transport:queue_response(Mock,
                                              tools_list_response(3, ToolsB)),
    {ok, Pid} = start_client(Mock, #{}),
    {ok, [First]} = erl_mcp_client:list_tools(Pid),
    ?assertEqual(<<"a">>, First#mcp_client_tool.name),
    {ok, [Second]} = erl_mcp_client:refresh_tools(Pid),
    ?assertEqual(<<"b">>, Second#mcp_client_tool.name),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

update_auth_test() ->
    Mock = mock_client_transport:new(),
    queue_initialize(Mock),
    {ok, Pid} = start_client(Mock, #{auth => {bearer, <<"old">>}}),
    ?assertEqual(ok, erl_mcp_client:update_auth(Pid, {bearer, <<"new">>})),
    erl_mcp_client:stop(Pid),
    mock_client_transport:stop(Mock).

child_spec_shape_test() ->
    Spec = erl_mcp_client:child_spec(#{server_url => <<"http://x">>}),
    ?assertEqual(worker, maps:get(type, Spec)),
    ?assertMatch({erl_mcp_client, start_link, [_]}, maps:get(start, Spec)).
