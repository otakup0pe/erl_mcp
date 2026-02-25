-module(mcp_json).

%% Thin wrapper over OTP 27 json module.
%% No jsx fallback -- OTP 27+ required.

-export([encode/1, decode/1]).

-spec encode(term()) -> {ok, binary()} | {error, {encode_error, term()}}.
encode(Term) ->
    try
        {ok, iolist_to_binary(json:encode(Term))}
    catch
        error:Reason ->
            {error, {encode_error, Reason}}
    end.

-spec decode(binary()) -> {ok, term()} | {error, {decode_error, term()}}.
decode(Bin) ->
    try
        {ok, json:decode(Bin)}
    catch
        error:Reason ->
            {error, {decode_error, Reason}}
    end.
