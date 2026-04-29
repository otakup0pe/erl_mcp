-module(mcp_jsonrpc).
%% @private
%% Internal module -- JSON-RPC 2.0 wire format for MCP sessions.

-include("mcp.hrl").

-export([encode/1, decode/1]).
-export([request/3, response/2, error_response/3, error_response/4,
         notification/2, batch/1]).
-export([error_code/1, error_atom/1]).

-spec request(binary() | integer(), binary(), map()) -> #jsonrpc_request{}.
request(Id, Method, Params) ->
    #jsonrpc_request{id = Id, method = Method, params = Params}.

-spec response(binary() | integer(), map()) -> #jsonrpc_response{}.
response(Id, Result) ->
    #jsonrpc_response{id = Id, result = Result}.

-spec error_response(binary() | integer() | null, integer(), binary()) ->
    #jsonrpc_error{}.
error_response(Id, Code, Message) ->
    #jsonrpc_error{id = Id, code = Code, message = Message, data = undefined}.

-spec error_response(binary() | integer() | null, integer(), binary(), term()) ->
    #jsonrpc_error{}.
error_response(Id, Code, Message, Data) ->
    #jsonrpc_error{id = Id, code = Code, message = Message, data = Data}.

-spec notification(binary(), map()) -> #jsonrpc_notification{}.
notification(Method, Params) ->
    #jsonrpc_notification{method = Method, params = Params}.

-spec batch([#jsonrpc_request{} | #jsonrpc_notification{}]) ->
    {batch, [#jsonrpc_request{} | #jsonrpc_notification{}]}.
batch([]) ->
    {error, empty_batch};
batch(Messages) when is_list(Messages) ->
    {batch, Messages}.

-spec encode(term()) -> {ok, binary()} | {error, term()}.
encode({batch, Messages}) when is_list(Messages) ->
    Encoded = [encode_message(M) || M <- Messages],
    mcp_json:encode(Encoded);
encode(#jsonrpc_request{} = Req) ->
    mcp_json:encode(encode_message(Req));
encode(#jsonrpc_response{} = Resp) ->
    mcp_json:encode(encode_message(Resp));
encode(#jsonrpc_error{} = Err) ->
    mcp_json:encode(encode_message(Err));
encode(#jsonrpc_notification{} = Notif) ->
    mcp_json:encode(encode_message(Notif));
encode(_) ->
    {error, invalid_message}.

encode_message(#jsonrpc_request{id = Id, method = Method, params = Params}) ->
    Base = #{<<"jsonrpc">> => ?JSONRPC_VERSION,
             <<"id">> => Id,
             <<"method">> => Method},
    case map_size(Params) of
        0 -> Base;
        _ -> Base#{<<"params">> => Params}
    end;
encode_message(#jsonrpc_response{id = Id, result = Result}) ->
    #{<<"jsonrpc">> => ?JSONRPC_VERSION,
      <<"id">> => Id,
      <<"result">> => Result};
encode_message(#jsonrpc_error{id = Id, code = Code, message = Msg,
                               data = Data}) ->
    ErrObj = case Data of
        undefined -> #{<<"code">> => Code, <<"message">> => Msg};
        _ -> #{<<"code">> => Code, <<"message">> => Msg, <<"data">> => Data}
    end,
    IdVal = case Id of
        null -> null;
        _ -> Id
    end,
    #{<<"jsonrpc">> => ?JSONRPC_VERSION,
      <<"id">> => IdVal,
      <<"error">> => ErrObj};
encode_message(#jsonrpc_notification{method = Method, params = Params}) ->
    Base = #{<<"jsonrpc">> => ?JSONRPC_VERSION,
             <<"method">> => Method},
    case map_size(Params) of
        0 -> Base;
        _ -> Base#{<<"params">> => Params}
    end.

-spec decode(binary()) -> {ok, term()} | {error, term()}.
decode(Bin) ->
    case mcp_json:decode(Bin) of
        {ok, List} when is_list(List) ->
            decode_batch(List);
        {ok, Map} when is_map(Map) ->
            decode_message(Map);
        {ok, _} ->
            {error, invalid_json_rpc};
        {error, _} = Err ->
            Err
    end.

decode_batch([]) ->
    {error, empty_batch};
decode_batch(Messages) ->
    Decoded = lists:map(fun(M) ->
        case decode_message(M) of
            {ok, Msg} -> Msg;
            {error, Reason} -> {decode_error, Reason}
        end
    end, Messages),
    {ok, {batch, Decoded}}.

decode_message(#{<<"jsonrpc">> := <<"2.0">>} = Map) ->
    HasId = maps:is_key(<<"id">>, Map),
    HasMethod = maps:is_key(<<"method">>, Map),
    HasResult = maps:is_key(<<"result">>, Map),
    HasError = maps:is_key(<<"error">>, Map),
    case {HasId, HasMethod, HasResult, HasError} of
        {true, true, false, false} ->
            decode_request(Map);
        {true, false, true, false} ->
            decode_response(Map);
        {true, false, false, true} ->
            decode_error(Map);
        {false, true, false, false} ->
            decode_notification(Map);
        {false, false, false, true} ->
            case maps:get(<<"id">>, Map, undefined) of
                undefined ->
                    decode_error_null_id(Map);
                _ ->
                    {error, invalid_json_rpc}
            end;
        _ ->
            {error, invalid_json_rpc}
    end;
decode_message(#{<<"jsonrpc">> := _}) ->
    {error, {invalid_version, <<"expected 2.0">>}};
decode_message(_) ->
    {error, missing_jsonrpc_field}.

decode_request(Map) ->
    Id = maps:get(<<"id">>, Map),
    Method = maps:get(<<"method">>, Map),
    Params = maps:get(<<"params">>, Map, #{}),
    case {is_valid_id(Id), is_binary(Method)} of
        {true, true} ->
            {ok, #jsonrpc_request{id = Id, method = Method, params = Params}};
        _ ->
            {error, invalid_request_fields}
    end.

decode_response(Map) ->
    Id = maps:get(<<"id">>, Map),
    Result = maps:get(<<"result">>, Map),
    case is_valid_id(Id) of
        true ->
            {ok, #jsonrpc_response{id = Id, result = Result}};
        false ->
            {error, invalid_response_fields}
    end.

decode_error(Map) ->
    Id = maps:get(<<"id">>, Map),
    ErrObj = maps:get(<<"error">>, Map),
    decode_error_obj(Id, ErrObj).

decode_error_null_id(Map) ->
    %% JSON null decodes to null atom in OTP json module
    case Map of
        #{<<"id">> := null, <<"error">> := ErrObj} ->
            decode_error_obj(null, ErrObj);
        _ ->
            {error, invalid_json_rpc}
    end.

decode_error_obj(Id, #{<<"code">> := Code, <<"message">> := Msg} = ErrObj)
  when is_integer(Code), is_binary(Msg) ->
    Data = maps:get(<<"data">>, ErrObj, undefined),
    {ok, #jsonrpc_error{id = Id, code = Code, message = Msg, data = Data}};
decode_error_obj(_, _) ->
    {error, invalid_error_object}.

decode_notification(Map) ->
    Method = maps:get(<<"method">>, Map),
    Params = maps:get(<<"params">>, Map, #{}),
    case is_binary(Method) of
        true ->
            {ok, #jsonrpc_notification{method = Method, params = Params}};
        false ->
            {error, invalid_notification_fields}
    end.

-spec error_code(atom()) -> integer().
error_code(parse_error) -> ?PARSE_ERROR;
error_code(invalid_request) -> ?INVALID_REQUEST;
error_code(method_not_found) -> ?METHOD_NOT_FOUND;
error_code(invalid_params) -> ?INVALID_PARAMS;
error_code(internal_error) -> ?INTERNAL_ERROR;
error_code(resource_not_found) -> ?RESOURCE_NOT_FOUND.

-spec error_atom(integer()) -> atom().
error_atom(?PARSE_ERROR) -> parse_error;
error_atom(?INVALID_REQUEST) -> invalid_request;
error_atom(?METHOD_NOT_FOUND) -> method_not_found;
error_atom(?INVALID_PARAMS) -> invalid_params;
error_atom(?INTERNAL_ERROR) -> internal_error;
error_atom(?RESOURCE_NOT_FOUND) -> resource_not_found;
error_atom(_) -> unknown_error.

is_valid_id(Id) when is_binary(Id) -> true;
is_valid_id(Id) when is_integer(Id) -> true;
is_valid_id(_) -> false.
