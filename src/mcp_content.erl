-module(mcp_content).

%% Builders for MCP content types.

-include("mcp.hrl").

-export([text/1, text/2, image/2, image/3, audio/2, audio/3,
         embedded_resource/1, embedded_resource/2]).
-export([to_map/1]).

%%--------------------------------------------------------------------
%% Builders
%%--------------------------------------------------------------------

-spec text(binary()) -> #text_content{}.
text(Text) ->
    #text_content{text = Text}.

-spec text(binary(), map()) -> #text_content{}.
text(Text, Annotations) ->
    #text_content{text = Text, annotations = Annotations}.

-spec image(binary(), binary()) -> #image_content{}.
image(Data, MimeType) ->
    #image_content{data = Data, mime_type = MimeType}.

-spec image(binary(), binary(), map()) -> #image_content{}.
image(Data, MimeType, Annotations) ->
    #image_content{data = Data, mime_type = MimeType, annotations = Annotations}.

-spec audio(binary(), binary()) -> #audio_content{}.
audio(Data, MimeType) ->
    #audio_content{data = Data, mime_type = MimeType}.

-spec audio(binary(), binary(), map()) -> #audio_content{}.
audio(Data, MimeType, Annotations) ->
    #audio_content{data = Data, mime_type = MimeType, annotations = Annotations}.

-spec embedded_resource(map()) -> #embedded_resource{}.
embedded_resource(Resource) ->
    #embedded_resource{resource = Resource}.

-spec embedded_resource(map(), map()) -> #embedded_resource{}.
embedded_resource(Resource, Annotations) ->
    #embedded_resource{resource = Resource, annotations = Annotations}.

%%--------------------------------------------------------------------
%% Serialization
%%--------------------------------------------------------------------

-spec to_map(term()) -> map().
to_map(#text_content{text = Text, annotations = undefined}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
to_map(#text_content{text = Text, annotations = Ann}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text,
      <<"annotations">> => Ann};
to_map(#image_content{data = Data, mime_type = Mime, annotations = undefined}) ->
    #{<<"type">> => <<"image">>, <<"data">> => Data,
      <<"mimeType">> => Mime};
to_map(#image_content{data = Data, mime_type = Mime, annotations = Ann}) ->
    #{<<"type">> => <<"image">>, <<"data">> => Data,
      <<"mimeType">> => Mime, <<"annotations">> => Ann};
to_map(#audio_content{data = Data, mime_type = Mime, annotations = undefined}) ->
    #{<<"type">> => <<"audio">>, <<"data">> => Data,
      <<"mimeType">> => Mime};
to_map(#audio_content{data = Data, mime_type = Mime, annotations = Ann}) ->
    #{<<"type">> => <<"audio">>, <<"data">> => Data,
      <<"mimeType">> => Mime, <<"annotations">> => Ann};
to_map(#embedded_resource{resource = Res, annotations = undefined}) ->
    #{<<"type">> => <<"resource">>, <<"resource">> => Res};
to_map(#embedded_resource{resource = Res, annotations = Ann}) ->
    #{<<"type">> => <<"resource">>, <<"resource">> => Res,
      <<"annotations">> => Ann}.
