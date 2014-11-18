%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp.erl
%%% Author      : Artem A. Ekimov <ekimov-artem@ya.ru>
%%% Description : RTMP application API module
%%% Created     : 28.04.2012
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp).

-bahaviour(application).

-include("rtmp.hrl").
-include("ptcl.hrl").

-define(CMDSID, 0).

%% Application callbacks

-export([
	start/2,
	stop/1
]).

%% External API functions

-export([
	accept_connection/1,
	reject_connection/1,
	accept_publish/3,
	reject_publish/2,
	accept_play/2,
	reject_play/2,
	message/3
	% start/0, 
	% stop/0
]).

-export([
	get_env/2,
	response/4,
	status/3,
	status/4,
	cmd/2,
	stream/0,
	stream/1,
	streams/1,
	string/1,
	get_id/0
]).

%%==============================================================================================================================================
%% Application callbacks
%%==============================================================================================================================================

start(_Type, _Args) ->
	rtmp_sup:start().

stop(_State) ->
	ok.


%%==============================================================================================================================================
%% External API functions
%%==============================================================================================================================================

accept_connection(Channel) ->
	rtmp_channel:message(Channel, ?CMDSID, accept_connection).

reject_connection(Channel) ->
	rtmp_channel:message(Channel, ?CMDSID, reject_connection).

accept_publish(Channel, StreamRef, Publish) ->
	rtmp:message(Channel, StreamRef, {accept_publish, Publish}).

reject_publish(Channel, StreamRef) ->
	rtmp:message(Channel, StreamRef, reject_publish).

accept_play(Channel, StreamRef) ->
	rtmp:message(Channel, StreamRef, accept_play).

reject_play(Channel, StreamRef) ->
	rtmp:message(Channel, StreamRef, reject_play).

message(Channel, StreamRef, Message) ->
	gen_server:cast(Channel, {message, external, StreamRef, Message}).

% start() ->
% 	application:load(?APPLICATION),
% 	application:start(?APPLICATION).
	
% stop() ->
% 	application:stop(?APPLICATION),
% 	application:unload(?APPLICATION).

%%==============================================================================================================================================
%% Internal API functions
%%==============================================================================================================================================

response(CMD, TrID, Properties, Information) ->
	[{?STRING, CMD}, TrID, Properties, Information].
	
status(Code, Description, ClientID) ->
	{map, [
		{{?STRING, "level"}, 		{?STRING, "status"}}, 
		{{?STRING, "code"}, 		{?STRING, Code}}, 
		{{?STRING, "description"}, 	{?STRING, Description}},
		{{?STRING, "clientid"}, 	{?STRING, ClientID}}
	]}.
status(Code, Description, Details, ClientID) ->
	{map, [
		{{?STRING, "level"}, 		{?STRING, "status"}}, 
		{{?STRING, "code"}, 		{?STRING, Code}}, 
		{{?STRING, "description"}, 	{?STRING, Description}},
		{{?STRING, "details"}, 		{?STRING, Details}},
		{{?STRING, "clientid"}, 	{?STRING, ClientID}}
	]}.

error(Code, Description, ClientID) ->
	{map, [
		{{?STRING, "level"}, 		{?STRING, "error"}}, 
		{{?STRING, "code"}, 		{?STRING, Code}}, 
		{{?STRING, "description"}, 	{?STRING, Description}},
		{{?STRING, "clientid"}, 	{?STRING, ClientID}}
	]}.

error(Code, Description, Details, ClientID) ->
	{map, [
		{{?STRING, "level"}, 		{?STRING, "error"}}, 
		{{?STRING, "code"}, 		{?STRING, Code}}, 
		{{?STRING, "description"}, 	{?STRING, Description}},
		{{?STRING, "details"}, 		{?STRING, Details}},
		{{?STRING, "clientid"}, 	{?STRING, ClientID}}
	]}.

%%--------------------------------------------------------------------

cmd(?RTMP_CMD_AMF0, {Command, Params}) ->
	{?RTMP_MSG_COMMAND_AMF0, [Command, 0, null, Params]};

cmd(?RTMP_CMD_AMF0_RESULT_CONNECT, {TrID}) ->
	Properties = {map, [
			{{?STRING, "fmsVer"},			{?STRING, "FMS/3,5,1,516"}},
			{{?STRING, "capabilities"},		31},
			{{?STRING, "mode"},				1}
		]},
	Information = {map, [
			{{?STRING, "level"},			{?STRING, "status"}},
			{{?STRING, "code"},				{?STRING, "NetConnection.Connect.Success"}},
			{{?STRING, "objectEncoding"},	3},
			{{?STRING, "data"},				null},
			{{?STRING, "version"},			{?STRING, "3,5,1,516"}}
		]},
	{?RTMP_MSG_COMMAND_AMF0, response("_result", TrID, Properties, Information)};
	
cmd(?RTMP_CMD_AMF0_RESULT_CREATE_STREAM, {TrID, N}) ->
	{?RTMP_MSG_COMMAND_AMF0, response("_result", TrID, null, N)};

cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_START, {Name, ID}) ->
	Information = status("NetStream.Publish.Start", Name ++ " is now published.", ID),
	{?RTMP_MSG_COMMAND_AMF3, response("onStatus", 0.0, null, Information)};

cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_BADNAME, {Name, ID}) ->
	Information = error("NetStream.Publish.BadName", Name ++ " is not published.", ID),
	{?RTMP_MSG_COMMAND_AMF3, response("onStatus", 0.0, null, Information)};
	
cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_UNPUBLISH_SUCCESS, {Name, ID}) ->
	Information = status("NetStream.Unpublish.Success", Name ++ " is now unpublished.", ID),
	{?RTMP_MSG_COMMAND_AMF0, response("onStatus", 0, null, Information)};
	
cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_START, {Name, ID}) ->
	Information = status("NetStream.Play.Start", "Started playing " ++ Name, Name, ID),
	{?RTMP_MSG_COMMAND_AMF0, response("onStatus", 0, null, Information)};
	
cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_RESET, {Name, ID}) ->
	Information = status("NetStream.Play.Reset", "!Playing and resetting " ++ Name, Name, ID),
	{?RTMP_MSG_COMMAND_AMF0, response("onStatus", 0, null, Information)};
	
cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_STOP, {Name, ID}) ->
	Information = status("NetStream.Play.Stop", "Stopped playing " ++ Name, Name, ID),
	{?RTMP_MSG_COMMAND_AMF0, response("onStatus", 0, null, Information)};
	
cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_FAILED, {Name, ID}) ->
	Information = error("NetStream.Play.Failed", "Failed playing " ++ Name, Name, ID),
	{?RTMP_MSG_COMMAND_AMF3, response("onStatus", 0.0, null, Information)};

cmd(?RTMP_CMD_AMF0_RTMPSAMPLEACCESS, _) ->
	{?RTMP_MSG_DATA_AMF0, [{?STRING, "|RtmpSampleAccess"}, false, false]};
	
cmd(_N, _Args) ->
	{?RTMP_MSG_COMMAND_AMF0, []}.
	
%%--------------------------------------------------------------------

stream() ->
	GSID = get_id(),
	?LOG(?MODULE, self(), "stream: get_id: ~p", [GSID]),
	gproc:add_local_name(GSID),
	{ok, GSID}.

stream(GSID) ->
	case gproc:lookup_local_name(GSID) of
		undefined -> {error, undefined};
		Stream -> {ok, Stream}
	end.

streams([]) ->
	{ok, []};
streams(List) ->
	Streams = lists:foldl(fun(GSID, Acc) ->
		case gproc:lookup_local_name(GSID) of
			undefined -> Acc;
			Stream -> [Stream | Acc]
		end
	end, [], List),
	{ok, Streams}.

get_env(Key, Def) ->
	case (catch application:get_env(?APPLICATION, Key)) of
		undefined -> Def;
		{ok, Val} -> Val;
		{'EXIT', Reason} ->
			lager:error("get_env: EXIT:~n~p", [Reason]),
			Def
	end.

get_id() ->
	{A1,A2,A3} = now(),
	random:seed(A1, A2, A3),
	get_id(10, []).
	
get_id(0, List) ->
	List;
	
get_id(N, List) ->
	get_id(N-1, [get_char() | List]).
	
get_char() ->
	N = random:uniform(52),
	case (N < 27) of
		true ->
			N + 64;
		false ->
			N - 26 + 96
	end.

string(String) -> {?STRING, String}.