%%====================================================================
%% Description : RTMP channel API and callbacks
%%====================================================================

-module(rtmp_channel).
-copyright("LiveTex").
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

-behaviour(gen_server).

-include("rtmp.hrl").
-include("ptcl.hrl").

%% API external functions
-export([start/1, start_link/1, message/3, send_command/3, ackwinsize/2]).
% -export([srv_request/4, srv_response/3, srv_error/3, srv_notify/4, send_cmd/2]).

%% API internal functions
% -export([app_response/4, app_notify/3, client_msg/2, app_msg/2, ackwinsize/2, get_stream/2, get_send/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record

-record(state, {decode, encode, socket, connected = false, sid=0, list=[], publish_list=[]}).

-record(stream, {sid, publish, csid, monref, ref, name, gsid, list=[], play=false, pubmgr}).

-define(Stream, Stream#stream). %{}
-define(NewStream, NewStream#stream). %{}
-define(NewState, NewState#state). %{}
-define(CMDSID, 0).


%%====================================================================
%% API
%%====================================================================

start(Socket) ->
	rtmp_channel_sup:start_channel([Socket]).
	
start_link(Socket) ->
	gen_server:start_link(?MODULE, Socket, []).

message(Channel, DSID, Message) ->
	gen_server:cast(Channel, {message, internal, DSID, Message}).

send_command(Channel, Command, Params) ->
	gen_server:cast(Channel, {send_command, Command, Params}).

ackwinsize(Channel, Len) ->
	gen_server:cast(Channel, {ackwinsize, Len}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init(Socket) when is_port(Socket)  ->
	lager:debug("Start rtmp_channel; Socket: ~p", [Socket]),
	gen_server:cast(self(), init),
	{ok, #state{socket = Socket}};

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
	
handle_cast(init, State) ->
	case rtmp_handshake:init(?State.socket) of
		{ok, {Encrypted, KeyIn, KeyOut}} ->
			{ok, Encode} = rtmp_encode:start(self(), ?State.socket, Encrypted, KeyOut),
			erlang:monitor(process, Encode),
			SREF = erlang:make_ref(),
			Stream = #stream{ref = SREF, sid = ?CMDSID},
			rtmp_encode:create_stream(Encode, ?CMDSID),
			{ok, Decode} = rtmp_decode:start(self(), ?State.socket, Encrypted, KeyIn),
			erlang:monitor(process, Decode),
			{noreply, ?State{decode = Decode, encode = Encode, sid = ?CMDSID + 1, list = [{SREF, ?CMDSID, Stream}]}};
		{error, Reason} ->
			lager:error("rtmp_handshake:init() error:~n~p", [Reason]),
			{stop, {error, Reason}, State}
	end;

handle_cast({message, Type, StreamID, Message}, State) ->
	case manage_message(Type, Message, StreamID, State) of
		{ok, NewState} -> 
			{noreply, NewState};
		{{error, Reason}, NewState} -> 
			lager:error("internal_message: error result from stream: ~p~nReason: ~p~nMessage: ~p", [StreamID, Reason, Message]),
			{stop, {error, Reason}, NewState};
		{stop, NewState} ->
			lager:debug("internal_message: stop result from stream: ~p", [StreamID]),
			{stop, normal, NewState}
	end;

handle_cast({send_command, Command, Params}, State) ->
	lager:debug("send_command: ~p; Params:~n~p", [Command, Params]),
	rtmp_encode:send_message(?State.encode, 0, rtmp:cmd(?RTMP_CMD_AMF0, {Command, Params})),
	{noreply, State};

handle_cast({ackwinsize, Len}, State) ->
	rtmp_encode:send_message(?State.encode, 0, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT(Len)),
	{noreply, State};

% handle_cast({timeout, connect}, State) ->
% 	case ?State.connected of
% 		true -> {noreply, State};
% 		false -> 
% 			lager:debug("handle_cast: timeout connect"),
% 			{stop, normal, State}
% 	end;

%%--------------------------------------------------------------------

handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p", [Msg]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({'DOWN', _, _, Pid, Reason}, State) ->
	Decode = ?State.decode,
	Encode = ?State.encode,
	lager:debug("'DOWN' from ~p: ~p~nDecode: ~p; Encode: ~p", [Pid, Reason, Decode, Encode]),
	case Pid of
		Decode -> {stop, normal, State};
		Encode -> {stop, normal, State};
		_ -> 
			% case lists:keyfind(Pid, 3, ?State.list) of
			% 	false  -> 
				{noreply, State}%;
			% 	Stream -> {noreply, ?State{list = lists:keyreplace(?Stream.sid, 2, ?State.list, ?Stream{publish = undefined, monref = undefined})}}
			% end
	end;

handle_info(Info, State) ->
	lager:error("handle_info: nomatch Info:~n~p", [Info]),
	{stop, {error, nomatch}, State}.
	
%%--------------------------------------------------------------------
%% Description: terminate process
%%--------------------------------------------------------------------

terminate(Reason, _State) ->
	lager:debug("terminate: ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Description: Stream messages
%%--------------------------------------------------------------------

manage_message(internal, Message, SID, State) ->
	case lists:keyfind(SID, 2, ?State.list) of
		false ->
			lager:error("message: not found stream for SID: ~p", [SID]),
			{{error, not_found}, State};
		{_, SID, Stream} -> 
			manage_message(Message, Stream, State);
		Other ->
			lager:error("message: nomatch for SID: ~p~n~p", [SID, Other]),
			{{error, nomatch}, State}
	end;

manage_message(external, Message, SREF, State) ->
	case lists:keyfind(SREF, 1, ?State.list) of
		false ->
			lager:error("message: not found stream for SREF: ~p", [SREF]),
			{{error, not_found}, State};
		{SREF, _, Stream} -> 
			manage_message(Message, Stream, State);
		Other ->
			lager:error("message: nomatch for SREF: ~p~n~p", [SREF, Other]),
			{{error, nomatch}, State}
	end.

manage_message(Message, Stream, State) ->
	case stream_message(Message, Stream, State) of
		close 									-> {ok, ?State{list = lists:keydelete(?Stream.ref, 1, ?State.list)}};
		{close, NewState}						-> {ok, ?NewState{list = lists:keydelete(?Stream.ref, 1, ?NewState.list)}};
		{close, NewStream, NewState}			-> {ok, ?NewState{list = lists:keydelete(?NewStream.ref, 1, ?NewState.list)}};
		{Result, NewState} 						-> {Result, NewState};
		{Result, NewStream, NewState} 			-> {Result, ?NewState{list = lists:keyreplace(?NewStream.ref, 1, ?NewState.list, {?NewStream.ref, ?NewStream.sid, NewStream})}};
		Result 									-> {Result, State}
	end.

stream_message({command, [{?STRING, "connect"}, _TrID, Object | _Rest]}, _Stream, _State) ->
	rtmp_event:notify({rtmp_event, self(), {new_connection, Object}}),
	ok;

stream_message({command, [{?STRING, "createStream"}, TrID | _]}, _CMDStream, State) ->
	Stream = #stream{ref = erlang:make_ref(), sid = ?State.sid, gsid = rtmp:get_id()},
	rtmp_encode:create_stream(?State.encode, ?Stream.sid),
	rtmp_encode:send_message(?State.encode, ?CMDSID, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CREATE_STREAM, {TrID, ?Stream.sid})),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, ?RTMP_CMD_UCM_STREAM_BEGIN(?Stream.sid)),
	{ok, ?State{list = [{?Stream.ref, ?Stream.sid, Stream} | ?State.list], sid = ?State.sid + 1}};

stream_message({command, [{?STRING, "closeStream"}, 0.0, null]}, Stream, State) when ?Stream.play ->
	lager:debug("stream_message: closeStream: ~p; Player", [?Stream.ref]),
	rtmp_event:notify({rtmp_event, self(), {stop_play, ?Stream.ref, ?Stream.name}}),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_STOP, {?Stream.name, ?Stream.gsid})),
	{ok, Stream, State};

stream_message({command, [{?STRING, "closeStream"}, 0.0, null]}, Stream, State) when ?Stream.publish /= undefined ->
	lager:debug("stream_message: closeStream: ~p; Publisher (~p)", [?Stream.ref, ?Stream.publish]),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_UNPUBLISH_SUCCESS, {?Stream.name, ?Stream.gsid})),
	rtmp_event:notify({rtmp_event, self(), {stop_publish, ?Stream.ref, ?Stream.name}}),
	{ok, ?Stream{publish = undefined, name = undefined}, State};

stream_message({command, [{?STRING, "closeStream"}, 0.0, null]}, Stream, State) ->
	lager:debug("stream_message: closeStream: ~p", [?Stream.ref]),
	{ok, Stream, State};

stream_message({command, [{?STRING, "publish"}, 0.0, null, {?STRING, StreamName}, {?STRING, Type}]}, Stream, State) ->
	rtmp_event:notify({rtmp_event, self(), {start_publish, ?Stream.ref, StreamName, Type}}),
	{ok, ?Stream{name = StreamName}, State};

stream_message({command, [{?STRING, "play"}, 0.0, null, {?STRING, StreamName}, _Type]}, Stream, State) ->
	rtmp_event:notify({rtmp_event, self(), {start_play, ?Stream.ref, StreamName}}),
	{ok, ?Stream{name = StreamName}, State};

stream_message({command, [{?STRING, CMD}, 0.0, null, Params]}, _Stream, _State) ->
	lager:debug("stream_message: RTMP command: ~p~nParams: ~p", [CMD, Params]),
	rtmp_event:notify({rtmp_event, self(), {command, CMD, Params}}),
	ok;

stream_message({asknowledgement_window_size, AckWinSize}, _Stream, State) ->
	rtmp_decode:setAckWinSize(?State.decode, AckWinSize),
	rtmp_encode:send_message(?State.encode, ?CMDSID, ?RTMP_CMD_UCM_STREAM_BEGIN(0)),
	rtmp_encode:send_message(?State.encode, ?CMDSID, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CONNECT, {1})),
	ok;

stream_message(accept_connection, _Stream, State) ->
	lager:debug("stream_message: accept_connection"),
	rtmp_encode:send_message(?State.encode, ?CMDSID, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE),
	rtmp_encode:send_message(?State.encode, ?CMDSID, ?RTMP_CMD_PCM_SET_PEER_BANDWIDTH),
	{ok, ?State{connected = true}};

stream_message(reject_connection, _Stream, _State) ->
	lager:debug("stream_message: reject_connection"),
	stop;

stream_message({accept_publish, Publish}, Stream, State) ->
	lager:debug("stream_message: accept_publish for StreamName: ~p", [?Stream.name]),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_START, {?Stream.name, ?Stream.gsid})),
	Ref = erlang:monitor(process, Publish),
	{ok, ?Stream{publish = Publish, monref = Ref}, State};

stream_message(reject_publish, Stream, State) -> 
	lager:debug("stream_message: reject_publish for StreamName: ~p", [?Stream.name]),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_BADNAME, {?Stream.name, ?Stream.gsid})),
	ok;

stream_message(accept_play, Stream, State) ->
	lager:debug("stream_message: accept_play for StreamName: ~p", [?Stream.name]),
	rtmp_encode:send_message(?State.encode, ?CMDSID, ?RTMP_CMD_UCM_STREAM_BEGIN(?Stream.sid)),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_RESET, {?Stream.name, ?Stream.gsid})),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_START, {?Stream.name, ?Stream.gsid})),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_RTMPSAMPLEACCESS, nothing)),
	{ok, ?Stream{play = true}, State};

stream_message(reject_play, Stream, State) ->
	lager:debug("stream_message: reject_play for StreamName: ~p", [?Stream.name]),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_FAILED, {?Stream.name, ?Stream.gsid})),
	ok;

stream_message({publish, Message}, Stream, _State) when ?Stream.publish /= undefined ->
	?Stream.publish ! Message,
	ok;

stream_message({publish, _}, _Stream, _State) ->
	ok;

stream_message({data, Data, Type}, Stream, State) ->
	% lager:debug("Play data: <<~w>>; Type: ~w", [byte_size(Data), Type]),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, {Type, Data}),
	ok;

stream_message(_Message, _Stream, _State) ->
	lager:debug("stream_message:~nMessage: ~p~nStream: ~p", [_Message, _Stream]),
	ok.
