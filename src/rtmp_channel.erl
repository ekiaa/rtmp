%%====================================================================
%% Description : RTMP channel API and callbacks
%%====================================================================

-module(rtmp_channel).

-author("Artem Ekimov <ekimov-artem@ya.ru>").

-behaviour(gen_server).

-include("rtmp.hrl").
-include("ptcl.hrl").

%% API functions
-export([start/1, start_link/1, message/3, send_command/3, ackwinsize/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(CMDSID, 0).

-define(NEW_STATE,
	#{	socket       => undefined,
		decode       => undefined,
		encode       => undefined,
		connected    => false,
		sid          => 0,
		list         => [],
		publish_list => []}).

-define(NEW_STREAM, 
	#{	sid     => undefined,
		publish => undefined,
		csid    => undefined,
		monref  => undefined,
		ref     => undefined,
		name    => undefined,
		gsid    => undefined,
		pubmgr  => undefined,
		play    => false,
		list    => []}).

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

init(Socket) when is_port(Socket)  ->
	lager:debug("Start rtmp_channel; Socket: ~p", [Socket]),
	self() ! init,
	{ok, init_map(#{socket => Socket}, ?NEW_STATE)};

init(Args) ->
	{stop, {?MODULE, ?LINE, no_matching, Args}}.
	
%%--------------------------------------------------------------------

handle_call(Request, _From, State) ->
	{stop, {?MODULE, ?LINE, no_matching, Request}, {error, no_matching}, State}.
	
%%--------------------------------------------------------------------

handle_cast({message, Type, StreamID, Message}, State) ->
	manage_message(Type, Message, StreamID, State);

handle_cast({send_command, Command, Params}, #{encode := Encode} = State) ->
	lager:debug("send_command: ~p; Params:~n~p", [Command, Params]),
	rtmp_encode:send_message(Encode, 0, rtmp:cmd(?RTMP_CMD_AMF0, {Command, Params})),
	{noreply, State};

handle_cast({ackwinsize, Len}, #{encode := Encode} = State) ->
	rtmp_encode:send_message(Encode, 0, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT(Len)),
	{noreply, State};

handle_cast(Message, State) ->
	{stop, {?MODULE, ?LINE, no_matching, Message}, State}.

%%--------------------------------------------------------------------

handle_info(init, #{socket := Socket} = State) ->
	case rtmp_handshake:init(Socket) of
		{ok, {Encrypted, KeyIn, KeyOut}} ->
			{ok, Encode} = rtmp_encode:start(self(), Socket, Encrypted, KeyOut),
			erlang:monitor(process, Encode),
			SREF = erlang:make_ref(),
			Stream = init_map(#{ref => SREF, sid => ?CMDSID}, ?NEW_STREAM),
			rtmp_encode:create_stream(Encode, ?CMDSID),
			{ok, Decode} = rtmp_decode:start(self(), Socket, Encrypted, KeyIn),
			erlang:monitor(process, Decode),
			{noreply, State#{decode => Decode, encode => Encode, sid => ?CMDSID + 1, list => [{?CMDSID, SREF, Stream}]}};
		{error, Reason} ->
			{stop, {?MODULE, ?LINE, error, Reason}, State}
	end;

handle_info({'DOWN', _, _, Pid, _Reason}, #{decode := Decode, encode := Encode} = State) ->
	case Pid of
		Decode -> {stop, normal, State};
		Encode -> {stop, normal, State};
		_ -> {noreply, State}
	end;

handle_info(Info, State) ->
	{stop, {?MODULE, ?LINE, no_matching, Info}, State}.
	
%%--------------------------------------------------------------------

terminate(normal, _) -> ok;
terminate(Reason, State) -> lager:error("terminate~nReason: ~p~nState: ~p", [Reason, State]).

%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

manage_message(internal, Message, SID, #{list := List} = State) ->
	case lists:keyfind(SID, 1, List) of
		false -> {error, {?MODULE, ?LINE, error, not_found}, State};
		{_SID, _SREF, Stream} -> stream_message(Message, Stream, State)
	end;

manage_message(external, Message, SREF, #{list := List} = State) ->
	case lists:keyfind(SREF, 2, List) of
		false -> {error, {?MODULE, ?LINE, error, not_found}, State};
		{_SID, _SREF, Stream} -> stream_message(Message, Stream, State)
	end.

%%--------------------------------------------------------------------

stream_message({command, [{?STRING, "connect"}, _TrID, Object | _Rest]}, _Stream, State) ->
	rtmp_event:notify({rtmp_event, self(), {new_connection, Object}}),
	{noreply, State};

stream_message({command, [{?STRING, "createStream"}, TrID | _]}, _CMDStream, #{encode := Encode, list := List, sid := SID} = State) ->
	SREF = erlang:make_ref(),
	Stream = init_map(#{ref => SREF, sid => SID, gsid => rtmp:get_id()}, ?NEW_STREAM),
	rtmp_encode:create_stream(Encode, SID),
	rtmp_encode:send_message(Encode, ?CMDSID, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CREATE_STREAM, {TrID, SID})),
	rtmp_encode:send_message(Encode, SID, ?RTMP_CMD_UCM_STREAM_BEGIN(SID)),
	{noreply, State#{list => [{SID, SREF, Stream} | List], sid => SID + 1}};

stream_message({command, [{?STRING, "closeStream"}, 0.0, null]}, #{play := Play, ref := Ref, sid := SID, name := Name, gsid := GSID}, #{encode := Encode} = State) when Play ->
	lager:debug("stream_message: closeStream: ~p; Player", [Ref]),
	rtmp_event:notify({rtmp_event, self(), {stop_play, Ref, Name}}),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_STOP, {Name, GSID})),
	{noreply, State};

stream_message({command, [{?STRING, "closeStream"}, 0.0, null]}, #{publish := Publish, ref := Ref, sid := SID, name := Name, gsid := GSID} = Stream, #{encode := Encode} = State) when Publish /= undefined ->
	lager:debug("stream_message: closeStream: ~p; Publisher (~p)", [Ref, Publish]),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_UNPUBLISH_SUCCESS, {Name, GSID})),
	rtmp_event:notify({rtmp_event, self(), {stop_publish, Ref, Name}}),
	{noreply, save_stream(Stream#{publish => undefined, name => undefined}, State)};

stream_message({command, [{?STRING, "closeStream"}, 0.0, null]}, #{ref := Ref} = Stream, State) ->
	lager:debug("stream_message: closeStream: ~p", [Ref]),
	{noreply, delete_stream(Stream, State)};

stream_message({command, [{?STRING, "publish"}, 0.0, null, {?STRING, StreamName}, {?STRING, Type}]}, #{ref := Ref} = Stream, State) ->
	rtmp_event:notify({rtmp_event, self(), {start_publish, Ref, StreamName, Type}}),
	{noreply, save_stream(Stream#{name => StreamName}, State)};

stream_message({command, [{?STRING, "play"}, 0.0, null, {?STRING, StreamName}, _Type]}, #{ref := Ref} = Stream, State) ->
	rtmp_event:notify({rtmp_event, self(), {start_play, Ref, StreamName}}),
	{noreply, save_stream(Stream#{name => StreamName}, State)};

stream_message({command, [{?STRING, CMD}, 0.0, null, Params]}, _Stream, State) ->
	lager:debug("stream_message: RTMP command: ~p~nParams: ~p", [CMD, Params]),
	rtmp_event:notify({rtmp_event, self(), {command, CMD, Params}}),
	{noreply, State};

stream_message({asknowledgement_window_size, AckWinSize}, _Stream, #{encode := Encode, decode := Decode} = State) ->
	rtmp_decode:setAckWinSize(Decode, AckWinSize),
	% rtmp_encode:send_message(Encode, ?CMDSID, ?RTMP_CMD_PCM_SET_CHUNK_SIZE(4096)),
	rtmp_encode:send_message(Encode, ?CMDSID, ?RTMP_CMD_UCM_STREAM_BEGIN(0)),
	rtmp_encode:send_message(Encode, ?CMDSID, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CONNECT, {1})),
	{noreply, State};

stream_message(accept_connection, _Stream, #{encode := Encode} = State) ->
	lager:debug("stream_message: accept_connection"),
	rtmp_encode:send_message(Encode, ?CMDSID, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE),
	rtmp_encode:send_message(Encode, ?CMDSID, ?RTMP_CMD_PCM_SET_PEER_BANDWIDTH),
	{noreply, State#{connected => true}};

stream_message(reject_connection, _Stream, State) ->
	lager:debug("stream_message: reject_connection"),
	{stop, normal, State};

stream_message({accept_publish, Publish}, #{sid := SID, name := Name, gsid := GSID} = Stream, #{encode := Encode} = State) ->
	lager:debug("stream_message: accept_publish for StreamName: ~p", [Name]),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_START, {Name, GSID})),
	Ref = erlang:monitor(process, Publish),
	{noreply, save_stream(Stream#{publish => Publish, monref => Ref}, State)};

stream_message(reject_publish, #{sid := SID, name := Name, gsid := GSID}, #{encode := Encode} = State) -> 
	lager:debug("stream_message: reject_publish for StreamName: ~p", [Name]),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_BADNAME, {Name, GSID})),
	{noreply, State};

stream_message(accept_play, #{sid := SID, name := Name, gsid := GSID} = Stream, #{encode := Encode} = State) ->
	lager:debug("stream_message: accept_play for StreamName: ~p", [Name]),
	rtmp_encode:send_message(Encode, ?CMDSID, ?RTMP_CMD_UCM_STREAM_BEGIN(SID)),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_RESET, {Name, GSID})),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_START, {Name, GSID})),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_RTMPSAMPLEACCESS, nothing)),
	{noreply, save_stream(Stream#{play => true}, State)};

stream_message(reject_play, #{sid := SID, name := Name, gsid := GSID}, #{encode := Encode} = State) ->
	lager:debug("stream_message: reject_play for StreamName: ~p", [Name]),
	rtmp_encode:send_message(Encode, SID, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_FAILED, {Name, GSID})),
	{noreply, State};

stream_message({publish, Message}, #{publish := Publish}, State) when Publish /= undefined ->
	Publish ! Message,
	{noreply, State};

stream_message({publish, _}, _Stream, State) ->
	{noreply, State};

stream_message({data, Data, Type}, #{sid := SID}, #{encode := Encode} = State) ->
	% lager:debug("Play data: <<~w>>; Type: ~w", [byte_size(Data), Type]),
	rtmp_encode:send_message(Encode, SID, {Type, Data}),
	{noreply, State};

stream_message(_Message, _Stream, State) ->
	lager:debug("stream_message:~nMessage: ~p~nStream: ~p", [_Message, _Stream]),
	{noreply, State}.

%%--------------------------------------------------------------------

save_stream(#{sid := SID, ref := SREF} = Stream, #{list := List} = State) ->
	State#{list => lists:keyreplace(SID, 1, List, {SID, SREF, Stream})}.

delete_stream(#{sid := SID}, #{list := List} = State) ->
	State#{list => lists:keydelete(SID, 1, List)}.

%%--------------------------------------------------------------------

init_map(Values, Map) ->
	maps:fold(fun(K, V, M) -> case maps:is_key(K, M) of true -> maps:put(K, V, M); false -> M end end, Map, Values).
	