-module(mock_transport).

%% In-process mock transport for CT tests.
%% Captures sent messages and allows injecting received messages.

-behaviour(gen_server).

-export([start_link/0, stop/1]).
-export([get_sent/1, inject/2, clear/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    sent = [] :: [binary()],
    inbox = [] :: [binary()]
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link(?MODULE, [], []).

stop(Pid) ->
    gen_server:stop(Pid).

%% Get all messages sent by the session (newest first).
-spec get_sent(pid()) -> [binary()].
get_sent(Pid) ->
    gen_server:call(Pid, get_sent).

%% Inject a message as if received from the remote side.
-spec inject(pid(), binary()) -> ok.
inject(Pid, Message) ->
    gen_server:cast(Pid, {inject, Message}).

%% Clear sent message buffer.
-spec clear(pid()) -> ok.
clear(Pid) ->
    gen_server:call(Pid, clear).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call(get_sent, _From, State) ->
    {reply, State#state.sent, State};

handle_call(clear, _From, State) ->
    {reply, ok, State#state{sent = []}};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({inject, _Message}, State) ->
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({mcp_send, Bin}, State) ->
    {noreply, State#state{sent = [Bin | State#state.sent]}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
