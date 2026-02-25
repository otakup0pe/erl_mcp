-module(mcp_tool_tests).
-include_lib("eunit/include/eunit.hrl").
-include("mcp.hrl").

%%--------------------------------------------------------------------
%% Builder tests
%%--------------------------------------------------------------------

new_minimal_test() ->
    T = mcp_tool:new(<<"echo">>, #{<<"type">> => <<"object">>}),
    ?assertEqual(<<"echo">>, T#tool.name),
    ?assertEqual(undefined, T#tool.description),
    ?assertEqual(#{}, T#tool.annotations).

new_with_description_test() ->
    T = mcp_tool:new(<<"echo">>, <<"Echoes input">>,
                     #{<<"type">> => <<"object">>}),
    ?assertEqual(<<"Echoes input">>, T#tool.description).

new_with_annotations_test() ->
    Ann = #{<<"readOnlyHint">> => true},
    T = mcp_tool:new(<<"read">>, <<"Reads stuff">>,
                     #{<<"type">> => <<"object">>}, Ann),
    ?assertEqual(Ann, T#tool.annotations).

%%--------------------------------------------------------------------
%% Serialization tests
%%--------------------------------------------------------------------

to_map_minimal_test() ->
    T = mcp_tool:new(<<"echo">>, #{<<"type">> => <<"object">>}),
    Map = mcp_tool:to_map(T),
    ?assertEqual(<<"echo">>, maps:get(<<"name">>, Map)),
    ?assert(maps:is_key(<<"inputSchema">>, Map)),
    ?assertNot(maps:is_key(<<"description">>, Map)),
    ?assertNot(maps:is_key(<<"annotations">>, Map)).

to_map_full_test() ->
    Ann = #{<<"destructiveHint">> => true},
    T = mcp_tool:new(<<"delete">>, <<"Deletes things">>,
                     #{<<"type">> => <<"object">>}, Ann),
    Map = mcp_tool:to_map(T),
    ?assertEqual(<<"Deletes things">>, maps:get(<<"description">>, Map)),
    ?assertEqual(Ann, maps:get(<<"annotations">>, Map)).

from_map_test() ->
    Map = #{<<"name">> => <<"test">>,
            <<"inputSchema">> => #{<<"type">> => <<"object">>},
            <<"description">> => <<"A test tool">>},
    {ok, T} = mcp_tool:from_map(Map),
    ?assertEqual(<<"test">>, T#tool.name),
    ?assertEqual(<<"A test tool">>, T#tool.description).

from_map_missing_name_test() ->
    ?assertEqual({error, missing_tool_name},
                 mcp_tool:from_map(#{<<"inputSchema">> => #{}})).

roundtrip_test() ->
    Orig = mcp_tool:new(<<"round">>, <<"Trips">>,
                        #{<<"type">> => <<"object">>,
                          <<"properties">> => #{<<"x">> => #{<<"type">> => <<"string">>}}},
                        #{<<"idempotentHint">> => true}),
    Map = mcp_tool:to_map(Orig),
    {ok, Parsed} = mcp_tool:from_map(Map),
    ?assertEqual(Orig#tool.name, Parsed#tool.name),
    ?assertEqual(Orig#tool.description, Parsed#tool.description),
    ?assertEqual(Orig#tool.annotations, Parsed#tool.annotations).

%%--------------------------------------------------------------------
%% Annotation validation tests
%%--------------------------------------------------------------------

valid_annotations_test() ->
    ?assertEqual(ok, mcp_tool:validate_annotations(#{
        <<"readOnlyHint">> => true,
        <<"destructiveHint">> => false
    })).

valid_annotations_with_title_test() ->
    ?assertEqual(ok, mcp_tool:validate_annotations(#{
        <<"title">> => <<"My Tool">>
    })).

invalid_annotation_key_test() ->
    ?assertMatch({error, {unknown_annotations, _}},
                 mcp_tool:validate_annotations(#{<<"bogus">> => true})).

invalid_annotation_type_test() ->
    ?assertMatch({error, {invalid_annotation_types, _}},
                 mcp_tool:validate_annotations(#{<<"readOnlyHint">> => <<"yes">>})).

empty_annotations_valid_test() ->
    ?assertEqual(ok, mcp_tool:validate_annotations(#{})).
