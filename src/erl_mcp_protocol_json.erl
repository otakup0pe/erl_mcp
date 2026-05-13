-module(erl_mcp_protocol_json).
%% @doc false
%% Internal module -- thin wrapper over OTP 27 json module.
%%
%% Uses a custom encoder that sanitizes binaries containing invalid
%% UTF-8 (replacing bad bytes with U+FFFD) so the wire serializer
%% never crashes on content returned by tool handlers.

-export([encode/1, decode/1]).

-spec encode(term()) -> {ok, binary()} | {error, {encode_error, term()}}.
encode(Term) ->
    try
        {ok, iolist_to_binary(json:encode(Term, fun encoder/2))}
    catch
        error:badarg ->
            {error, {encode_error, badarg}};
        error:{invalid_byte, _} = Reason ->
            {error, {encode_error, Reason}}
    end.

encoder(Bin, _Encode) when is_binary(Bin) ->
    json:encode_binary(sanitize_utf8(Bin));
encoder(Other, Encode) ->
    json:encode_value(Other, Encode).

sanitize_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Result when is_binary(Result) -> Result;
        _ -> sanitize_utf8_bytes(Bin, <<>>)
    end.

sanitize_utf8_bytes(<<>>, Acc) -> Acc;
sanitize_utf8_bytes(<<C/utf8, Rest/binary>>, Acc) ->
    sanitize_utf8_bytes(Rest, <<Acc/binary, C/utf8>>);
sanitize_utf8_bytes(<<_, Rest/binary>>, Acc) ->
    sanitize_utf8_bytes(Rest, <<Acc/binary, 16#FFFD/utf8>>).

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
