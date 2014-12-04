%%====================================================================
%% Description : Encode RTMP data
%%====================================================================

-module(rtmp_encode).

-author("Artem Ekimov <ekimov-artem@ya.ru>").

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions
-export([start/4, start_link/4, send_message/3, create_stream/2]).
-export([wait_mainframe/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(ENCODE_STATE, 
	#{
		channel   => undefined,
		socket    => undefined,
		keyout    => undefined,
		encrypted => false,
		csid      => 3,
		csize     => ?RTMP_CONST_CHUNK_SIZE,
		list      => []
	}).

-define(STREAM_STATE, 
	#{
		sid      => undefined,
		csid     => undefined,
		csid_bin => undefined,
		type     => 0,
		len      => 0,
		fts      => undefined,
		ts       => undefined,
		tsd      => 0
	}).

%%====================================================================
%% API functions
%%====================================================================

start(Channel, Socket, Encrypted, KeyOut) ->
	rtmp_encode_sup:start_encode([Channel, Socket, Encrypted, KeyOut]).
	
start_link(Channel, Socket, Encrypted, KeyOut) ->
	gen_server:start_link(?MODULE, {Channel, Socket, Encrypted, KeyOut}, []).

create_stream(Encode, StreamID) ->
	gen_server:cast(Encode, {create_stream, StreamID}).

send_message(Encode, StreamID, Message) ->
	gen_server:cast(Encode, {send_message, StreamID, Message}).	

wait_mainframe(Encode) ->
	gen_server:cast(Encode, wait_mainframe).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Channel, Socket, Encrypted, KeyOut}) ->
	lager:debug("Start rtmp_encode; Channel: ~p; Socket: ~p", [Channel, Socket]),
	State = ?ENCODE_STATE,
	erlang:monitor(process, Channel),
	{ok, State#{socket => Socket, channel => Channel, encrypted => Encrypted, keyout => KeyOut}};
	
init(Args) ->
	lager:error("init: nomatch Args:~n~p", [Args]),
	{stop, {error, nomatch}}.
	
%%--------------------------------------------------------------------

handle_call(Request, _From, State) ->
	lager:error("handle_call: nomatch Request:~n~p", [Request]),
	Error = {error, nomatch},
	{stop, Error, Error, State}.
	
%%--------------------------------------------------------------------

handle_cast({send_message, StreamID, Message}, #{list := List} = State) ->
	case lists:keyfind(StreamID, 1, List) of
		false ->
			lager:error("send_message: nomatch StreamID: ~p", [StreamID]),
			{stop, {error, nomatch}, State};
		{StreamID, Stream} ->
			case start_encode(Message, Stream, State) of
				{ok, NewState} ->
					{noreply, NewState};
				{error, Reason} ->
					lager:error("send_message error:~n~p", [Reason]),
					{stop, {error, Reason}, State}
			end
	end;

handle_cast({create_stream, StreamID}, #{list := List, csid := CSID} = State) ->
	Stream = ?STREAM_STATE,
	lager:debug("create_stream: ~p", [StreamID]),
	{noreply, State#{list => [{StreamID, Stream#{sid => StreamID, csid => CSID}} | List], csid => CSID + 1}};

handle_cast(wait_mainframe, State) ->
	{noreply, State};

handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p", [Msg]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, State) ->
	{stop, normal, State};

handle_info(Info, State) ->
	lager:error("handle_info: nomatch Info:~n~p", [Info]),
	{stop, {error, nomatch}, State}.
	
%%--------------------------------------------------------------------

terminate(Reason, _State) ->
	lager:debug("terminate: ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

start_encode({Type, Message}, #{fts := undefined} = Stream, State) ->
	encode({type, Type, Message}, Stream#{fts => erlang:now()}, State);

start_encode({Type, Message}, Stream, State) ->
	encode({type, Type, Message}, Stream, State).

encode({type, Type, Msg}, #{csid := CSID} = Stream, State) ->
	case Type of
		?RTMP_PCM_SET_CHUNK_SIZE ->
			encode({fmt_0, Type, 4, <<Msg:32>>}, Stream#{csid_bin => <<2:6>>}, State);
		?RTMP_PCM_ACKNOWLEDGEMENT ->
			encode({fmt_0, Type, 4, <<Msg:32>>}, Stream#{csid_bin => <<2:6>>}, State);
		?RTMP_PCM_USER_CONTROL_MESSAGE ->
			case Msg of
				{?RTMP_UCM_SET_BUFFER_LENGTH, {StreamID, BufferLength}} ->
					encode({fmt_0, Type, 10, <<?RTMP_UCM_SET_BUFFER_LENGTH:16, StreamID:32, BufferLength:32>>}, Stream#{csid_bin => <<2:6>>}, State);
				{EventType, EventData} ->
					encode({fmt_0, Type, 6, <<EventType:16, EventData:32>>}, Stream#{csid_bin => <<2:6>>}, State)
			end;
		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
			encode({fmt_0, Type, 4, <<Msg:32>>}, Stream#{csid_bin => <<2:6>>}, State);
		?RTMP_PCM_SET_PEER_BANDWIDTH ->
			{Size, LimitType} = Msg,
			encode({fmt_0, Type, 5, <<Size:32, LimitType:8>>}, Stream#{csid_bin => <<2:6>>}, State);
		?RTMP_MSG_AUDIO ->
			encode({msghead, Type, byte_size(Msg), Msg}, Stream#{csid_bin => <<CSID:6>>}, State);
		?RTMP_MSG_VIDEO ->
			encode({msghead, Type, byte_size(Msg), Msg}, Stream#{csid_bin => <<CSID:6>>}, State);
		?RTMP_MSG_DATA_AMF0 ->
			Bin = amf0:encode_args(Msg),
			encode({msghead, Type, byte_size(Bin), Bin}, Stream#{csid_bin => <<CSID:6>>}, State);
		?RTMP_MSG_COMMAND_AMF0 ->
			Bin = amf0:encode_args(Msg),
			encode({fmt_0, Type, byte_size(Bin), Bin}, Stream#{csid_bin => <<3:6>>}, State);
		?RTMP_MSG_COMMAND_AMF3 ->
			Bin = <<0:8, (amf0:encode_args(Msg))/binary>>,
			encode({fmt_0, Type, byte_size(Bin), Bin}, Stream#{csid_bin => <<3:6>>}, State);
		Type ->
			lager:error("encode: nomatch Type: ~p", [Type]),
			{error, nomatch}
	end;

encode({msghead, Type, Len, Bin}, #{type := Type, len := Len, ts := Ts, csid_bin := CSIDBin} = Stream, State) -> % fmt == 2
	{Ts1, Tsd} = get_timestamp_diff(Ts),
	encode({chunk, <<2:2, CSIDBin/bitstring, Tsd:24>>, Bin, <<>>}, Stream#{ts => Ts1}, State);

encode({msghead, Type, Len, Bin}, #{type := Type, ts := Ts, csid_bin := CSIDBin} = Stream, State) -> %fmt == 1
	{Ts1, Tsd} = get_timestamp_diff(Ts),
	encode({chunk, <<1:2, CSIDBin/bitstring, Tsd:24, Len:24, Type:8>>, Bin, <<>>}, Stream#{ts => Ts1, len => Len}, State);

encode({msghead, Type, Len, Bin}, Stream, State) ->
	encode({msghead, Type, Bin}, Stream#{type => Type, len => Len}, State);

encode({msghead, Type, Bin}, #{sid := SID, fts := Fts, len := Len, csid_bin := CSIDBin} = Stream, State) -> % fmt == 0
	{Ts, Tsd} = get_timestamp_diff(Fts),
	encode({chunk, <<0:2, CSIDBin/bitstring, Tsd:24, Len:24, Type:8, (SID * 16#1000000):32>>, Bin, <<>>}, Stream#{ts => Ts}, State);

encode({fmt_0, Type, Len, Bin}, #{sid := SID, csid_bin := CSIDBin} =  Stream, State) ->
	encode({chunk, <<0:2, CSIDBin/bitstring, 0:24, Len:24, Type:8, (SID * 16#1000000):32>>, Bin, <<>>}, Stream#{len => Len}, State);

encode({chunk, Head, Bin, Buf}, #{csid_bin := CSIDBin} = Stream, #{csize := CSize} = State) ->
	case byte_size(Bin) > CSize of
		true ->
			{Payload, Rest} = split_binary(Bin, CSize),
			encode({chunk, <<3:2, CSIDBin/bitstring>>, Rest, <<Buf/binary, Head/binary, Payload/binary>>}, Stream, State);
		false ->
			encode({crypt, <<Buf/binary, Head/binary, Bin/binary>>}, Stream, State)
	end;

encode({crypt, Buf}, Stream, #{encrypted := Encrypted, keyout := KeyOut} = State) ->
	case Encrypted of
		true ->
			{KeyOut1, EncryptedData} = crypto:stream_encrypt(KeyOut, Buf),
			encode({send, EncryptedData}, Stream, State#{keyout => KeyOut1});
		false ->
			encode({send, Buf}, Stream, State)
	end;

encode({send, Data}, #{sid := StreamID} = Stream, #{socket := Socket, list := List} = State) ->
	case gen_tcp:send(Socket, Data) of
		ok ->
			{ok, State#{list => lists:keyreplace(StreamID, 1, List, {StreamID, Stream})}};
		{error, Reason} ->
			lager:error("encode: gen_tcp:send() error:~n~p", [Reason]),
			{error, Reason}
	end.

get_timestamp_diff(Ts1) ->
	Ts2 = now(),
	{Ts2, round(timer:now_diff(Ts2, Ts1)/1000)}.
