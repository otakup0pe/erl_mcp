-module(erl_mcp_transport_http_streamable).

%% HTTP streamable transport for the MCP client.
%%
%% Implements the request/response half of the MCP HTTP transport
%% (POST application/json, Mcp-Session-Id header, MCP-Protocol-Version
%% header). SSE GET stream support is deliberately not implemented --
%% Phase 1-4 only needs synchronous request/response; pushed
%% notifications arrive inside POST response bodies when the server
%% is able to piggyback them, or are received when the client issues
%% the next request.

-behaviour(erl_mcp_transport).

-include_lib("kernel/include/logger.hrl").

-export([connect/1, request/3, notify/2, close/1, update_auth/2]).

-record(handle, {
    url :: string(),
    auth :: term(),
    protocol_version :: binary(),
    session_id :: undefined | binary(),
    request_timeout :: pos_integer(),
    profile :: atom()
}).

connect(Config) ->
    UrlBin = maps:get(server_url, Config),
    Url = unicode:characters_to_list(UrlBin),
    Auth = maps:get(auth, Config, none),
    ProtoVsn = maps:get(protocol_version, Config),
    Timeout = maps:get(timeout, Config, 30000),
    Profile = ensure_profile(),
    case ensure_inets_started() of
        ok ->
            {ok, #handle{
                url = Url,
                auth = Auth,
                protocol_version = ProtoVsn,
                request_timeout = Timeout,
                profile = Profile
            }};
        {error, _} = Err ->
            Err
    end.

request(#handle{} = H, Message, Timeout) ->
    Headers = build_headers(H, request),
    Body = iolist_to_binary(Message),
    Req = {H#handle.url, Headers, "application/json", Body},
    HttpOpts = [{timeout, Timeout}],
    Opts = [{body_format, binary}, {full_result, true}],
    case httpc:request(post, Req, HttpOpts, Opts, H#handle.profile) of
        {ok, {{_, Status, _}, RespHeaders, RespBody}} ->
            NewSession = find_session_id(RespHeaders, H#handle.session_id),
            H1 = H#handle{session_id = NewSession},
            handle_response(Status, RespBody, H1);
        {error, Reason} ->
            {error, {transport_error, Reason}, H}
    end.

notify(#handle{} = H, Message) ->
    Headers = build_headers(H, notify),
    Body = iolist_to_binary(Message),
    Req = {H#handle.url, Headers, "application/json", Body},
    HttpOpts = [{timeout, H#handle.request_timeout}],
    Opts = [{body_format, binary}, {full_result, true}],
    case httpc:request(post, Req, HttpOpts, Opts, H#handle.profile) of
        {ok, {{_, Status, _}, RespHeaders, _RespBody}} when Status >= 200, Status < 300 ->
            NewSession = find_session_id(RespHeaders, H#handle.session_id),
            {ok, H#handle{session_id = NewSession}};
        {ok, {{_, Status, _}, _, RespBody}} ->
            {error, {http_status, Status, RespBody}, H};
        {error, Reason} ->
            {error, {transport_error, Reason}, H}
    end.

close(#handle{}) ->
    ok.

update_auth(#handle{} = H, Auth) ->
    {ok, H#handle{auth = Auth}}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

handle_response(Status, Body, H) when Status >= 200, Status < 300 ->
    {ok, Body, H};
handle_response(404, _Body, H) ->
    {error, session_not_found, H#handle{session_id = undefined}};
handle_response(Status, Body, H) ->
    {error, {http_status, Status, Body}, H}.

build_headers(#handle{protocol_version = Proto,
                      auth = Auth,
                      session_id = Sid}, _Kind) ->
    Base = [
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", unicode:characters_to_list(Proto)}
    ],
    WithSid = case Sid of
        undefined -> Base;
        _ -> [{"mcp-session-id", unicode:characters_to_list(Sid)} | Base]
    end,
    WithSid ++ auth_headers(Auth).

auth_headers(none) ->
    [];
auth_headers({bearer, Token}) when is_binary(Token) ->
    [{"authorization",
      "Bearer " ++ unicode:characters_to_list(Token)}];
auth_headers({header, Name, Value})
  when is_binary(Name), is_binary(Value) ->
    [{unicode:characters_to_list(Name), unicode:characters_to_list(Value)}];
auth_headers({custom_headers, Pairs}) when is_list(Pairs) ->
    [{unicode:characters_to_list(N), unicode:characters_to_list(V)}
     || {N, V} <- Pairs, is_binary(N), is_binary(V)].

find_session_id(Headers, Current) ->
    case lists:keyfind("mcp-session-id", 1, Headers) of
        {_, Value} when is_list(Value), Value =/= [] ->
            unicode:characters_to_binary(Value);
        _ ->
            Current
    end.

ensure_profile() ->
    %% place holder for future profile knob
    default.

ensure_inets_started() ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.
