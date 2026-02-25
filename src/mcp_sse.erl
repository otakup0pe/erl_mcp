-module(mcp_sse).

%% Server-Sent Events encoding and decoding for MCP streamable HTTP.

-export([encode_event/1, encode_event/2, encode_event/3]).
-export([decode_events/1]).

%%--------------------------------------------------------------------
%% Encoding
%%--------------------------------------------------------------------

%% Encode a data-only SSE event.
-spec encode_event(binary()) -> iolist().
encode_event(Data) ->
    encode_event(undefined, Data).

%% Encode an SSE event with optional id.
-spec encode_event(undefined | binary(), binary()) -> iolist().
encode_event(Id, Data) ->
    encode_event(Id, undefined, Data).

%% Encode an SSE event with optional id and event type.
-spec encode_event(undefined | binary(), undefined | binary(), binary()) ->
    iolist().
encode_event(Id, EventType, Data) ->
    Parts = [],
    P1 = case Id of
        undefined -> Parts;
        _ -> [["id: ", Id, "\n"] | Parts]
    end,
    P2 = case EventType of
        undefined -> P1;
        _ -> [["event: ", EventType, "\n"] | P1]
    end,
    %% Data lines: split on newlines, each prefixed with "data: "
    DataLines = binary:split(Data, <<"\n">>, [global]),
    P3 = lists:foldl(fun(Line, Acc) ->
        [["data: ", Line, "\n"] | Acc]
    end, P2, DataLines),
    lists:reverse(["\n" | P3]).

%%--------------------------------------------------------------------
%% Decoding
%%--------------------------------------------------------------------

%% Parse an SSE event stream into a list of event maps.
%% Each event: #{id => binary(), event => binary(), data => binary()}
-spec decode_events(binary()) -> [map()].
decode_events(Bin) ->
    %% Events are separated by double newlines
    RawEvents = binary:split(Bin, <<"\n\n">>, [global]),
    lists:filtermap(fun(Block) ->
        case parse_event_block(Block) of
            #{data := _} = Event -> {true, Event};
            _ -> false
        end
    end, RawEvents).

parse_event_block(Block) ->
    Lines = binary:split(Block, <<"\n">>, [global]),
    lists:foldl(fun parse_event_line/2, #{}, Lines).

parse_event_line(<<"id: ", Id/binary>>, Acc) ->
    Acc#{id => Id};
parse_event_line(<<"event: ", Type/binary>>, Acc) ->
    Acc#{event => Type};
parse_event_line(<<"data: ", Data/binary>>, Acc) ->
    case maps:get(data, Acc, undefined) of
        undefined -> Acc#{data => Data};
        Existing -> Acc#{data => <<Existing/binary, "\n", Data/binary>>}
    end;
parse_event_line(_, Acc) ->
    Acc.
