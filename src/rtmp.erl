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

%% Application callbacks

-export([
	start/2,
	stop/1
]).

%% External API functions

-export([
	start/0, 
	stop/0,
	start_channel/2,
	app_request/5,
	app_response/3,
	app_error/3,
	app_notify/4
]).

-export([
	start_accept/2,
	start_send/2,
	start_recv/2,
	start_decode/1,
	srv_request/4,
	srv_response/3,
	srv_error/3,
	srv_notify/4,
	response/4,
	status/3,
	status/4,
	cmd/2,
	log/4,
	stream/0,
	stream/1,
	streams/1
]).

%%==============================================================================================================================================
%% Application callbacks
%%==============================================================================================================================================

start(_Type, _Args) ->
	?LOG(?MODULE, self(), "start", []),
%	Res1 = register:start(),
%	Res2 = register:create(?REGISTER),
	gproc:start_link(),
%	?LOG(?MODULE, self(), "register: ~p, ~p", [Res1, Res2]),
	rtmp_sup:start().

stop(_State) ->
	ok.


%%==============================================================================================================================================
%% External API functions
%%==============================================================================================================================================

start() ->
	application:load(?APPLICATION),
	application:start(?APPLICATION).
	
stop() ->
	application:stop(?APPLICATION),
	application:unload(?APPLICATION).

start_channel(Parent, Socket) ->
	rtmp_channel:start(Parent, Socket).

app_request(Channel, GSID, Cmd, Args, TrID) ->
	gen_server:cast(Channel, {app, {request, GSID, Cmd, Args, TrID}}).

app_response(Channel, TrID, Response) ->
	gen_server:cast(Channel, {app, {response, TrID, Response}}).

app_error(Channel, TrID, Error) ->
	gen_server:cast(Channel, {app, {error, TrID, Error}}).	

app_notify(Channel, GSID, Cmd, Args) ->
	gen_server:cast(Channel, {app, {notify, GSID, Cmd, Args}}).

%%==============================================================================================================================================
%% Internal API functions
%%==============================================================================================================================================

start_accept(Parent, Port) ->
	gen_server:call(?ACCEPT, {start_accept, Parent, Port}).

start_send(Channel, Socket) ->
	supervisor:start_child(?SEND_SUP, [Channel, Socket]).
	
start_recv(Channel, Socket) ->
	supervisor:start_child(?RECV_SUP, [Channel, Socket]).
	
start_decode(Channel) ->
	supervisor:start_child(?DECODE_SUP, [Channel]).
	
srv_request(Parent, GSID, Cmd, Args) ->
	gen_server:call(Parent, {srv, {request, GSID, Cmd, Args}}).

srv_response(Parent, TrID, Response) ->
	gen_server:cast(Parent, {srv, {response, TrID, Response}}).

srv_error(Parent, TrID, Error) ->
	gen_server:cast(Parent, {srv, {error, TrID, Error}}).

srv_notify(Parent, GSID, Cmd, Args) ->
	gen_server:cast(Parent, {srv, {notify, GSID, Cmd, Args}}).
	
response(CMD, TrID, Properties, Information) ->
	[{?STRING, CMD}, TrID, Properties, Information].
	
status(Code, Description, ClientID) ->
	{map, [
		{{?STRING, "level"}, 		{?STRING, "status"}}, 
		{{?STRING, "code"}, 		{?STRING, Code}}, 
		{{?STRING, "description"}, 	{?STRING, Description}},
		{{?STRING, "clientid"}, 	ClientID}
	]}.
status(Code, Description, Details, ClientID) ->
	{map, [
		{{?STRING, "level"}, 		{?STRING, "status"}}, 
		{{?STRING, "code"}, 		{?STRING, Code}}, 
		{{?STRING, "description"}, 	{?STRING, Description}},
		{{?STRING, "details"}, 		{?STRING, Details}},
		{{?STRING, "clientid"}, 	ClientID}
	]}.

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
	{?RTMP_MSG_COMMAND_AMF0, response("onStatus", 0, null, Information)};
	
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
	
cmd(?RTMP_CMD_AMF0_RTMPSAMPLEACCESS, _) ->
	{?RTMP_MSG_DATA_AMF0, [{?STRING, "|RtmpSampleAccess"}, false, false]};
	
cmd(_N, _Args) ->
	{?RTMP_MSG_COMMAND_AMF0, []}.
	
log(Module, Pid, Format, Data) ->
	io:format("~-" ++ ?TITLE_LENGTH ++ "w (~w): " ++ Format ++ "~n", [Module, Pid] ++ Data).

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

get_id() ->
	{A1,A2,A3} = now(),
	random:seed(A1, A2, A3),
	get_id(10, []).
	
get_id(0, List) ->
	{?STRING, List};
	
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