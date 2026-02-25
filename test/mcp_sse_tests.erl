-module(mcp_sse_tests).
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Encode tests
%%--------------------------------------------------------------------

encode_data_only_test() ->
    Event = iolist_to_binary(mcp_sse:encode_event(<<"hello">>)),
    ?assertEqual(<<"data: hello\n\n">>, Event).

encode_with_id_test() ->
    Event = iolist_to_binary(mcp_sse:encode_event(<<"1">>, <<"hello">>)),
    ?assertEqual(<<"id: 1\ndata: hello\n\n">>, Event).

encode_with_id_and_type_test() ->
    Event = iolist_to_binary(
        mcp_sse:encode_event(<<"1">>, <<"message">>, <<"hello">>)),
    ?assertEqual(<<"id: 1\nevent: message\ndata: hello\n\n">>, Event).

encode_multiline_data_test() ->
    Event = iolist_to_binary(
        mcp_sse:encode_event(<<"line1\nline2\nline3">>)),
    ?assertEqual(<<"data: line1\ndata: line2\ndata: line3\n\n">>, Event).

encode_no_id_with_type_test() ->
    Event = iolist_to_binary(
        mcp_sse:encode_event(undefined, <<"endpoint">>, <<"data">>)),
    ?assertEqual(<<"event: endpoint\ndata: data\n\n">>, Event).

%%--------------------------------------------------------------------
%% Decode tests
%%--------------------------------------------------------------------

decode_simple_event_test() ->
    Events = mcp_sse:decode_events(<<"data: hello\n\n">>),
    ?assertEqual(1, length(Events)),
    [E] = Events,
    ?assertEqual(<<"hello">>, maps:get(data, E)).

decode_event_with_id_test() ->
    Events = mcp_sse:decode_events(<<"id: 42\ndata: test\n\n">>),
    [E] = Events,
    ?assertEqual(<<"42">>, maps:get(id, E)),
    ?assertEqual(<<"test">>, maps:get(data, E)).

decode_event_with_type_test() ->
    Events = mcp_sse:decode_events(<<"event: msg\ndata: hi\n\n">>),
    [E] = Events,
    ?assertEqual(<<"msg">>, maps:get(event, E)),
    ?assertEqual(<<"hi">>, maps:get(data, E)).

decode_multiline_data_test() ->
    Events = mcp_sse:decode_events(
        <<"data: line1\ndata: line2\n\n">>),
    [E] = Events,
    ?assertEqual(<<"line1\nline2">>, maps:get(data, E)).

decode_multiple_events_test() ->
    Stream = <<"data: first\n\ndata: second\n\n">>,
    Events = mcp_sse:decode_events(Stream),
    ?assertEqual(2, length(Events)).

decode_empty_block_skipped_test() ->
    Events = mcp_sse:decode_events(<<"\n\n">>),
    ?assertEqual(0, length(Events)).

%%--------------------------------------------------------------------
%% Roundtrip tests
%%--------------------------------------------------------------------

roundtrip_simple_test() ->
    Encoded = iolist_to_binary(mcp_sse:encode_event(<<"test data">>)),
    [Decoded] = mcp_sse:decode_events(Encoded),
    ?assertEqual(<<"test data">>, maps:get(data, Decoded)).

roundtrip_with_id_test() ->
    Encoded = iolist_to_binary(
        mcp_sse:encode_event(<<"evt-1">>, <<"{\"jsonrpc\":\"2.0\"}">>)),
    [Decoded] = mcp_sse:decode_events(Encoded),
    ?assertEqual(<<"evt-1">>, maps:get(id, Decoded)),
    ?assertEqual(<<"{\"jsonrpc\":\"2.0\"}">>, maps:get(data, Decoded)).
