-module(erl_mcp_sse_stream_tests).
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Test generators
%%--------------------------------------------------------------------

stream_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
      fun endpoint_received/1,
      fun message_received/1,
      fun partial_chunk_buffering/1,
      fun multiple_messages_queued/1,
      fun endpoint_timeout/1,
      fun stream_end_errors_waiters/1,
      fun stream_error_errors_waiters/1,
      fun default_event_is_message/1
     ]}.

%%--------------------------------------------------------------------
%% Setup / teardown
%%--------------------------------------------------------------------

setup() ->
    ok = application:ensure_started(inets),
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, cancel_request, fun(_ReqId, _Profile) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(httpc).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Start the stream with a mock httpc:request that immediately sends
%% SSE chunks to the gen_server process. The ReqId ref is captured
%% for later use.
start_stream_with_chunks(Chunks) ->
    meck:expect(httpc, request,
        fun(get, {_Url, _Headers}, _HttpOpts, _Opts, _Profile) ->
            ReqId = make_ref(),
            Self = self(),
            Self ! {http, {ReqId, stream_start,
                           [{"content-type", "text/event-stream"}]}},
            lists:foreach(fun(Chunk) ->
                Self ! {http, {ReqId, stream, Chunk}}
            end, Chunks),
            {ok, ReqId}
        end),
    Config = #{url => "http://localhost:9999/sse",
               headers => [],
               profile => default},
    erl_mcp_sse_stream:start_link(Config).

%% Start stream that sends chunks asynchronously from a spawned process
%% after a short delay.
start_stream_delayed_chunks(DelayedChunks) ->
    meck:expect(httpc, request,
        fun(get, {_Url, _Headers}, _HttpOpts, _Opts, _Profile) ->
            ReqId = make_ref(),
            Self = self(),
            Self ! {http, {ReqId, stream_start,
                           [{"content-type", "text/event-stream"}]}},
            spawn(fun() ->
                lists:foreach(fun({Delay, Chunk}) ->
                    timer:sleep(Delay),
                    Self ! {http, {ReqId, stream, Chunk}}
                end, DelayedChunks)
            end),
            {ok, ReqId}
        end),
    Config = #{url => "http://localhost:9999/sse",
               headers => [],
               profile => default},
    erl_mcp_sse_stream:start_link(Config).

%% Start stream that sends stream_end after chunks
start_stream_with_end(Chunks) ->
    meck:expect(httpc, request,
        fun(get, {_Url, _Headers}, _HttpOpts, _Opts, _Profile) ->
            ReqId = make_ref(),
            Self = self(),
            Self ! {http, {ReqId, stream_start,
                           [{"content-type", "text/event-stream"}]}},
            lists:foreach(fun(Chunk) ->
                Self ! {http, {ReqId, stream, Chunk}}
            end, Chunks),
            Self ! {http, {ReqId, stream_end, []}},
            {ok, ReqId}
        end),
    Config = #{url => "http://localhost:9999/sse",
               headers => [],
               profile => default},
    erl_mcp_sse_stream:start_link(Config).

%% Start stream that sends an error after chunks
start_stream_with_error(Chunks, ErrorReason) ->
    meck:expect(httpc, request,
        fun(get, {_Url, _Headers}, _HttpOpts, _Opts, _Profile) ->
            ReqId = make_ref(),
            Self = self(),
            Self ! {http, {ReqId, stream_start,
                           [{"content-type", "text/event-stream"}]}},
            lists:foreach(fun(Chunk) ->
                Self ! {http, {ReqId, stream, Chunk}}
            end, Chunks),
            Self ! {http, {ReqId, {error, ErrorReason}}},
            {ok, ReqId}
        end),
    Config = #{url => "http://localhost:9999/sse",
               headers => [],
               profile => default},
    erl_mcp_sse_stream:start_link(Config).

%% Start stream that only sends stream_start (no data at all)
start_stream_no_data() ->
    meck:expect(httpc, request,
        fun(get, {_Url, _Headers}, _HttpOpts, _Opts, _Profile) ->
            ReqId = make_ref(),
            Self = self(),
            Self ! {http, {ReqId, stream_start,
                           [{"content-type", "text/event-stream"}]}},
            {ok, ReqId}
        end),
    Config = #{url => "http://localhost:9999/sse",
               headers => [],
               profile => default},
    erl_mcp_sse_stream:start_link(Config).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

endpoint_received(_) ->
    fun() ->
        {ok, Pid} = start_stream_with_chunks(
            [<<"event: endpoint\ndata: /message?sid=abc\n\n">>]),
        {ok, Url} = erl_mcp_sse_stream:await_endpoint(Pid, 5000),
        ?assertEqual(<<"/message?sid=abc">>, Url),
        erl_mcp_sse_stream:stop(Pid)
    end.

message_received(_) ->
    fun() ->
        {ok, Pid} = start_stream_with_chunks(
            [<<"event: endpoint\ndata: /message\n\n">>,
             <<"event: message\ndata: {\"jsonrpc\":\"2.0\"}\n\n">>]),
        {ok, _Url} = erl_mcp_sse_stream:await_endpoint(Pid, 5000),
        {ok, Data} = erl_mcp_sse_stream:await_message(Pid, 5000),
        ?assertEqual(<<"{\"jsonrpc\":\"2.0\"}">>, Data),
        erl_mcp_sse_stream:stop(Pid)
    end.

partial_chunk_buffering(_) ->
    fun() ->
        %% Endpoint event split across two chunks
        {ok, Pid} = start_stream_delayed_chunks(
            [{0, <<"event: endpoint\n">>},
             {20, <<"data: /msg\n\n">>}]),
        {ok, Url} = erl_mcp_sse_stream:await_endpoint(Pid, 5000),
        ?assertEqual(<<"/msg">>, Url),
        erl_mcp_sse_stream:stop(Pid)
    end.

multiple_messages_queued(_) ->
    fun() ->
        {ok, Pid} = start_stream_with_chunks(
            [<<"event: endpoint\ndata: /ep\n\n">>,
             <<"event: message\ndata: msg1\n\nevent: message\ndata: msg2\n\n">>]),
        {ok, _} = erl_mcp_sse_stream:await_endpoint(Pid, 5000),
        {ok, D1} = erl_mcp_sse_stream:await_message(Pid, 5000),
        {ok, D2} = erl_mcp_sse_stream:await_message(Pid, 5000),
        ?assertEqual(<<"msg1">>, D1),
        ?assertEqual(<<"msg2">>, D2),
        erl_mcp_sse_stream:stop(Pid)
    end.

endpoint_timeout(_) ->
    fun() ->
        %% No endpoint event sent
        {ok, Pid} = start_stream_no_data(),
        Result = erl_mcp_sse_stream:await_endpoint(Pid, 100),
        ?assertEqual({error, timeout}, Result),
        erl_mcp_sse_stream:stop(Pid)
    end.

stream_end_errors_waiters(_) ->
    fun() ->
        {ok, Pid} = start_stream_with_end([]),
        %% Give the gen_server time to process stream_end
        timer:sleep(50),
        Result = erl_mcp_sse_stream:await_endpoint(Pid, 1000),
        ?assertMatch({error, _}, Result),
        erl_mcp_sse_stream:stop(Pid)
    end.

stream_error_errors_waiters(_) ->
    fun() ->
        {ok, Pid} = start_stream_with_error([], econnrefused),
        %% Give the gen_server time to process the error
        timer:sleep(50),
        Result = erl_mcp_sse_stream:await_endpoint(Pid, 1000),
        ?assertMatch({error, _}, Result),
        erl_mcp_sse_stream:stop(Pid)
    end.

default_event_is_message(_) ->
    fun() ->
        %% Events without explicit event type should be treated as messages
        {ok, Pid} = start_stream_with_chunks(
            [<<"event: endpoint\ndata: /ep\n\n">>,
             <<"data: default_msg\n\n">>]),
        {ok, _} = erl_mcp_sse_stream:await_endpoint(Pid, 5000),
        {ok, Data} = erl_mcp_sse_stream:await_message(Pid, 5000),
        ?assertEqual(<<"default_msg">>, Data),
        erl_mcp_sse_stream:stop(Pid)
    end.
