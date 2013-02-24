%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp_stream.erl
%%% Author      : Ekimov Artem <ekimov-artem@ya.ru>
%%% Description : RTMP stream API and callbacks
%%% Created     : 28.04.2012
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp_stream).

-author('ekimov-artem@ya.ru').

-behaviour(gen_server).

-include("rtmp.hrl").
-include("ptcl.hrl").

%% API external functions

-export([start/4, start_link/4, stop/1]).

-export([app_request/4, app_response/4, app_error/4, app_notify/3, client_message/2, data/2]).

%% API internal functions

-export([send_cmd/2, app_message/2, client_msg/2]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {parent, channel, encode, sid, gsid, name, list=[], publish=false, play=false}).

%%====================================================================
%% API
%%====================================================================

start(Channel, Socket, SID, CSID) ->
	supervisor:start_child(?STREAM_SUP, [Channel, Socket, SID, CSID]).
	
start_link(Channel, Socket, SID, CSID) ->
	gen_server:start_link(?MODULE, {Channel, Socket, SID, CSID}, []).
	
stop(Pid) ->
	gen_server:call(Pid, stop).

app_request(Stream, Cmd, Args, TrID) ->
	gen_server:call(Stream, {app, {request, Cmd, Args, TrID}}).

app_response(Stream, Cmd, Response, TrID) ->
	gen_server:cast(Stream, {app, {response, Cmd, Response, TrID}}).

app_error(Stream, Cmd, Error, TrID) ->
	gen_server:cast(Stream, {app, {error, Cmd, Error, TrID}}).

app_notify(Stream, Cmd, Args) ->
	gen_server:cast(Stream, {app, {notify, Cmd, Args}}).
	
client_message(Stream, Msg) ->
	gen_server:cast(Stream, {client_message, Msg}).
	
send_cmd(Stream, Cmd) ->
	gen_server:cast(Stream, {send_cmd, Cmd}).

data(Stream, Data) ->
	gen_server:cast(Stream, {data, Data}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init({Channel, Socket, SID, CSID}) ->
	?LOG(?MODULE, self(), "start: {~w, ~w, ~w, ~w}", [Channel, Socket, SID, CSID]),
	{ok, Encode} = rtmp_encode:start(self(), Socket, SID, CSID),
	erlang:monitor(process, Channel),
	{ok, GSID} = rtmp:stream(),
	{ok, #state{channel = Channel, encode = Encode, sid = SID, gsid = GSID}};

init(_Args) ->
	{stop, {error, {?MODULE, self(), no_matching, init}}}.
	
%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call(_Request, _From, State) ->
	Error = {error, {?MODULE, self(), no_matching, handle_cast}},
	{stop, Error, Error, State}.
	
%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------

% Message from client

handle_cast({client_message, Msg}, S) ->
	?MODULE:client_msg(Msg, S);

% Message from application

handle_cast({app, Msg}, S) ->
	?MODULE:app_message(Msg, S);

%
	
handle_cast({send_cmd, Cmd}, S) ->
%	?LOG(?MODULE, self(), "send command:~n~p", [Cmd]),
	rtmp_encode:send(S#state.encode, Cmd),
	{noreply, S};

% Stream data: audio/video

handle_cast({data, {video, Data}}, S) ->
%	?LOG(?MODULE, self(), "receive video data: <<~w>>", [byte_size(Data)]),
	rtmp_encode:send(S#state.encode, {?RTMP_MSG_VIDEO, Data}),
	{noreply, S};
	
handle_cast(_Msg, State) ->
	{stop, {error, {?MODULE, self(), no_matching, handle_cast}}, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, S) ->
	{stop, normal, S};
	

handle_info(_Info, State) ->
	{stop, {error, {?MODULE, self(), no_matching, handle_info}}, State}.
	
%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: terminate process
%%--------------------------------------------------------------------

%terminate(_Reason, S) when S#state.publish ->
%	rtmp_channel:srv_notify(S#state.channel, {?STRING, S#state.gsid}, {?STRING, "unpublish"}, null),
%	?LOG(?MODULE, self(), "terminate: publish", []),
%	ok;
%
%terminate(_Reason, S) when S#state.play ->
%	rtmp_channel:srv_notify(S#state.channel, {?STRING, S#state.gsid}, {?STRING, "unplay"}, null),
%	?LOG(?MODULE, self(), "terminate: play", []),
%	ok;

terminate(_Reason, S) ->
	rtmp_channel:srv_notify(S#state.channel, {?STRING, S#state.gsid}, {?STRING, "terminate"}, null),
	?LOG(?MODULE, self(), "terminate", []),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	?LOG(?MODULE, self(), "code_change", []),
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Client messages
%%--------------------------------------------------------------------

% Publish video

client_msg({command, [{?STRING, "publish"}, _TrID, null, {?STRING, Name} = ClientName, Type]}, S) when not S#state.publish ->
	rtmp_channel:srv_request(S#state.channel, self(), {?STRING, "publish"}, [S#state.gsid, ClientName, Type]),
	{noreply, S#state{name = Name}};

client_msg({command, [{?STRING, "publish"} | _]}, S) ->
	{noreply, S};

% play video

client_msg({command, [{?STRING, "play"}, _TrID, null, {?STRING, Name} = ClientName, Type]}, S) ->
	rtmp_channel:srv_request(S#state.channel, self(), {?STRING, "play"}, [S#state.gsid, ClientName, Type]),
	{noreply, S#state{name = Name}};

client_msg({command, [{?STRING, "play"} | _]}, S) ->
	{noreply, S};

% Close stream

client_msg({command, [{?STRING, "closeStream"}, _TrID, null]}, S) when S#state.publish ->
	rtmp_channel:srv_request(S#state.channel, self(), {?STRING, "unpublish"}, S#state.gsid),
	{noreply, S};

client_msg({command, [{?STRING, "closeStream"}, _TrID, null]}, S) when S#state.play ->
	rtmp_channel:srv_request(S#state.channel, self(), {?STRING, "unplay"}, S#state.gsid),
	rtmp_encode:send(S#state.encode, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_STOP, {S#state.name, S#state.gsid})),
	{noreply, S};

client_msg({command, [{?STRING, "closeStream"}, _TrID, null]}, S) ->
	{stop, normal, S};
	
% Video packet

client_msg({video, Data}, S) ->
%	?LOG(?MODULE, self(), "send video data: <<~w>>", [byte_size(Data)]),
	lists:foreach(fun(Stream) -> rtmp_stream:data(Stream, {video, Data}) end, S#state.list),
	{noreply, S};

% Audio packet

client_msg({audio, _Data}, S) ->
	{noreply, S};

% Any message

client_msg(Msg, S) ->
	?LOG(?MODULE, self(), "client message:~n~p", [Msg]),
	{noreply, S}.
	
%%--------------------------------------------------------------------
%% Application messages
%%--------------------------------------------------------------------

% Application request
	
app_message({request, _Cmd, _Args, TrID} = Msg, S) ->
	?LOG(?MODULE, self(), "app_request: unknown message~n~p", [Msg]),
	rtmp_channel:srv_error(S#state.channel, TrID, {?STRING, "Unknown request"}),
	{noreply, S};

% Application response

app_message({response, {?STRING, "publish"}, true, _TrID}, S) ->
	?LOG(?MODULE, self(), "publish: ok", []),
	rtmp_encode:wait_mainframe(S#state.encode),
	rtmp_encode:send(S#state.encode, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_START, {S#state.name, S#state.gsid})),
	{noreply, S#state{publish = true}};

app_message({response, {?STRING, "publish"}, false, _TrID}, S) ->
	?LOG(?MODULE, self(), "publish: fail", []),
	{stop, normal, S};

app_message({response, {?STRING, "unpublish"}, true, _TrID}, S) ->
	?LOG(?MODULE, self(), "unpublish: ok", []),
	rtmp_encode:send(S#state.encode, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_UNPUBLISH_SUCCESS, {S#state.name, S#state.gsid})),
	{noreply, S#state{publish = false}};

app_message({response, {?STRING, "play"}, true, _TrID}, S) ->
	?LOG(?MODULE, self(), "play: ok", []),
	rtmp_channel:send_cmd(S#state.channel, ?RTMP_CMD_UCM_STREAM_BEGIN(S#state.sid)),

	rtmp_encode:send(S#state.encode, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_RESET, {S#state.name, S#state.gsid})),
	rtmp_encode:send(S#state.encode, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_START, {S#state.name, S#state.gsid})),
	rtmp_encode:send(S#state.encode, rtmp:cmd(?RTMP_CMD_AMF0_RTMPSAMPLEACCESS, nothing)),
	{noreply, S#state{play = true}};

app_message({response, _Cmd, _Response, _TrID} = Msg, S) ->
	?LOG(?MODULE, self(), "app_response: unknown message~n~p", [Msg]),
	{noreply, S};

% Application error

app_message({error, _Cmd, _Error, _TrID} = Msg, S) ->
	?LOG(?MODULE, self(), "app_error: unknown message~n~p", [Msg]),
	{noreply, S};

% Application notify

app_message({notify, {?STRING, "setPlayList"}, List}, S) ->
%	?LOG(?MODULE, self(), "app_notify: setPlayList:~n~p", [List]),
	{ok, PList} = rtmp:streams(List),
	?LOG(?MODULE, self(), "app_notify: setPlayList	:~n~p", [PList]),
	{noreply, S#state{list = PList}};

app_message({notify, _Cmd, _Args} = Msg, S) ->
	?LOG(?MODULE, self(), "app_notify: unknown message~n~p", [Msg]),
	{noreply, S};

% any message from app 

app_message(Msg, S) ->
	?LOG(?MODULE, self(), "app_message: unknown message~n~p", [Msg]),
	{noreply, S}.