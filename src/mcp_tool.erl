-module(mcp_tool).

%% Tool definition builder and serialization.

-include("mcp.hrl").

-export([new/2, new/3, new/4]).
-export([to_map/1, from_map/1]).
-export([validate_annotations/1]).

%%--------------------------------------------------------------------
%% Builders
%%--------------------------------------------------------------------

-spec new(binary(), map()) -> #tool{}.
new(Name, InputSchema) ->
    #tool{name = Name, input_schema = InputSchema}.

-spec new(binary(), binary(), map()) -> #tool{}.
new(Name, Description, InputSchema) ->
    #tool{name = Name, description = Description, input_schema = InputSchema}.

-spec new(binary(), binary(), map(), map()) -> #tool{}.
new(Name, Description, InputSchema, Annotations) ->
    #tool{name = Name, description = Description,
          input_schema = InputSchema, annotations = Annotations}.

%%--------------------------------------------------------------------
%% Serialization
%%--------------------------------------------------------------------

-spec to_map(#tool{}) -> map().
to_map(#tool{name = Name, description = Desc, input_schema = Schema,
              annotations = Ann}) ->
    Base = #{<<"name">> => Name, <<"inputSchema">> => Schema},
    M1 = case Desc of
        undefined -> Base;
        _ -> Base#{<<"description">> => Desc}
    end,
    case map_size(Ann) of
        0 -> M1;
        _ -> M1#{<<"annotations">> => Ann}
    end.

-spec from_map(map()) -> {ok, #tool{}} | {error, term()}.
from_map(#{<<"name">> := Name} = Map) when is_binary(Name) ->
    Schema = maps:get(<<"inputSchema">>, Map,
                      #{<<"type">> => <<"object">>}),
    Desc = maps:get(<<"description">>, Map, undefined),
    Ann = maps:get(<<"annotations">>, Map, #{}),
    {ok, #tool{name = Name, description = Desc,
               input_schema = Schema, annotations = Ann}};
from_map(_) ->
    {error, missing_tool_name}.

%%--------------------------------------------------------------------
%% Annotation validation
%%--------------------------------------------------------------------

%% Validates tool annotation hints per MCP spec.
-spec validate_annotations(map()) -> ok | {error, term()}.
validate_annotations(Ann) when is_map(Ann) ->
    ValidKeys = [<<"title">>, <<"readOnlyHint">>, <<"destructiveHint">>,
                 <<"idempotentHint">>, <<"openWorldHint">>],
    BoolKeys = [<<"readOnlyHint">>, <<"destructiveHint">>,
                <<"idempotentHint">>, <<"openWorldHint">>],
    %% Check all keys are valid
    Keys = maps:keys(Ann),
    Invalid = [K || K <- Keys, not lists:member(K, ValidKeys)],
    case Invalid of
        [] ->
            %% Check bool keys are booleans
            BadBools = [K || K <- BoolKeys,
                        maps:is_key(K, Ann),
                        not is_boolean(maps:get(K, Ann))],
            case BadBools of
                [] -> ok;
                _ -> {error, {invalid_annotation_types, BadBools}}
            end;
        _ ->
            {error, {unknown_annotations, Invalid}}
    end;
validate_annotations(_) ->
    {error, not_a_map}.
