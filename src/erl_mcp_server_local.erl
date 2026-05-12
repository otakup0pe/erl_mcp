-module(erl_mcp_server_local).

%% @doc MCP server endpoint for the Erlang-message-passing transport.
%%
%% Wraps an {@link erl_mcp_server_session} and accepts inbound
%% JSON-RPC messages via `gen_server:call' and `gen_server:cast',
%% so an {@link erl_mcp_transport_local} client -- in the same BEAM
%% OR on another node within the cluster -- can connect without
%% HTTP.  Same JSON-RPC envelope, same protocol semantics, same
%% handler surface -- only the transport differs.
%%
%% For cross-node use, register the server under a name and pass
%% the `{Name, Node}' form as the client's `server_pid' config.
%%
%% Example:
%% ```
%% application:ensure_all_started(erl_mcp),
%% Tool = erl_mcp_server_tool:new(<<"echo">>, <<"Echoes">>,
%%     #{<<"type">> => <<"object">>}),
%% ok = erl_mcp_server_tool_registry:register_tool(Tool,
%%     fun(#{<<"text">> := T}, _Ctx) ->
%%         {ok, [erl_mcp_protocol_content:text(T)]}
%%     end),
%% {ok, Server} = erl_mcp_server_local:start_link(#{
%%     handlers => erl_mcp_server_protocol:default_handlers(),
%%     server_info => #implementation{name = <<"demo">>,
%%                                    version = <<"0.1.0">>}
%% }),
%% {ok, Client} = erl_mcp_client:start_link(#{
%%     transport => erl_mcp_transport_local,
%%     server_pid => Server
%% }).
%% '''

-behaviour(gen_server).

-include("erl_mcp.hrl").

-export([start_link/1, start_link/2, stop/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    session :: undefined | pid(),
    session_opts :: map()
}).

%% @doc Start an unregistered local MCP server.
%%
%% `Opts' may include `handlers', `server_capabilities', and
%% `server_info'.  A fresh {@link erl_mcp_server_session} is created
%% lazily on the first `initialize' request.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% @doc Start a named local MCP server.
-spec start_link(term(), map()) -> {ok, pid()} | {error, term()}.
start_link(Name, Opts) ->
    gen_server:start_link(Name, ?MODULE, Opts, []).

%% @doc Stop the local server and its session.
-spec stop(pid() | atom()) -> ok.
stop(Ref) ->
    gen_server:stop(Ref).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init(Opts) ->
    Handlers = maps:get(handlers, Opts,
                        erl_mcp_server_protocol:default_handlers()),
    ServerCaps = maps:get(server_capabilities, Opts, undefined),
    ServerInfo = maps:get(server_info, Opts, undefined),
    OnClose = maps:get(on_close, Opts, undefined),
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
    {ok, #state{session_opts = SessionOpts}}.

handle_call({erl_mcp_local_request, Body}, _From, State) ->
    State1 = ensure_session(State),
    case State1#state.session of
        undefined ->
            {reply, {error, session_creation_failed}, State1};
        Session ->
            case erl_mcp_protocol_jsonrpc:decode(Body) of
                {ok, Message} ->
                    Result = erl_mcp_server_session:handle_message(
                               Session, Message),
                    case Result of
                        {reply, Reply} ->
                            case erl_mcp_protocol_jsonrpc:encode(Reply) of
                                {ok, RespBody} ->
                                    {reply, {ok, RespBody}, State1};
                                {error, EncErr} ->
                                    {reply, {error, {encode_error, EncErr}},
                                     State1}
                            end;
                        ok ->
                            {reply, {ok, <<"{}">>}, State1};
                        {error, Reason} ->
                            {reply, {error, Reason}, State1}
                    end;
                {error, DecErr} ->
                    ErrResp = erl_mcp_protocol_jsonrpc:error_response(
                                null, ?PARSE_ERROR, <<"Parse error">>),
                    case erl_mcp_protocol_jsonrpc:encode(ErrResp) of
                        {ok, ErrBody} ->
                            {reply, {ok, ErrBody}, State1};
                        _ ->
                            {reply, {error, {decode_error, DecErr}}, State1}
                    end
            end
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({erl_mcp_local_notify, Body}, State) ->
    State1 = ensure_session(State),
    case State1#state.session of
        undefined ->
            {noreply, State1};
        Session ->
            case erl_mcp_protocol_jsonrpc:decode(Body) of
                {ok, Message} ->
                    erl_mcp_server_session:handle_message(Session, Message),
                    ok;
                {error, _} ->
                    ok
            end,
            {noreply, State1}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{session = Pid} = State) ->
    {noreply, State#state{session = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{session = undefined}) ->
    ok;
terminate(_Reason, #state{session = Pid}) ->
    catch gen_server:stop(Pid, shutdown, 5000),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

ensure_session(#state{session = undefined, session_opts = Opts} = State) ->
    case erl_mcp_server_session:start_link(Opts) of
        {ok, Pid} ->
            unlink(Pid),
            monitor(process, Pid),
            State#state{session = Pid};
        {error, _} ->
            State
    end;
ensure_session(State) ->
    State.
