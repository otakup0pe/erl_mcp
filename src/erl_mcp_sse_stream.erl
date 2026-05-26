-module(erl_mcp_sse_stream).
%% @private
%% Internal module -- SSE stream helper for the legacy SSE transport.
%% Manages a persistent GET connection with httpc async streaming,
%% buffering and decoding SSE events.

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, await_endpoint/2, await_message/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2, terminate/2]).

-record(state, {
    config :: map(),
    request_id :: reference() | undefined,
    buffer = <<>> :: binary(),
    endpoint_url :: binary() | undefined,
    endpoint_waiters = [] :: [{gen_server:from(), reference()}],
    message_queue :: queue:queue(binary()),
    message_waiters = [] :: [{gen_server:from(), reference()}],
    stream_error :: term() | undefined
}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec await_endpoint(pid(), timeout()) -> {ok, binary()} | {error, term()}.
await_endpoint(Pid, Timeout) ->
    gen_server:call(Pid, {await_endpoint, Timeout}, infinity).

-spec await_message(pid(), timeout()) -> {ok, binary()} | {error, term()}.
await_message(Pid, Timeout) ->
    gen_server:call(Pid, {await_message, Timeout}, infinity).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

init(Config) ->
    {ok, #state{config = Config,
                message_queue = queue:new()},
     {continue, connect}}.

handle_continue(connect, #state{config = Config} = State) ->
    Url = maps:get(url, Config),
    Headers = maps:get(headers, Config, []),
    Profile = maps:get(profile, Config, default),
    HttpOpts = [{timeout, infinity}],
    Opts = [{sync, false}, {stream, self}],
    case httpc:request(get, {Url, Headers}, HttpOpts, Opts, Profile) of
        {ok, RequestId} ->
            {noreply, State#state{request_id = RequestId}};
        {error, Reason} ->
            {stop, {connect_failed, Reason}, State}
    end.

handle_call({await_endpoint, _Timeout}, _From,
            #state{endpoint_url = Url} = State)
  when Url =/= undefined ->
    {reply, {ok, Url}, State};
handle_call({await_endpoint, _Timeout}, _From,
            #state{stream_error = Err} = State)
  when Err =/= undefined ->
    {reply, {error, Err}, State};
handle_call({await_endpoint, Timeout}, From, State) ->
    TRef = erlang:send_after(Timeout, self(), {endpoint_timeout, From}),
    Waiters = [{From, TRef} | State#state.endpoint_waiters],
    {noreply, State#state{endpoint_waiters = Waiters}};

handle_call({await_message, _Timeout}, _From,
            #state{stream_error = Err} = State)
  when Err =/= undefined ->
    case queue:out(State#state.message_queue) of
        {{value, Msg}, Q2} ->
            {reply, {ok, Msg}, State#state{message_queue = Q2}};
        {empty, _} ->
            {reply, {error, Err}, State}
    end;
handle_call({await_message, Timeout}, From, State) ->
    case queue:out(State#state.message_queue) of
        {{value, Msg}, Q2} ->
            {reply, {ok, Msg}, State#state{message_queue = Q2}};
        {empty, _} ->
            TRef = erlang:send_after(Timeout, self(),
                                     {message_timeout, From}),
            Waiters = [{From, TRef} | State#state.message_waiters],
            {noreply, State#state{message_waiters = Waiters}}
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% httpc async streaming messages
handle_info({http, {ReqId, stream_start, _Headers}},
            #state{request_id = ReqId} = State) ->
    ?LOG_DEBUG("SSE stream started"),
    {noreply, State};

handle_info({http, {ReqId, stream, Chunk}},
            #state{request_id = ReqId} = State) ->
    ?LOG_DEBUG("SSE chunk (~B bytes)", [byte_size(Chunk)]),
    Buffer = <<(State#state.buffer)/binary, Chunk/binary>>,
    {Events, Remainder} = process_buffer(Buffer),
    State1 = State#state{buffer = Remainder},
    State2 = handle_events(Events, State1),
    {noreply, State2};

handle_info({http, {ReqId, stream_end, _Headers}},
            #state{request_id = ReqId} = State) ->
    ?LOG_DEBUG("SSE stream ended"),
    State1 = State#state{stream_error = stream_closed,
                         request_id = undefined},
    State2 = error_all_waiters(stream_closed, State1),
    {noreply, State2};

handle_info({http, {ReqId, {{_Proto, Status, _Phrase}, Headers, Body}}},
            #state{request_id = ReqId} = State) ->
    %% Non-streamed response (e.g. redirect, error page)
    ?LOG_ERROR("SSE got non-streamed HTTP ~B, headers: ~p, body: ~s",
               [Status, Headers, truncate_for_log(Body, 500)]),
    Err = {http_status, Status, Body},
    State1 = State#state{stream_error = Err, request_id = undefined},
    State2 = error_all_waiters(Err, State1),
    {noreply, State2};

handle_info({http, {ReqId, {error, Reason}}},
            #state{request_id = ReqId} = State) ->
    ?LOG_ERROR("SSE stream error: ~p", [Reason]),
    State1 = State#state{stream_error = {stream_error, Reason},
                         request_id = undefined},
    State2 = error_all_waiters({stream_error, Reason}, State1),
    {noreply, State2};

handle_info({endpoint_timeout, From}, State) ->
    case lists:keytake(From, 1, State#state.endpoint_waiters) of
        {value, {From, TRef}, Rest} ->
            erlang:cancel_timer(TRef),
            gen_server:reply(From, {error, timeout}),
            {noreply, State#state{endpoint_waiters = Rest}};
        false ->
            %% Already replied
            {noreply, State}
    end;

handle_info({message_timeout, From}, State) ->
    case lists:keytake(From, 1, State#state.message_waiters) of
        {value, {From, TRef}, Rest} ->
            erlang:cancel_timer(TRef),
            gen_server:reply(From, {error, timeout}),
            {noreply, State#state{message_waiters = Rest}};
        false ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{request_id = undefined}) ->
    ok;
terminate(_Reason, #state{request_id = ReqId, config = Config}) ->
    Profile = maps:get(profile, Config, default),
    httpc:cancel_request(ReqId, Profile),
    ok.

-spec process_buffer(binary()) -> {[map()], binary()}.
process_buffer(Buffer) ->
    Parts = binary:split(Buffer, <<"\n\n">>, [global]),
    case Parts of
        [_SinglePart] ->
            %% No complete event yet
            {[], Buffer};
        _ ->
            %% Everything except the last part contains complete events
            {CompleteParts, [Remainder]} =
                lists:split(length(Parts) - 1, Parts),
            CompleteData = iolist_to_binary(
                lists:join(<<"\n\n">>, CompleteParts)),
            Events = erl_mcp_protocol_sse:decode_events(CompleteData),
            {Events, Remainder}
    end.

-spec handle_events([map()], #state{}) -> #state{}.
handle_events([], State) ->
    State;
handle_events([Event | Rest], State) ->
    State1 = handle_event(Event, State),
    handle_events(Rest, State1).

-spec handle_event(map(), #state{}) -> #state{}.
handle_event(#{event := <<"endpoint">>, data := Url}, State) ->
    ?LOG_DEBUG("SSE endpoint received: ~s", [Url]),
    State1 = State#state{endpoint_url = Url},
    reply_to_endpoint_waiters(State1);
handle_event(#{event := <<"message">>, data := Data}, State) ->
    deliver_or_queue_message(Data, State);
handle_event(#{data := Data}, State) ->
    %% Events without an explicit event type default to "message"
    deliver_or_queue_message(Data, State);
handle_event(_Event, State) ->
    State.

-spec reply_to_endpoint_waiters(#state{}) -> #state{}.
reply_to_endpoint_waiters(#state{endpoint_url = Url,
                                 endpoint_waiters = Waiters} = State) ->
    lists:foreach(fun({From, TRef}) ->
        erlang:cancel_timer(TRef),
        gen_server:reply(From, {ok, Url})
    end, Waiters),
    State#state{endpoint_waiters = []}.

-spec deliver_or_queue_message(binary(), #state{}) -> #state{}.
deliver_or_queue_message(Data, #state{message_waiters = []} = State) ->
    Q = queue:in(Data, State#state.message_queue),
    State#state{message_queue = Q};
deliver_or_queue_message(Data, #state{message_waiters = Waiters} = State) ->
    [{From, TRef} | Rest] = Waiters,
    erlang:cancel_timer(TRef),
    gen_server:reply(From, {ok, Data}),
    State#state{message_waiters = Rest}.

-spec truncate_for_log(binary() | list(), pos_integer()) -> binary().
truncate_for_log(Data, Max) when is_list(Data) ->
    truncate_for_log(list_to_binary(Data), Max);
truncate_for_log(Data, Max) when byte_size(Data) > Max ->
    <<Head:Max/binary, _/binary>> = Data,
    <<Head/binary, "...">>;
truncate_for_log(Data, _Max) ->
    Data.

-spec error_all_waiters(term(), #state{}) -> #state{}.
error_all_waiters(Reason, State) ->
    lists:foreach(fun({From, TRef}) ->
        erlang:cancel_timer(TRef),
        gen_server:reply(From, {error, Reason})
    end, State#state.endpoint_waiters),
    lists:foreach(fun({From, TRef}) ->
        erlang:cancel_timer(TRef),
        gen_server:reply(From, {error, Reason})
    end, State#state.message_waiters),
    State#state{endpoint_waiters = [], message_waiters = []}.
