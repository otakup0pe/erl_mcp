-module(erl_mcp_transport_sse).
%% @private
%% Internal module -- legacy SSE {@link erl_mcp_transport} implementation.
%%
%% Uses a persistent GET connection (via {@link erl_mcp_sse_stream}) to
%% receive SSE events and POSTs JSON-RPC messages to the endpoint URL
%% advertised in the `endpoint` SSE event.

-behaviour(erl_mcp_transport).

-include_lib("kernel/include/logger.hrl").

-export([connect/1, request/3, notify/2, close/1, update_auth/2]).

-record(handle, {
    base_url :: string(),
    endpoint_url :: string(),
    auth :: term(),
    request_timeout :: pos_integer(),
    profile :: atom(),
    stream_pid :: pid()
}).

connect(Config) ->
    UrlBin = maps:get(server_url, Config),
    Url = unicode:characters_to_list(UrlBin),
    Auth = maps:get(auth, Config, none),
    Timeout = maps:get(timeout, Config, 30000),
    Profile = ensure_profile(),
    case ensure_inets_started() of
        ok ->
            case ensure_ssl_started() of
                ok ->
                    do_connect(Url, Auth, Timeout, Profile);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

request(#handle{} = H, Message, Timeout) ->
    Headers = [{"accept", "application/json"}] ++ auth_headers(H#handle.auth),
    Body = iolist_to_binary(Message),
    Req = {H#handle.endpoint_url, Headers, "application/json", Body},
    HttpOpts = [{timeout, Timeout}],
    Opts = [{body_format, binary}, {full_result, true}],
    case httpc:request(post, Req, HttpOpts, Opts, H#handle.profile) of
        {ok, {{_, Status, _}, _RespHeaders, RespBody}}
          when Status >= 200, Status < 300 ->
            case RespBody of
                <<>> ->
                    %% Empty body (e.g. 202 Accepted) -- response
                    %% will arrive on the SSE stream
                    await_sse_response(H, Timeout);
                _ ->
                    %% Inline response
                    {ok, RespBody, H}
            end;
        {ok, {{_, 404, _}, _, _}} ->
            {error, session_not_found, H};
        {ok, {{_, Status, _}, _, RespBody}} ->
            {error, {http_status, Status, RespBody}, H};
        {error, Reason} ->
            {error, {transport_error, Reason}, H}
    end.

notify(#handle{} = H, Message) ->
    Headers = [{"accept", "application/json"}] ++ auth_headers(H#handle.auth),
    Body = iolist_to_binary(Message),
    Req = {H#handle.endpoint_url, Headers, "application/json", Body},
    HttpOpts = [{timeout, H#handle.request_timeout}],
    Opts = [{body_format, binary}, {full_result, true}],
    case httpc:request(post, Req, HttpOpts, Opts, H#handle.profile) of
        {ok, {{_, Status, _}, _, _}} when Status >= 200, Status < 300 ->
            {ok, H};
        {ok, {{_, Status, _}, _, RespBody}} ->
            {error, {http_status, Status, RespBody}, H};
        {error, Reason} ->
            {error, {transport_error, Reason}, H}
    end.

close(#handle{stream_pid = Pid}) ->
    erl_mcp_sse_stream:stop(Pid),
    ok.

update_auth(#handle{} = H, Auth) ->
    {ok, H#handle{auth = Auth}}.

do_connect(Url, Auth, Timeout, Profile) ->
    Headers = [{"accept", "text/event-stream"}] ++ auth_headers(Auth),
    StreamConfig = #{url => Url,
                     headers => Headers,
                     profile => Profile},
    case erl_mcp_sse_stream:start_link(StreamConfig) of
        {ok, StreamPid} ->
            case erl_mcp_sse_stream:await_endpoint(StreamPid, Timeout) of
                {ok, EndpointBin} ->
                    EndpointUrl = resolve_url(Url, EndpointBin),
                    ?LOG_INFO("SSE transport connected, endpoint: ~s",
                              [EndpointUrl]),
                    {ok, #handle{
                        base_url = Url,
                        endpoint_url = EndpointUrl,
                        auth = Auth,
                        request_timeout = Timeout,
                        profile = Profile,
                        stream_pid = StreamPid
                    }};
                {error, Reason} ->
                    erl_mcp_sse_stream:stop(StreamPid),
                    {error, {endpoint_timeout, Reason}}
            end;
        {error, Reason} ->
            {error, {stream_start_failed, Reason}}
    end.

await_sse_response(#handle{stream_pid = StreamPid} = H, Timeout) ->
    case erl_mcp_sse_stream:await_message(StreamPid, Timeout) of
        {ok, Data} ->
            {ok, Data, H};
        {error, Reason} ->
            {error, {transport_error, Reason}, H}
    end.

-spec resolve_url(string(), binary()) -> string().
resolve_url(_BaseUrl, <<"http://", _/binary>> = Absolute) ->
    unicode:characters_to_list(Absolute);
resolve_url(_BaseUrl, <<"https://", _/binary>> = Absolute) ->
    unicode:characters_to_list(Absolute);
resolve_url(BaseUrl, Relative) when is_binary(Relative) ->
    BaseBin = unicode:characters_to_binary(BaseUrl),
    Resolved = uri_string:resolve(Relative, BaseBin),
    unicode:characters_to_list(Resolved).

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

ensure_profile() ->
    default.

ensure_inets_started() ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.

ensure_ssl_started() ->
    case application:ensure_all_started(ssl) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.
