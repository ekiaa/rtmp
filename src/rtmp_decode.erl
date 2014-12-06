%%====================================================================
%%% Description : RTMP decode 
%%====================================================================

-module(rtmp_decode).

-author("Artem Ekimov <ekimov-artem@ya.ru>").

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions
-export([start/4, start_link/4, setAckWinSize/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DECODE_STATE, 
	#{
		socket       => undefined,
		channel      => undefined,
		publish      => undefined,
		encrypted    => undefined,
		keyin        => undefined,
		received     => 0, 
		sended       => 0, 
		lref         => 0, 
		list         => [],
		csid         => 2, 
		ackwinsize   => ?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE,
		decode_func  => decode_basic_header,
		chunk_stream => undefined,
		buffer       => <<>>
	}).

-define(CHUNK_STREAM_STATE(CSID, REF),
	#{
		stream   => undefined, 
		sid      => undefined, 
		csid     => CSID, 
		ts       => undefined, 
		tsd      => undefined, 
		len      => 0, 
		type     => undefined, 
		ref      => REF, 
		received => 0, 
		bufsize  => 0,
		csize    => ?RTMP_CONST_CHUNK_SIZE, 
		data     => <<>>
	}).

%%====================================================================
%% API
%%====================================================================

start(Channel, Socket, Encrypted, KeyIn) ->
	rtmp_decode_sup:start_decode([Channel, Socket, Encrypted, KeyIn]).
	
start_link(Channel, Socket, Encrypted, KeyIn) ->
	gen_server:start_link(?MODULE, {Channel, Socket, Encrypted, KeyIn}, []).

setAckWinSize(Decode, AckWinSize) ->
	gen_server:cast(Decode, {setAckWinSize, AckWinSize}).
	
%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init({Channel, Socket, Encrypted, KeyIn}) ->
	% Res = eprof:start_profiling([self()]),
	% lager:debug("eprof:start_profiling(~p) return: ~p", [self(), Res]),
	lager:debug("Start rtmp_decode; Channel: ~p; Socket: ~p", [Channel, Socket]),
	erlang:monitor(process, Channel),
	gen_server:cast(self(), recv),
	State = ?DECODE_STATE,
	{ok, State#{channel => Channel, socket => Socket, encrypted => Encrypted, keyin => KeyIn}};

init(Args) ->
	lager:error("init: nomatch Args:~n~p", [Args]),
	{stop, {error, nomatch}}.
	
%%--------------------------------------------------------------------

handle_call(Request, _From, State) ->
	lager:error("handle_call: nomatch Request:~n~p", [Request]),
	Error = {error, nomatch},
	{stop, Error, Error, State}.
	
%%--------------------------------------------------------------------

handle_cast(recv, #{socket := Socket, channel := Channel, received := Received, sended := Sended} = State) ->	
	case gen_tcp:recv(Socket, 0, 5000) of
		{ok, Data} ->
			gen_server:cast(self(), recv),
			case Received - Sended >= ?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE of
				true ->
					rtmp_channel:ackwinsize(Channel, Received),
					decode(State#{received => Received + byte_size(Data), sended => Received}, Data);
				false ->
					decode(State#{received => Received + byte_size(Data)}, Data)
			end;
		{error, timeout} ->
			gen_server:cast(self(), recv),
			{noreply, State};
		{error, closed} ->
			lager:debug("handle_cast: socket ~p closed", [Socket]),
			{stop, normal, State};
		{error, Reason} ->
			lager:error("handle_cast: gen_tcp:recv() error:~n~p", [Reason]),
			{stop, {error, Reason}, State}
	end;

handle_cast({setAckWinSize, AckWinSize}, State) ->
	{noreply, State#{ackwinsize => AckWinSize}};

handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p~nState: ~p", [Msg, State]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, State) ->
	{stop, normal, State};

handle_info(Info, State) ->
	lager:error("handle_info: nomatch Info:~n~p", [Info]),
	{stop, {error, nomatch}, State}.
	
%%--------------------------------------------------------------------

terminate(Reason, #{socket := Socket}) ->
	% Res = eprof:stop_profiling(),
	% lager:debug("eprof:stop_profiling() return: ~p", [Res]),
	catch gen_tcp:close(Socket),
	lager:debug("terminate: ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

decode(#{encrypted := Encrypted, keyin := KeyIn, chunk_stream := CS, buffer := Buffer} = State, Data) ->
	case Encrypted of
		true ->
			{NewKeyIn, Bin} = crypto:stream_encrypt(KeyIn, Data),
			decode(State#{keyin => NewKeyIn, chunk_stream => undefined, buffer => <<>>}, CS, <<Buffer/binary, Bin/binary>>);
		false ->
			decode(State#{chunk_stream => undefined, buffer => <<>>}, CS, <<Buffer/binary, Data/binary>>)
	end.

decode(#{decode_func := Function} = State, CS, Buf) ->
	case Function of
		decode_basic_header -> decode_basic_header(State, CS, Buf);
		decode_chunk_stream_id -> decode_chunk_stream_id(State, CS, Buf);
		decode_message_header -> decode_message_header(State, CS, Buf);
		decode_chunk_payload -> decode_chunk_payload(State, CS, Buf)
	end.

decode_basic_header(State, CS, <<>>) 										-> {noreply, State#{decode_func => decode_basic_header, chunk_stream => CS, buffer => <<>>}};
decode_basic_header(State, CS, <<Fmt:2, 0:6, CSID:8, Buf/binary>>)			-> decode_chunk_stream_id(State#{rfmt => Fmt, rcsid => CSID}, CS, Buf);
decode_basic_header(State, CS, <<Fmt:2, 1:6, CSID:16, Buf/binary>>)			-> decode_chunk_stream_id(State#{rfmt => Fmt, rcsid => CSID}, CS, Buf);
decode_basic_header(State, CS, <<Fmt:2, CSID:6, Buf/binary>>) when CSID > 1	-> decode_chunk_stream_id(State#{rfmt => Fmt, rcsid => CSID}, CS, Buf);
decode_basic_header(State, CS, Buf)											-> {noreply, State#{decode_func => decode_basic_header, chunk_stream => CS, buffer => Buf}}.

decode_chunk_stream_id(#{list := List, rcsid := CSID} = State, undefined, Buf) ->
	NewCS = ?CHUNK_STREAM_STATE(CSID, erlang:make_ref()),
	decode_message_header(State#{list => [{CSID, NewCS} | List]}, NewCS, Buf);
decode_chunk_stream_id(#{rcsid := CSID} = State, #{csid := CSID} = CS, Buf) -> 
	decode_message_header(State, CS, Buf);
decode_chunk_stream_id(#{list := List, rcsid := RCSID} = State, #{csid := CSID} = CS, Buf) ->
	case lists:keyfind(RCSID, 1, List) of
		false ->
			NewCS = ?CHUNK_STREAM_STATE(RCSID, erlang:make_ref()),
			decode_message_header(State#{list => [{RCSID, NewCS} | lists:keyreplace(CSID, 1, List, {CSID, CS})]}, NewCS, Buf);
		{RCSID, NextCS} ->
			decode_message_header(State#{list => lists:keyreplace(CSID, 1, List, {CSID, CS})}, NextCS, Buf)
	end.
	
decode_message_header(#{rfmt := 0} = State, CS, <<Ts:24,  Len:24, Type:8, Sid:8, _Bin:24, Buf/binary>>)	-> decode_chunk_payload(State, CS#{ts  => Ts,  len => Len, type => Type, sid => Sid}, Buf);
decode_message_header(#{rfmt := 1} = State, CS, <<Tsd:24, Len:24, Type:8, Buf/binary>>)					-> decode_chunk_payload(State, CS#{tsd => Tsd, len => Len, type => Type}, Buf);
decode_message_header(#{rfmt := 2} = State, CS, <<Tsd:24, Buf/binary>>)									-> decode_chunk_payload(State, CS#{tsd => Tsd}, Buf);
decode_message_header(#{rfmt := 3} = State, CS, <<>>)													-> {noreply, State#{decode_func => decode_message_header, chunk_stream => CS, buffer => <<>>}};
decode_message_header(#{rfmt := 3} = State, CS, Buf)													-> decode_chunk_payload(State, CS, Buf);
decode_message_header(State, CS, Buf)																	-> {noreply, State#{decode_func => decode_message_header, chunk_stream => CS, buffer => Buf}}.

decode_chunk_payload(State, #{data := Data, len := Len, csize := CSize, received := Received} = CS, Buf) when Len - Received > CSize, CSize =< byte_size(Buf) ->
	<<Payload:CSize/binary, Rest/binary>> = Buf,
	decode_basic_header(State, CS#{received => Received + CSize, data => <<Data/binary, Payload/binary>>}, Rest);
decode_chunk_payload(State, #{data := Data, len := Len, csize := CSize, received := Received} = CS, Buf) when Len - Received =< CSize, Len - Received =< byte_size(Buf) ->
	RemLen = Len - Received,
	<<Payload:RemLen/binary, Rest/binary>> = Buf,
	decode_message_data(State, CS#{remlen => 0, received => 0, data => <<Data/binary, Payload/binary>>}, Rest);
decode_chunk_payload(State, CS, Buf) ->
	{noreply, State#{decode_func => decode_chunk_payload, chunk_stream => CS, buffer => Buf}}.

decode_message_data(State, #{data := Data, type := Type} = CS, Buf) ->
	case Type of
		?RTMP_MSG_COMMAND_AMF0 ->
			Msg = amf0:decode_args(Data),
			send_message(State, CS#{data => <<>>}, Buf, {command, Msg});
		?RTMP_MSG_COMMAND_AMF3 ->
			<<AmfType:8, Bin/binary>> = Data,
			Msg = case AmfType of
				0 -> amf0:decode_args(Bin);
				3 -> amf:decode(3, Bin);
				Code ->
					lager:error("decode: nomatch type code for AMF3 command: ~p; Chunk stream:~n~p", [Code, CS]),
					{stop, {error, nomatch}, State#{chunk_stream => CS}}
			end,
			send_message(State, CS#{data => <<>>}, Buf, {command, Msg});
		?RTMP_PCM_USER_CONTROL_MESSAGE ->
			<<EventType:16, EventData/binary>> = Data,
			case EventType of
				?RTMP_UCM_STREAM_BEGIN ->
					<<StreamID:32>> = EventData,
					send_message(State, CS#{data => <<>>}, Buf, {user_control_message, stream_begin, StreamID});
				?RTMP_UCM_STREAM_EOF ->
					<<StreamID:32>> = EventData,
					send_message(State, CS#{data => <<>>}, Buf, {user_control_message, stream_eof, StreamID});
				?RTMP_UCM_STREAM_IS_RECORDED ->
					<<StreamID:32>> = EventData,
					send_message(State, CS#{data => <<>>}, Buf, {user_control_message, stream_is_recorded, StreamID});
				?RTMP_UCM_SET_BUFFER_LENGTH ->
					<<StreamID:32, BufferLength:32>> = EventData,
					send_message(State, CS#{data => <<>>}, Buf, {user_control_message, set_buffer_length, StreamID, BufferLength})
			end;
		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
			<<Size:32>> = Data,
			send_message(State, CS#{data => <<>>}, Buf, {asknowledgement_window_size, Size});
		?RTMP_PCM_ACKNOWLEDGEMENT ->
			<<Size:32>> = Data,
			send_message(State, CS#{data => <<>>}, Buf, {asknowledgement, Size});
		?RTMP_MSG_AUDIO ->
			send_message(State, CS#{data => <<>>}, Buf, {publish, {data, Data, ?RTMP_MSG_AUDIO}});
		?RTMP_MSG_VIDEO ->
			send_message(State, CS#{data => <<>>}, Buf, {publish, {data, Data, ?RTMP_MSG_VIDEO}});
		ANY_TYPE ->
			lager:error("Unknown type number: ~p", [ANY_TYPE]),
			{stop, {error, nomatch}, State#{chunk_stream => CS, buffer => Buf}}
	end.
	
send_message(#{channel := Channel} = State, #{sid := SID} = CS, Buf, Message) ->
	rtmp_channel:message(Channel, SID, Message),
	decode_basic_header(State, CS, Buf).