-module(mock_client_transport).

%% In-process mock transport implementing erl_mcp_transport for
%% unit tests of erl_mcp_client. Pre-queued responses are returned
%% in FIFO order against outbound request/notify calls.

-behaviour(erl_mcp_transport).
-behaviour(gen_server).

-export([connect/1, request/3, notify/2, close/1, update_auth/2]).

-export([new/0, queue_response/2, queue_error/2,
         sent_messages/1, stop/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    responses = [] :: [{ok, binary()} | {error, term()} | no_response],
    sent = [] :: [binary()]
}).

%%--------------------------------------------------------------------
%% Test-side API
%%--------------------------------------------------------------------

new() ->
    {ok, Pid} = gen_server:start_link(?MODULE, [], []),
    Pid.

queue_response(Pid, Body) when is_binary(Body) ->
    gen_server:call(Pid, {queue, {ok, Body}});
queue_response(Pid, no_response) ->
    gen_server:call(Pid, {queue, no_response}).

queue_error(Pid, Reason) ->
    gen_server:call(Pid, {queue, {error, Reason}}).

sent_messages(Pid) ->
    gen_server:call(Pid, sent_messages).

stop(Pid) ->
    gen_server:stop(Pid).

%%--------------------------------------------------------------------
%% erl_mcp_transport callbacks
%%--------------------------------------------------------------------

connect(Config) ->
    Pid = maps:get(mock_pid, Config),
    {ok, Pid}.

request(Pid, Message, _Timeout) ->
    case gen_server:call(Pid, {send, iolist_to_binary(Message)}) of
        {ok, Body} -> {ok, Body, Pid};
        no_response -> {error, no_response_queued, Pid};
        {error, Reason} -> {error, Reason, Pid}
    end.

notify(Pid, Message) ->
    case gen_server:call(Pid, {send, iolist_to_binary(Message)}) of
        {ok, _Body} -> {ok, Pid};
        no_response -> {ok, Pid};
        {error, Reason} -> {error, Reason, Pid}
    end.

close(_Pid) ->
    ok.

update_auth(Pid, _Auth) ->
    {ok, Pid}.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call({queue, R}, _From, State) ->
    {reply, ok, State#state{responses = State#state.responses ++ [R]}};
handle_call({send, Msg}, _From, State) ->
    Sent = State#state.sent ++ [Msg],
    case State#state.responses of
        [] ->
            {reply, {error, no_response_queued},
             State#state{sent = Sent}};
        [R | Rest] ->
            {reply, R, State#state{sent = Sent, responses = Rest}}
    end;
handle_call(sent_messages, _From, State) ->
    {reply, State#state.sent, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
