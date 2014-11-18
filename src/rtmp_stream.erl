%%====================================================================
%% Description : RTMP stream API and callbacks
%%====================================================================

-module(rtmp_stream).
-copyright("LiveTex").
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-11").
-version("0.1").

-behaviour(gen_server).

-include("rtmp.hrl").
-include("ptcl.hrl").

%% API external functions
-export([start/3, start_link/3, start/4, start_link/4, stop/1]).
-export([app_request/4, app_response/4, app_error/4, app_notify/3, client_message/2, data/2]).

%% API internal functions
-export([send_cmd/2, app_message/2, client_msg/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record
-record(state, {connection, parent, channel, encode, sid, csid, gsid, name, list=[], publish=false, play=false}).

%%====================================================================
%% API
%%====================================================================

start(Connection, StreamID, ChunkStreamID) ->
	rtmp_stream_sup:start_stream([Connection, StreamID, ChunkStreamID]).

start(Channel, Socket, SID, CSID) ->
	supervisor:start_child(?STREAM_SUP, [Channel, Socket, SID, CSID]).
	
start_link(Connection, StreamID, ChunkStreamID) ->
	gen_server:start_link(?MODULE, {Connection, StreamID, ChunkStreamID}, []).

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

init({Connection, StreamID, ChunkStreamID}) ->
	lager:debug("Start rtmp_stream; Conn: ~p; SID: ~p; CSID: ~p", [Connection, StreamID, ChunkStreamID]),
	erlang:monitor(process, Connection),
	{ok, #state{connection = Connection, sid = StreamID, csid = ChunkStreamID}};

init(Args) ->
	lager:error("init: nomatch Args:~n~p", [Args]),
	{stop, {error, nomatch}}.
	
%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call(Request, _From, State) ->
	lager:error("handle_call: nomatch Request:~n~p", [Request]),
	Error = {error, nomatch},
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
	
handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p", [Msg]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, S) ->
	{stop, normal, S};

handle_info(Info, State) ->
	lager:error("handle_info: nomatch Info:~n~p", [Info]),
	{stop, {error, nomatch}, State}.
	
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

terminate(Reason, _State) ->
	% rtmp_channel:srv_notify(S#state.channel, {?STRING, S#state.gsid}, {?STRING, "terminate"}, null),
	lager:debug("terminate:~n~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
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

% %%--------------------------------------------------------------------
% %% Description: Encode RTMP data
% %%--------------------------------------------------------------------

% encode(type, S, {Type, Msg}) ->
% 	case Type of
% 		?RTMP_PCM_SET_CHUNK_SIZE ->
% 			encode(msghead, S, {Type, 4, <<Msg:32>>});
% 		?RTMP_PCM_ACKNOWLEDGEMENT ->
% 			encode(msghead, S, {Type, 4, <<Msg:32>>});
% 		?RTMP_PCM_USER_CONTROL_MESSAGE ->
% 			case Msg of
% 				{?RTMP_UCM_SET_BUFFER_LENGTH, {StreamId, BufferLength}} ->
% 					encode(msghead, S, {Type, 10, <<?RTMP_UCM_SET_BUFFER_LENGTH:16, StreamId:32, BufferLength:32>>});
% 				{EventType, EventData} ->
% 					encode(msghead, S, {Type, 6, <<EventType:16, EventData:32>>})
% 			end;
% 		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
% 			encode(msghead, S, {Type, 4, <<Msg:32>>});
% 		?RTMP_PCM_SET_PEER_BANDWIDTH ->
% 			{Size, LimitType} = Msg,
% 			encode(msghead, S, {Type, 5, <<Size:32, LimitType:8>>});
% 		?RTMP_MSG_AUDIO ->
% 			encode(msghead, S, {Type, byte_size(Msg), Msg});
% 		?RTMP_MSG_VIDEO ->
% 			encode(msghead, S, {Type, byte_size(Msg), Msg});
% 		?RTMP_MSG_DATA_AMF0 ->
% 			Bin = amf0:encode_args(Msg),
% 			encode(msghead, S, {Type, byte_size(Bin), Bin});
% 		?RTMP_MSG_COMMAND_AMF0 ->
% 			Bin = amf0:encode_args(Msg),
% 			encode(msghead, S, {Type, byte_size(Bin), Bin});
% 		Type ->
% 			lager:warning("encode: nomatch Type: ~p", [Type]),
% 			{noreply, S}
% 	end;

% encode(msghead, S, {Type, Len, Bin}) when S#state.type == Type, S#state.len == Len -> % fmt == 2
% 	{Ts, Tsd} = get_timestamp_diff(S#state.ts),
% 	encode(chunk, S#state{ts = Ts}, <<2:2, (S#state.csidb)/bitstring, Tsd:24>>, Bin);

% encode(msghead, S, {Type, Len, Bin}) when S#state.type == Type -> %fmt == 1
% 	{Ts, Tsd} = get_timestamp_diff(S#state.ts),
% 	encode(chunk, S#state{ts = Ts, len = Len}, <<1:2, (S#state.csidb)/bitstring, Tsd:24, Len:24, Type:8>>, Bin);

% encode(msghead, S, {Type, Len, Bin}) ->
% 	case Type of
% 		?RTMP_MSG_AUDIO ->
% 			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
% 		?RTMP_MSG_VIDEO ->
% 			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
% 		?RTMP_MSG_DATA_AMF0 ->
% 			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
% 		?RTMP_MSG_COMMAND_AMF0 ->
% 			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
% 		_CMD ->
% 			encode(msghead, S#state{len = Len}, {Type, Bin})
% 	end;

% encode(msghead, S, {Type, Bin}) -> % fmt == 0
% 	{Ts, Tsd} = get_timestamp_diff(S#state.fts),
% 	encode(chunk, S#state{ts = Ts}, <<0:2, (S#state.csidb)/bitstring, Tsd:24, (S#state.len):24, Type:8, (S#state.sid):32>>, Bin).

% encode(chunk, S, _Head, <<>>) ->
% 	{noreply, S};

% encode(chunk, S, Head, Bin) ->
% 	case byte_size(Bin) > S#state.csize of
% 		true ->
% 			{P, R} = split_binary(Bin, S#state.csize),
% 			encode(send, S, <<Head/binary, P/binary>>, R);
% 		false ->
% 			encode(send, S, <<Head/binary, Bin/binary>>, <<>>)
% 	end;

% encode(send, S, Chunk, Bin) ->
% 	case gen_tcp:send(S#state.socket, Chunk) of
% 		ok ->
% 			encode(chunk, S, <<3:2, (S#state.csidb)/bitstring>>, Bin);
% 		{error, Reason} ->
% 			lager:error("encode: gen_tcp:send() error:~n~p", [Reason]),
% 			{stop, {error, Reason}, S}
% 	end.

% get_timestamp_diff(Ts1) ->
% 	Ts2 = now(),
% 	{Ts2, round(timer:now_diff(Ts2, Ts1)/1000)}.