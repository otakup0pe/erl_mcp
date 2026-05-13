-module(mcp_json_tests).
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% encode/1
%%--------------------------------------------------------------------

encode_simple_map_test() ->
    {ok, Bin} = erl_mcp_protocol_json:encode(#{<<"key">> => <<"val">>}),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    ?assertEqual(<<"val">>, maps:get(<<"key">>, Decoded)).

encode_nested_map_test() ->
    Term = #{<<"a">> => #{<<"b">> => [1, 2, 3]}},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    ?assertEqual([1, 2, 3], maps:get(<<"b">>, maps:get(<<"a">>, Decoded))).

encode_integers_and_booleans_test() ->
    Term = #{<<"n">> => 42, <<"t">> => true, <<"f">> => false, <<"z">> => null},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    ?assertEqual(42, maps:get(<<"n">>, Decoded)),
    ?assertEqual(true, maps:get(<<"t">>, Decoded)),
    ?assertEqual(false, maps:get(<<"f">>, Decoded)),
    ?assertEqual(null, maps:get(<<"z">>, Decoded)).

encode_empty_map_test() ->
    {ok, Bin} = erl_mcp_protocol_json:encode(#{}),
    ?assertEqual(<<"{}">>, Bin).

encode_empty_list_test() ->
    {ok, Bin} = erl_mcp_protocol_json:encode([]),
    ?assertEqual(<<"[]">>, Bin).

%%--------------------------------------------------------------------
%% UTF-8 sanitization
%%--------------------------------------------------------------------

encode_valid_utf8_unchanged_test() ->
    Term = #{<<"text">> => <<"héllo wörld"/utf8>>},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    ?assertEqual(<<"héllo wörld"/utf8>>, maps:get(<<"text">>, Decoded)).

encode_invalid_utf8_sanitized_test() ->
    Bad = <<"hello ", 16#92, " world">>,
    Term = #{<<"text">> => Bad},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    Result = maps:get(<<"text">>, Decoded),
    ?assert(is_binary(Result)),
    ?assertNotEqual(nomatch, binary:match(Result, <<"hello">>)),
    ?assertNotEqual(nomatch, binary:match(Result, <<"world">>)).

encode_invalid_utf8_replaced_with_fffd_test() ->
    Bad = <<16#FF, 16#FE>>,
    Term = #{<<"v">> => Bad},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    Result = maps:get(<<"v">>, Decoded),
    Replacement = <<16#FFFD/utf8>>,
    ?assertEqual(<<Replacement/binary, Replacement/binary>>, Result).

encode_mixed_valid_invalid_utf8_test() ->
    Bad = <<"abc", 16#80, "def", 16#C0, "ghi">>,
    Term = #{<<"m">> => Bad},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    Result = maps:get(<<"m">>, Decoded),
    ?assertNotEqual(nomatch, binary:match(Result, <<"abc">>)),
    ?assertNotEqual(nomatch, binary:match(Result, <<"def">>)),
    ?assertNotEqual(nomatch, binary:match(Result, <<"ghi">>)).

encode_invalid_utf8_in_nested_map_test() ->
    Bad = <<"bad ", 16#92, " byte">>,
    Term = #{<<"outer">> => #{<<"inner">> => Bad}},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    Inner = maps:get(<<"inner">>, maps:get(<<"outer">>, Decoded)),
    ?assertNotEqual(nomatch, binary:match(Inner, <<"bad">>)),
    ?assertNotEqual(nomatch, binary:match(Inner, <<"byte">>)).

encode_invalid_utf8_in_list_test() ->
    Bad = <<"x", 16#92, "y">>,
    Term = [Bad, <<"clean">>],
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    ?assertEqual(2, length(Decoded)),
    ?assertEqual(<<"clean">>, lists:last(Decoded)).

encode_invalid_utf8_in_map_key_test() ->
    Bad = <<"key", 16#92>>,
    Term = #{Bad => <<"val">>},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    ?assertEqual(1, map_size(Decoded)).

encode_byte_146_at_position_32_test() ->
    Prefix = binary:copy(<<"a">>, 32),
    Bad = <<Prefix/binary, 16#92, "rest">>,
    Term = #{<<"content">> => [#{<<"type">> => <<"text">>,
                                 <<"text">> => Bad}]},
    {ok, Bin} = erl_mcp_protocol_json:encode(Term),
    {ok, Decoded} = erl_mcp_protocol_json:decode(Bin),
    [#{<<"text">> := Result}] = maps:get(<<"content">>, Decoded),
    ?assertNotEqual(nomatch, binary:match(Result, <<"rest">>)).

%%--------------------------------------------------------------------
%% decode/1
%%--------------------------------------------------------------------

decode_valid_json_test() ->
    {ok, Decoded} = erl_mcp_protocol_json:decode(<<"{\"a\":1}">>),
    ?assertEqual(1, maps:get(<<"a">>, Decoded)).

decode_invalid_json_test() ->
    ?assertMatch({error, {decode_error, _}},
                 erl_mcp_protocol_json:decode(<<"not json">>)).

decode_invalid_utf8_test() ->
    ?assertMatch({error, {decode_error, _}},
                 erl_mcp_protocol_json:decode(<<"{\"a\":\"", 16#92, "\"}">>)).
