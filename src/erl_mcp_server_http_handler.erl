-module(erl_mcp_server_http_handler).

%% @doc Cowboy handler for the MCP streamable HTTP transport.
%%
%% Handles POST (JSON-RPC dispatch), GET (SSE stream, not yet
%% implemented), and DELETE (session teardown). Session identity
%% is carried via the `Mcp-Session-Id' header. Wire this module
%% into your cowboy router; no public API beyond `init/2'.
%%
%% Example:
%% ```
%% Dispatch = cowboy_router:compile([
%%     {'_', [{"/mcp", erl_mcp_server_http_handler, #{
%%         handlers => erl_mcp_server_protocol:default_handlers()
%%     }}]}
%% ]),
%% cowboy:start_clear(my_listener, [{port, 8080}],
%%     #{env => #{dispatch => Dispatch}}).
%% '''

-include("erl_mcp.hrl").

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case Method of
        <<"POST">> ->
            handle_post(Req0, State);
        <<"GET">> ->
            handle_get(Req0, State);
        <<"DELETE">> ->
            handle_delete(Req0, State);
        _ ->
            Req = cowboy_req:reply(405, #{}, <<>>, Req0),
            {ok, Req, State}
    end.

handle_post(Req0, State) ->
    MaxBody = application:get_env(erl_mcp, max_request_body, 1048576),
    case read_full_body(Req0, MaxBody) of
        {ok, Body, Req1} ->
            handle_post_body(Body, Req1, State);
        {error, too_large, Req1} ->
            Req2 = cowboy_req:reply(413,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":\"Request body too large\"}">>,
                Req1),
            {ok, Req2, State}
    end.

handle_post_body(Body, Req1, State) ->
    case erl_mcp_protocol_jsonrpc:decode(Body) of
        {ok, {batch, Messages}} ->
            handle_batch(Messages, Req1, State);
        {ok, Message} ->
            handle_single_message(Message, Req1, State);
        {error, Reason} ->
            logger:warning("http_handler: JSON-RPC decode error: ~p", [Reason]),
            send_jsonrpc_error(null, ?PARSE_ERROR,
                               <<"Parse error">>, Req1, State)
    end.

handle_single_message(#jsonrpc_notification{} = Notif, Req0, State) ->
    SessionPid = get_or_create_session(Req0, State),
    case SessionPid of
        {ok, Pid, Req1} ->
            erl_mcp_server_session:handle_message(Pid, Notif),
            Req = cowboy_req:reply(202, #{}, <<>>, Req1),
            {ok, Req, State};
        {error, Req1} ->
            Req = cowboy_req:reply(404,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":\"Invalid session\"}">>, Req1),
            {ok, Req, State}
    end;
handle_single_message(#jsonrpc_request{method = <<"initialize">>} = Msg,
                       Req0, State) ->
    Handlers = maps:get(handlers, State, erl_mcp_server_protocol:default_handlers()),
    ServerCaps = maps:get(server_capabilities, State, undefined),
    ServerInfo = maps:get(server_info, State, undefined),
    OnClose = maps:get(on_close, State, undefined),
    SessionOpts0 = #{
        role => server,
        handlers => Handlers,
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    },
    SessionOpts = case OnClose of
        undefined -> SessionOpts0;
        Fun -> SessionOpts0#{on_close => Fun}
    end,
    case erl_mcp_server_session_manager:create_session(SessionOpts) of
        {ok, SessionId, Pid} ->
            case erl_mcp_server_session:handle_message(Pid, Msg) of
                {reply, Reply} ->
                    {ok, RespBody} = erl_mcp_protocol_jsonrpc:encode(Reply),
                    Req = cowboy_req:reply(200, #{
                        <<"content-type">> => <<"application/json">>,
                        <<"mcp-session-id">> => SessionId
                    }, RespBody, Req0),
                    {ok, Req, State};
                ok ->
                    Req = cowboy_req:reply(202, #{
                        <<"mcp-session-id">> => SessionId
                    }, <<>>, Req0),
                    {ok, Req, State}
            end;
        {error, _Reason} ->
            send_jsonrpc_error(Msg#jsonrpc_request.id, ?INTERNAL_ERROR,
                               <<"Session creation failed">>, Req0, State)
    end;
handle_single_message(#jsonrpc_request{} = Msg, Req0, State) ->
    case get_or_create_session(Req0, State) of
        {ok, Pid, Req1} ->
            case erl_mcp_server_session:handle_message(Pid, Msg) of
                {reply, Reply} ->
                    {ok, RespBody} = erl_mcp_protocol_jsonrpc:encode(Reply),
                    Req = cowboy_req:reply(200, #{
                        <<"content-type">> => <<"application/json">>
                    }, RespBody, Req1),
                    {ok, Req, State};
                ok ->
                    Req = cowboy_req:reply(202, #{}, <<>>, Req1),
                    {ok, Req, State};
                {error, _Reason} ->
                    send_jsonrpc_error(Msg#jsonrpc_request.id, ?INTERNAL_ERROR,
                                       <<"Internal error">>, Req1, State)
            end;
        {error, Req1} ->
            Req = cowboy_req:reply(404,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":\"Invalid session\"}">>, Req1),
            {ok, Req, State}
    end;
handle_single_message(_, Req0, State) ->
    send_jsonrpc_error(null, ?INVALID_REQUEST,
                       <<"Invalid request">>, Req0, State).

handle_batch(Messages, Req0, State) ->
    case get_or_create_session(Req0, State) of
        {ok, Pid, Req1} ->
            Replies = lists:filtermap(fun(Msg) ->
                IsNotification = is_record(Msg, jsonrpc_notification),
                case erl_mcp_server_session:handle_message(Pid, Msg) of
                    {reply, Reply} -> {true, Reply};
                    ok -> false;
                    {error, Reason} when not IsNotification ->
                        MsgId = case Msg of
                            #jsonrpc_request{id = I} -> I;
                            _ -> null
                        end,
                        ErrMsg = iolist_to_binary(
                            io_lib:format("~p", [Reason])),
                        ErrReply = erl_mcp_protocol_jsonrpc:error_response(
                            MsgId, ?INTERNAL_ERROR, ErrMsg),
                        {true, ErrReply};
                    {error, _} ->
                        false
                end
            end, Messages),
            case Replies of
                [] ->
                    Req = cowboy_req:reply(202, #{}, <<>>, Req1),
                    {ok, Req, State};
                _ ->
                    {ok, RespBody} = erl_mcp_protocol_jsonrpc:encode({batch, Replies}),
                    Req = cowboy_req:reply(200, #{
                        <<"content-type">> => <<"application/json">>
                    }, RespBody, Req1),
                    {ok, Req, State}
            end;
        {error, Req1} ->
            Req = cowboy_req:reply(404,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":\"Invalid session\"}">>, Req1),
            {ok, Req, State}
    end.

handle_get(Req0, State) ->
    Req = cowboy_req:reply(501,
        #{<<"content-type">> => <<"application/json">>},
        <<"{\"error\":\"SSE server push not yet implemented\"}">>,
        Req0),
    {ok, Req, State}.

handle_delete(Req0, State) ->
    SessionId = cowboy_req:header(<<"mcp-session-id">>, Req0, undefined),
    case SessionId of
        undefined ->
            Req = cowboy_req:reply(400, #{}, <<>>, Req0),
            {ok, Req, State};
        _ ->
            case erl_mcp_server_session_manager:remove_session(SessionId) of
                ok ->
                    Req = cowboy_req:reply(200, #{}, <<>>, Req0),
                    {ok, Req, State};
                {error, not_found} ->
                    Req = cowboy_req:reply(404, #{}, <<>>, Req0),
                    {ok, Req, State}
            end
    end.

%% @private
get_or_create_session(Req0, _State) ->
    SessionId = cowboy_req:header(<<"mcp-session-id">>, Req0, undefined),
    case SessionId of
        undefined ->
            {error, Req0};
        _ ->
            case erl_mcp_server_session_manager:get_session(SessionId) of
                {ok, Pid} -> {ok, Pid, Req0};
                {error, not_found} -> {error, Req0}
            end
    end.

%% @private
send_jsonrpc_error(Id, Code, Message, Req0, State) ->
    ErrResp = erl_mcp_protocol_jsonrpc:error_response(Id, Code, Message),
    {ok, RespBody} = erl_mcp_protocol_jsonrpc:encode(ErrResp),
    Req = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>
    }, RespBody, Req0),
    {ok, Req, State}.

%% @private Read the full request body, accumulating chunks.
%% Returns `{ok, Body, Req}' when the complete body has been read,
%% or `{error, too_large, Req}' when the accumulated size exceeds MaxBody.
read_full_body(Req, MaxBody) ->
    read_full_body(Req, MaxBody, <<>>).

read_full_body(Req0, MaxBody, Acc) ->
    case cowboy_req:read_body(Req0, #{length => 65536, period => 5000}) of
        {ok, Data, Req1} ->
            Total = <<Acc/binary, Data/binary>>,
            if byte_size(Total) > MaxBody -> {error, too_large, Req1};
               true -> {ok, Total, Req1}
            end;
        {more, Data, Req1} ->
            Total = <<Acc/binary, Data/binary>>,
            if byte_size(Total) > MaxBody -> {error, too_large, Req1};
               true -> read_full_body(Req1, MaxBody, Total)
            end
    end.
