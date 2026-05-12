-module(erl_mcp_transport_local_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erl_mcp.hrl").
-include("erl_mcp_client.hrl").

%%--------------------------------------------------------------------
%% Test generators
%%--------------------------------------------------------------------

connect_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun connect_with_pid/1,
      fun connect_with_name/1,
      fun connect_missing_config/1,
      fun connect_dead_pid/1
     ]}.

request_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun request_round_trip/1,
      fun request_server_down/1
     ]}.

notify_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun notify_round_trip/1
     ]}.

close_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun close_demonitors/1
     ]}.

%%--------------------------------------------------------------------
%% Setup / teardown
%%--------------------------------------------------------------------

setup() ->
    stop_if_alive(erl_mcp_server_tool_registry),
    stop_if_alive(erl_mcp_server_session_manager),
    {ok, RegPid} = erl_mcp_server_tool_registry:start_link(),
    unlink(RegPid),
    EchoTool = #tool{
        name = <<"echo">>,
        description = <<"Echoes input">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    EchoHandler = fun(Args, _Ctx) ->
        Msg = maps:get(<<"text">>, Args, <<"no text">>),
        {ok, [erl_mcp_protocol_content:text(Msg)]}
    end,
    ok = erl_mcp_server_tool_registry:register_tool(EchoTool, EchoHandler),
    {ok, ServerPid} = erl_mcp_server_local:start_link(#{
        handlers => erl_mcp_server_protocol:default_handlers(),
        server_capabilities => erl_mcp_protocol_capability:server_capabilities(#{
            tools => #{list_changed => true}
        }),
        server_info => #implementation{
            name = <<"test-local-server">>,
            version = <<"0.1.0">>
        }
    }),
    #{server_pid => ServerPid, reg_pid => RegPid}.

teardown(#{server_pid := ServerPid, reg_pid := RegPid}) ->
    catch gen_server:stop(ServerPid),
    catch gen_server:stop(RegPid).

%%--------------------------------------------------------------------
%% Connect tests
%%--------------------------------------------------------------------

connect_with_pid(#{server_pid := ServerPid}) ->
    fun() ->
        {ok, Handle} = erl_mcp_transport_local:connect(
                          #{server_pid => ServerPid}),
        ?assertMatch({handle, _, _}, Handle),
        ok = erl_mcp_transport_local:close(Handle)
    end.

connect_with_name(#{server_pid := ServerPid}) ->
    fun() ->
        register(test_local_server, ServerPid),
        {ok, Handle} = erl_mcp_transport_local:connect(
                          #{server_pid => test_local_server}),
        ok = erl_mcp_transport_local:close(Handle),
        unregister(test_local_server)
    end.

connect_missing_config(_Ctx) ->
    fun() ->
        ?assertEqual({error, {missing_config, server_pid}},
                     erl_mcp_transport_local:connect(#{}))
    end.

connect_dead_pid(_Ctx) ->
    fun() ->
        DeadPid = spawn(fun() -> ok end),
        timer:sleep(50),
        ?assertEqual({error, server_down},
                     erl_mcp_transport_local:connect(
                       #{server_pid => DeadPid}))
    end.

%%--------------------------------------------------------------------
%% Request tests
%%--------------------------------------------------------------------

request_round_trip(#{server_pid := ServerPid}) ->
    fun() ->
        {ok, Handle} = erl_mcp_transport_local:connect(
                          #{server_pid => ServerPid}),
        %% Send an initialize request
        InitReq = erl_mcp_protocol_jsonrpc:request(1, <<"initialize">>, #{
            <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{<<"name">> => <<"test">>,
                                  <<"version">> => <<"0.1">>}
        }),
        {ok, InitBody} = erl_mcp_protocol_jsonrpc:encode(InitReq),
        {ok, RespBody, Handle1} = erl_mcp_transport_local:request(
                                    Handle, InitBody, 5000),
        {ok, Resp} = erl_mcp_protocol_jsonrpc:decode(RespBody),
        ?assertMatch(#jsonrpc_response{id = 1}, Resp),
        Result = Resp#jsonrpc_response.result,
        ?assert(is_map(maps:get(<<"capabilities">>, Result))),
        ?assert(is_map(maps:get(<<"serverInfo">>, Result))),
        ok = erl_mcp_transport_local:close(Handle1)
    end.

request_server_down(_Ctx) ->
    fun() ->
        {ok, TmpServer} = erl_mcp_server_local:start_link(#{}),
        {ok, Handle} = erl_mcp_transport_local:connect(
                          #{server_pid => TmpServer}),
        gen_server:stop(TmpServer),
        timer:sleep(50),
        Req = erl_mcp_protocol_jsonrpc:request(1, <<"ping">>, #{}),
        {ok, Body} = erl_mcp_protocol_jsonrpc:encode(Req),
        {error, server_down, _H} = erl_mcp_transport_local:request(
                                     Handle, Body, 1000)
    end.

%%--------------------------------------------------------------------
%% Notify tests
%%--------------------------------------------------------------------

notify_round_trip(#{server_pid := ServerPid}) ->
    fun() ->
        {ok, Handle} = erl_mcp_transport_local:connect(
                          #{server_pid => ServerPid}),
        Notif = erl_mcp_protocol_jsonrpc:notification(
                  <<"notifications/initialized">>, #{}),
        {ok, NotifBody} = erl_mcp_protocol_jsonrpc:encode(Notif),
        {ok, Handle1} = erl_mcp_transport_local:notify(Handle, NotifBody),
        ?assertMatch({handle, _, _}, Handle1),
        ok = erl_mcp_transport_local:close(Handle1)
    end.

%%--------------------------------------------------------------------
%% Close tests
%%--------------------------------------------------------------------

close_demonitors(#{server_pid := ServerPid}) ->
    fun() ->
        {ok, Handle} = erl_mcp_transport_local:connect(
                          #{server_pid => ServerPid}),
        ok = erl_mcp_transport_local:close(Handle),
        %% Monitor ref should have been flushed -- no DOWN message
        receive
            {'DOWN', _, process, ServerPid, _} ->
                ?assert(false)
        after 100 ->
            ok
        end
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

stop_if_alive(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 5000)
    end.
