-module(mcp_jsonrpc_tests).
-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").

%%--------------------------------------------------------------------
%% Encode tests
%%--------------------------------------------------------------------

encode_request_test() ->
    Req = mcp_jsonrpc:request(1, <<"initialize">>, #{<<"key">> => <<"val">>}),
    {ok, Bin} = mcp_jsonrpc:encode(Req),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Decoded)),
    ?assertEqual(1, maps:get(<<"id">>, Decoded)),
    ?assertEqual(<<"initialize">>, maps:get(<<"method">>, Decoded)),
    ?assertEqual(#{<<"key">> => <<"val">>}, maps:get(<<"params">>, Decoded)).

encode_request_no_params_test() ->
    Req = mcp_jsonrpc:request(1, <<"ping">>, #{}),
    {ok, Bin} = mcp_jsonrpc:encode(Req),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertNot(maps:is_key(<<"params">>, Decoded)).

encode_request_string_id_test() ->
    Req = mcp_jsonrpc:request(<<"abc-123">>, <<"ping">>, #{}),
    {ok, Bin} = mcp_jsonrpc:encode(Req),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(<<"abc-123">>, maps:get(<<"id">>, Decoded)).

encode_response_test() ->
    Resp = mcp_jsonrpc:response(1, #{<<"status">> => <<"ok">>}),
    {ok, Bin} = mcp_jsonrpc:encode(Resp),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Decoded)),
    ?assertEqual(1, maps:get(<<"id">>, Decoded)),
    ?assertEqual(#{<<"status">> => <<"ok">>}, maps:get(<<"result">>, Decoded)).

encode_error_test() ->
    Err = mcp_jsonrpc:error_response(1, ?METHOD_NOT_FOUND, <<"not found">>),
    {ok, Bin} = mcp_jsonrpc:encode(Err),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Decoded)),
    ?assertEqual(1, maps:get(<<"id">>, Decoded)),
    ErrObj = maps:get(<<"error">>, Decoded),
    ?assertEqual(?METHOD_NOT_FOUND, maps:get(<<"code">>, ErrObj)),
    ?assertEqual(<<"not found">>, maps:get(<<"message">>, ErrObj)).

encode_error_with_data_test() ->
    Err = mcp_jsonrpc:error_response(1, ?INTERNAL_ERROR, <<"oops">>,
                                      #{<<"detail">> => <<"stack">>}),
    {ok, Bin} = mcp_jsonrpc:encode(Err),
    {ok, Decoded} = mcp_json:decode(Bin),
    ErrObj = maps:get(<<"error">>, Decoded),
    ?assertEqual(#{<<"detail">> => <<"stack">>}, maps:get(<<"data">>, ErrObj)).

encode_error_null_id_test() ->
    Err = mcp_jsonrpc:error_response(null, ?PARSE_ERROR, <<"parse error">>),
    {ok, Bin} = mcp_jsonrpc:encode(Err),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(null, maps:get(<<"id">>, Decoded)).

encode_notification_test() ->
    Notif = mcp_jsonrpc:notification(<<"notifications/initialized">>, #{}),
    {ok, Bin} = mcp_jsonrpc:encode(Notif),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Decoded)),
    ?assertEqual(<<"notifications/initialized">>, maps:get(<<"method">>, Decoded)),
    ?assertNot(maps:is_key(<<"id">>, Decoded)),
    ?assertNot(maps:is_key(<<"params">>, Decoded)).

encode_notification_with_params_test() ->
    Notif = mcp_jsonrpc:notification(<<"notifications/progress">>,
                                      #{<<"token">> => <<"t1">>}),
    {ok, Bin} = mcp_jsonrpc:encode(Notif),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(#{<<"token">> => <<"t1">>}, maps:get(<<"params">>, Decoded)).

%%--------------------------------------------------------------------
%% Decode tests
%%--------------------------------------------------------------------

decode_request_test() ->
    Json = <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>,
    {ok, Msg} = mcp_jsonrpc:decode(Json),
    ?assertMatch(#jsonrpc_request{id = 1, method = <<"ping">>}, Msg).

decode_request_with_params_test() ->
    Json = <<"{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\","
             "\"params\":{\"name\":\"echo\"}}">>,
    {ok, Msg} = mcp_jsonrpc:decode(Json),
    ?assertMatch(#jsonrpc_request{id = 42, method = <<"tools/call">>}, Msg),
    ?assertEqual(#{<<"name">> => <<"echo">>}, Msg#jsonrpc_request.params).

decode_response_test() ->
    Json = <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}">>,
    {ok, Msg} = mcp_jsonrpc:decode(Json),
    ?assertMatch(#jsonrpc_response{id = 1}, Msg),
    ?assertEqual(#{<<"ok">> => true}, Msg#jsonrpc_response.result).

decode_error_test() ->
    Json = <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":"
             "{\"code\":-32601,\"message\":\"not found\"}}">>,
    {ok, Msg} = mcp_jsonrpc:decode(Json),
    ?assertMatch(#jsonrpc_error{id = 1, code = ?METHOD_NOT_FOUND}, Msg),
    ?assertEqual(<<"not found">>, Msg#jsonrpc_error.message).

decode_error_with_data_test() ->
    Json = <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":"
             "{\"code\":-32603,\"message\":\"err\",\"data\":\"extra\"}}">>,
    {ok, Msg} = mcp_jsonrpc:decode(Json),
    ?assertEqual(<<"extra">>, Msg#jsonrpc_error.data).

decode_error_null_id_test() ->
    Json = <<"{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":"
             "{\"code\":-32700,\"message\":\"parse error\"}}">>,
    {ok, Msg} = mcp_jsonrpc:decode(Json),
    ?assertMatch(#jsonrpc_error{id = null, code = ?PARSE_ERROR}, Msg).

decode_notification_test() ->
    Json = <<"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}">>,
    {ok, Msg} = mcp_jsonrpc:decode(Json),
    ?assertMatch(#jsonrpc_notification{method = <<"notifications/initialized">>}, Msg).

decode_rejects_missing_jsonrpc_test() ->
    Json = <<"{\"id\":1,\"method\":\"ping\"}">>,
    ?assertMatch({error, missing_jsonrpc_field}, mcp_jsonrpc:decode(Json)).

decode_rejects_wrong_version_test() ->
    Json = <<"{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}">>,
    ?assertMatch({error, {invalid_version, _}}, mcp_jsonrpc:decode(Json)).

decode_rejects_invalid_json_test() ->
    ?assertMatch({error, _}, mcp_jsonrpc:decode(<<"not json">>)).

%%--------------------------------------------------------------------
%% Batch tests
%%--------------------------------------------------------------------

encode_batch_test() ->
    Req1 = mcp_jsonrpc:request(1, <<"ping">>, #{}),
    Req2 = mcp_jsonrpc:request(2, <<"ping">>, #{}),
    {batch, Msgs} = mcp_jsonrpc:batch([Req1, Req2]),
    {ok, Bin} = mcp_jsonrpc:encode({batch, Msgs}),
    {ok, Decoded} = mcp_json:decode(Bin),
    ?assertEqual(2, length(Decoded)).

decode_batch_test() ->
    Json = <<"[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"},"
             "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}]">>,
    {ok, {batch, Msgs}} = mcp_jsonrpc:decode(Json),
    ?assertEqual(2, length(Msgs)),
    ?assertMatch(#jsonrpc_request{id = 1}, hd(Msgs)).

batch_rejects_empty_test() ->
    ?assertEqual({error, empty_batch}, mcp_jsonrpc:batch([])).

decode_batch_rejects_empty_test() ->
    ?assertMatch({error, empty_batch}, mcp_jsonrpc:decode(<<"[]">>)).

%%--------------------------------------------------------------------
%% Error code mapping tests
%%--------------------------------------------------------------------

error_code_roundtrip_test_() ->
    Atoms = [parse_error, invalid_request, method_not_found,
             invalid_params, internal_error, resource_not_found],
    [fun() ->
        Code = mcp_jsonrpc:error_code(A),
        ?assertEqual(A, mcp_jsonrpc:error_atom(Code))
     end || A <- Atoms].

error_atom_unknown_test() ->
    ?assertEqual(unknown_error, mcp_jsonrpc:error_atom(9999)).

%%--------------------------------------------------------------------
%% Roundtrip tests
%%--------------------------------------------------------------------

roundtrip_request_test() ->
    Orig = mcp_jsonrpc:request(99, <<"tools/list">>, #{<<"cursor">> => <<"abc">>}),
    {ok, Bin} = mcp_jsonrpc:encode(Orig),
    {ok, Decoded} = mcp_jsonrpc:decode(Bin),
    ?assertEqual(Orig#jsonrpc_request.id, Decoded#jsonrpc_request.id),
    ?assertEqual(Orig#jsonrpc_request.method, Decoded#jsonrpc_request.method),
    ?assertEqual(Orig#jsonrpc_request.params, Decoded#jsonrpc_request.params).

roundtrip_response_test() ->
    Orig = mcp_jsonrpc:response(99, #{<<"tools">> => []}),
    {ok, Bin} = mcp_jsonrpc:encode(Orig),
    {ok, Decoded} = mcp_jsonrpc:decode(Bin),
    ?assertEqual(Orig#jsonrpc_response.id, Decoded#jsonrpc_response.id),
    ?assertEqual(Orig#jsonrpc_response.result, Decoded#jsonrpc_response.result).

roundtrip_notification_test() ->
    Orig = mcp_jsonrpc:notification(<<"notifications/tools/list_changed">>, #{}),
    {ok, Bin} = mcp_jsonrpc:encode(Orig),
    {ok, Decoded} = mcp_jsonrpc:decode(Bin),
    ?assertEqual(Orig#jsonrpc_notification.method,
                 Decoded#jsonrpc_notification.method).
