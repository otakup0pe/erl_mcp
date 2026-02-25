-module(mcp_capability).

%% MCP capability negotiation.

-include("mcp.hrl").

-export([client_capabilities/1, server_capabilities/1]).
-export([client_to_map/1, server_to_map/1]).
-export([parse_client/1, parse_server/1]).
-export([negotiate/2]).

%%--------------------------------------------------------------------
%% Builders
%%--------------------------------------------------------------------

-spec client_capabilities(map()) -> #client_capabilities{}.
client_capabilities(Opts) ->
    #client_capabilities{
        experimental = maps:get(experimental, Opts, #{}),
        roots = maps:get(roots, Opts, undefined),
        sampling = maps:get(sampling, Opts, undefined)
    }.

-spec server_capabilities(map()) -> #server_capabilities{}.
server_capabilities(Opts) ->
    #server_capabilities{
        experimental = maps:get(experimental, Opts, #{}),
        logging = maps:get(logging, Opts, undefined),
        completions = maps:get(completions, Opts, undefined),
        prompts = maps:get(prompts, Opts, undefined),
        resources = maps:get(resources, Opts, undefined),
        tools = maps:get(tools, Opts, undefined)
    }.

%%--------------------------------------------------------------------
%% Serialization
%%--------------------------------------------------------------------

-spec client_to_map(#client_capabilities{}) -> map().
client_to_map(#client_capabilities{} = C) ->
    Base = #{},
    M1 = maybe_put(<<"experimental">>, C#client_capabilities.experimental, Base),
    M2 = maybe_put(<<"roots">>, C#client_capabilities.roots, M1),
    maybe_put(<<"sampling">>, C#client_capabilities.sampling, M2).

-spec server_to_map(#server_capabilities{}) -> map().
server_to_map(#server_capabilities{} = S) ->
    Base = #{},
    M1 = maybe_put(<<"experimental">>, S#server_capabilities.experimental, Base),
    M2 = maybe_put(<<"logging">>, S#server_capabilities.logging, M1),
    M3 = maybe_put(<<"completions">>, S#server_capabilities.completions, M2),
    M4 = maybe_put(<<"prompts">>, S#server_capabilities.prompts, M3),
    M5 = maybe_put(<<"resources">>, S#server_capabilities.resources, M4),
    maybe_put(<<"tools">>, S#server_capabilities.tools, M5).

%%--------------------------------------------------------------------
%% Parsing from wire format
%%--------------------------------------------------------------------

-spec parse_client(map()) -> #client_capabilities{}.
parse_client(Map) when is_map(Map) ->
    #client_capabilities{
        experimental = maps:get(<<"experimental">>, Map, #{}),
        roots = maps:get(<<"roots">>, Map, undefined),
        sampling = maps:get(<<"sampling">>, Map, undefined)
    }.

-spec parse_server(map()) -> #server_capabilities{}.
parse_server(Map) when is_map(Map) ->
    #server_capabilities{
        experimental = maps:get(<<"experimental">>, Map, #{}),
        logging = maps:get(<<"logging">>, Map, undefined),
        completions = maps:get(<<"completions">>, Map, undefined),
        prompts = maps:get(<<"prompts">>, Map, undefined),
        resources = maps:get(<<"resources">>, Map, undefined),
        tools = maps:get(<<"tools">>, Map, undefined)
    }.

%%--------------------------------------------------------------------
%% Negotiation
%%--------------------------------------------------------------------

%% Returns the effective server capabilities given what the client supports.
%% For now this is a passthrough -- server advertises what it has. Future:
%% filter based on client capabilities (e.g. don't advertise sampling if
%% client doesn't support it).
-spec negotiate(#client_capabilities{}, #server_capabilities{}) ->
    #server_capabilities{}.
negotiate(_ClientCaps, ServerCaps) ->
    ServerCaps.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(_Key, M, Map) when is_map(M), map_size(M) =:= 0 -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.
