-module(mcp_content_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").

%%--------------------------------------------------------------------
%% TextContent tests
%%--------------------------------------------------------------------

text_content_test() ->
    T = erl_mcp_protocol_content:text(<<"hello">>),
    Map = erl_mcp_protocol_content:to_map(T),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Map)),
    ?assertNot(maps:is_key(<<"annotations">>, Map)).

text_content_with_annotations_test() ->
    Ann = #{<<"audience">> => [<<"user">>]},
    T = erl_mcp_protocol_content:text(<<"hello">>, Ann),
    Map = erl_mcp_protocol_content:to_map(T),
    ?assertEqual(Ann, maps:get(<<"annotations">>, Map)).

%%--------------------------------------------------------------------
%% ImageContent tests
%%--------------------------------------------------------------------

image_content_test() ->
    I = erl_mcp_protocol_content:image(<<"base64data">>, <<"image/png">>),
    Map = erl_mcp_protocol_content:to_map(I),
    ?assertEqual(<<"image">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"base64data">>, maps:get(<<"data">>, Map)),
    ?assertEqual(<<"image/png">>, maps:get(<<"mimeType">>, Map)).

image_content_with_annotations_test() ->
    Ann = #{<<"priority">> => 0.5},
    I = erl_mcp_protocol_content:image(<<"data">>, <<"image/jpeg">>, Ann),
    Map = erl_mcp_protocol_content:to_map(I),
    ?assertEqual(Ann, maps:get(<<"annotations">>, Map)).

%%--------------------------------------------------------------------
%% AudioContent tests
%%--------------------------------------------------------------------

audio_content_test() ->
    A = erl_mcp_protocol_content:audio(<<"audiodata">>, <<"audio/wav">>),
    Map = erl_mcp_protocol_content:to_map(A),
    ?assertEqual(<<"audio">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"audiodata">>, maps:get(<<"data">>, Map)),
    ?assertEqual(<<"audio/wav">>, maps:get(<<"mimeType">>, Map)).

audio_content_with_annotations_test() ->
    Ann = #{<<"priority">> => 1.0},
    A = erl_mcp_protocol_content:audio(<<"data">>, <<"audio/mp3">>, Ann),
    Map = erl_mcp_protocol_content:to_map(A),
    ?assertEqual(Ann, maps:get(<<"annotations">>, Map)).

%%--------------------------------------------------------------------
%% EmbeddedResource tests
%%--------------------------------------------------------------------

embedded_resource_test() ->
    Res = #{<<"uri">> => <<"file:///test.md">>,
            <<"mimeType">> => <<"text/markdown">>,
            <<"text">> => <<"# Hello">>},
    E = erl_mcp_protocol_content:embedded_resource(Res),
    Map = erl_mcp_protocol_content:to_map(E),
    ?assertEqual(<<"resource">>, maps:get(<<"type">>, Map)),
    ?assertEqual(Res, maps:get(<<"resource">>, Map)).

embedded_resource_with_annotations_test() ->
    Res = #{<<"uri">> => <<"file:///test.md">>},
    Ann = #{<<"audience">> => [<<"assistant">>]},
    E = erl_mcp_protocol_content:embedded_resource(Res, Ann),
    Map = erl_mcp_protocol_content:to_map(E),
    ?assertEqual(Ann, maps:get(<<"annotations">>, Map)).
