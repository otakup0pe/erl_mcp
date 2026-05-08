-module(erl_mcp_protocol_json).
%% @doc false
%% Internal module -- thin wrapper over OTP 27 json module.

-export([encode/1, decode/1]).

-spec encode(term()) -> {ok, binary()} | {error, {encode_error, term()}}.
encode(Term) ->
    try
        {ok, iolist_to_binary(json:encode(Term))}
    catch
        error:badarg ->
            {error, {encode_error, badarg}}
    end.

-spec decode(binary()) -> {ok, term()} | {error, {decode_error, term()}}.
decode(Bin) ->
    try
        {ok, json:decode(Bin)}
    catch
        error:badarg ->
            {error, {decode_error, badarg}};
        error:{invalid_byte, _} = Reason ->
            {error, {decode_error, Reason}};
        error:{unexpected, _, _} = Reason ->
            {error, {decode_error, Reason}};
        error:{unexpected_end, _} = Reason ->
            {error, {decode_error, Reason}}
    end.
