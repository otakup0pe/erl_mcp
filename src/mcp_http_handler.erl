-module(mcp_http_handler).

%% Cowboy handler for MCP streamable HTTP transport.
%% Handles POST (JSON-RPC dispatch) and GET (SSE stream).
%% Manages Mcp-Session-Id header.

-include("mcp.hrl").

-export([init/2]).

%%--------------------------------------------------------------------
%% Cowboy handler
%%--------------------------------------------------------------------

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

%%--------------------------------------------------------------------
%% POST - JSON-RPC dispatch
%%--------------------------------------------------------------------

handle_post(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case mcp_jsonrpc:decode(Body) of
        {ok, {batch, Messages}} ->
            handle_batch(Messages, Req1, State);
        {ok, Message} ->
            handle_single_message(Message, Req1, State);
        {error, _Reason} ->
            send_jsonrpc_error(null, ?PARSE_ERROR,
                               <<"Parse error">>, Req1, State)
    end.

handle_single_message(#jsonrpc_notification{} = Notif, Req0, State) ->
    %% Notifications get 202 Accepted, no body
    SessionPid = get_or_create_session(Req0, State),
    case SessionPid of
        {ok, Pid, Req1} ->
            mcp_session:handle_message(Pid, Notif),
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
    %% Initialize creates a new session
    Handlers = maps:get(handlers, State, mcp_protocol:default_handlers()),
    ServerCaps = maps:get(server_capabilities, State, undefined),
    ServerInfo = maps:get(server_info, State, undefined),
    SessionOpts = #{
        role => server,
        handlers => Handlers,
        server_capabilities => ServerCaps,
        server_info => ServerInfo
    },
    case mcp_session_manager:create_session(SessionOpts) of
        {ok, SessionId, Pid} ->
            case mcp_session:handle_message(Pid, Msg) of
                {reply, Reply} ->
                    {ok, RespBody} = mcp_jsonrpc:encode(Reply),
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
            case mcp_session:handle_message(Pid, Msg) of
                {reply, Reply} ->
                    {ok, RespBody} = mcp_jsonrpc:encode(Reply),
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
                case mcp_session:handle_message(Pid, Msg) of
                    {reply, Reply} -> {true, Reply};
                    ok -> false;
                    {error, _} -> false
                end
            end, Messages),
            case Replies of
                [] ->
                    Req = cowboy_req:reply(202, #{}, <<>>, Req1),
                    {ok, Req, State};
                _ ->
                    {ok, RespBody} = mcp_jsonrpc:encode({batch, Replies}),
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

%%--------------------------------------------------------------------
%% GET - SSE stream for server-initiated messages
%%--------------------------------------------------------------------

handle_get(Req0, State) ->
    case get_or_create_session(Req0, State) of
        {ok, _Pid, Req1} ->
            Req = cowboy_req:stream_reply(200, #{
                <<"content-type">> => <<"text/event-stream">>,
                <<"cache-control">> => <<"no-cache">>,
                <<"connection">> => <<"keep-alive">>
            }, Req1),
            %% TODO: hold connection open and stream events
            %% For now, just open the stream
            {ok, Req, State};
        {error, Req1} ->
            Req = cowboy_req:reply(404, #{}, <<>>, Req1),
            {ok, Req, State}
    end.

%%--------------------------------------------------------------------
%% DELETE - End session
%%--------------------------------------------------------------------

handle_delete(Req0, State) ->
    SessionId = cowboy_req:header(<<"mcp-session-id">>, Req0, undefined),
    case SessionId of
        undefined ->
            Req = cowboy_req:reply(400, #{}, <<>>, Req0),
            {ok, Req, State};
        _ ->
            case mcp_session_manager:remove_session(SessionId) of
                ok ->
                    Req = cowboy_req:reply(200, #{}, <<>>, Req0),
                    {ok, Req, State};
                {error, not_found} ->
                    Req = cowboy_req:reply(404, #{}, <<>>, Req0),
                    {ok, Req, State}
            end
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

get_or_create_session(Req0, _State) ->
    SessionId = cowboy_req:header(<<"mcp-session-id">>, Req0, undefined),
    case SessionId of
        undefined ->
            {error, Req0};
        _ ->
            case mcp_session_manager:get_session(SessionId) of
                {ok, Pid} -> {ok, Pid, Req0};
                {error, not_found} -> {error, Req0}
            end
    end.

send_jsonrpc_error(Id, Code, Message, Req0, State) ->
    ErrResp = mcp_jsonrpc:error_response(Id, Code, Message),
    {ok, RespBody} = mcp_jsonrpc:encode(ErrResp),
    Req = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>
    }, RespBody, Req0),
    {ok, Req, State}.
