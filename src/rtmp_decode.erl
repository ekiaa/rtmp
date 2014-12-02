%%====================================================================
%%% Description : RTMP connection
%%====================================================================

-module(rtmp_decode).
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

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
		decode_state => bh,
		chunk_stream => undefined,
		buffer       => <<>>
	}).

-define(CHUNK_STREAM_STATE,
	#{
		stream   => undefined, 
		sid      => undefined, 
		csid     => undefined, 
		ts       => undefined, 
		tsd      => undefined, 
		len      => 0, 
		type     => undefined, 
		ref      => undefined, 
		received => 0, 
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
	lager:debug("Start rtmp_decode; Channel: ~p; Socket: ~p", [Channel, Socket]),
	erlang:monitor(process, Channel),
	gen_server:cast(self(), recv),
	State = ?DECODE_STATE,
	{ok, State#{channel => Channel, socket => Socket, encrypted => Encrypted, keyin => KeyIn}};

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

handle_cast(recv, #{socket := Socket} = State) ->	
	case gen_tcp:recv(Socket, 0, 5000) of
		{ok, Data} ->
			case decode(Data, ackwinsize(State, byte_size(Data))) of
				{ok, NewState} ->
					gen_server:cast(self(), recv),
					{noreply, NewState};
				{error, Reason} ->
					lager:error("handle_cast: decode error:~n~p", [Reason]),
					{stop, {error, Reason}, State}
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
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, State) ->
	{stop, normal, State};

handle_info(Info, State) ->
	lager:error("handle_info: nomatch Info:~n~p", [Info]),
	{stop, {error, nomatch}, State}.
	
%%--------------------------------------------------------------------
%% Description: terminate process
%%--------------------------------------------------------------------

terminate(Reason, #{socket := Socket}) ->
	catch gen_tcp:close(Socket),
	lager:debug("terminate: ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

ackwinsize(#{channel := Channel, received := Received, sended := Sended} = State, DataSize) ->
	case Received - Sended >= ?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE of
		true ->
			rtmp_channel:ackwinsize(Channel, Received),
			State#{received => Received + DataSize, sended => Received};
		false ->
			State#{received => Received + DataSize}
	end.

%%--------------------------------------------------------------------
%% Description: Decode RTMP data
%%--------------------------------------------------------------------

decode(Data, #{encrypted := Encrypted, keyin := KeyIn, decode_state := DecodeState, chunk_stream := ChunkStream, buffer := Buffer} = State) ->
	case Encrypted of
		true ->
			{NewKeyIn, Bin} = crypto:stream_encrypt(KeyIn, Data),
			decode(DecodeState, State#{keyin => NewKeyIn, chunk_stream => undefined, buffer => <<>>}, ChunkStream, <<Buffer/binary, Bin/binary>>);
		false ->
			decode(DecodeState, State#{chunk_stream => undefined, buffer => <<>>}, ChunkStream, <<Buffer/binary, Data/binary>>)
	end.

%% Basic header
decode(bh, State, CS, <<>>) 										-> {ok, State#{decode_state => bh, chunk_stream => CS, buffer => <<>>}};
decode(bh, State, CS, <<Fmt:2, 0:6, CSID:8, Buf/binary>>)			-> decode({csid, Fmt, CSID}, State, CS, Buf);
decode(bh, State, CS, <<Fmt:2, 1:6, CSID:16, Buf/binary>>)			-> decode({csid, Fmt, CSID}, State, CS, Buf);
decode(bh, State, CS, <<Fmt:2, CSID:6, Buf/binary>>) when CSID > 1	-> decode({csid, Fmt, CSID}, State, CS, Buf);
decode(bh, State, CS, Buf)											-> {ok, State#{decode_state => bh, chunk_stream => CS, buffer => Buf}};

%% Chunk stream ID
decode({csid, Fmt, CSID}, #{list := List} = State, undefined, Buf) ->
	NewCS = #{csid => CSID, ref => erlang:make_ref()},
	decode({mh, Fmt}, State#{list => [{CSID, NewCS} | List]}, NewCS, Buf);
decode({csid, Fmt, CSID}, #{list := List} = State, #{csid := CurrCSID} = CS, Buf) when CurrCSID /= CSID ->
	case lists:keyfind(CSID, 1, List) of
		false ->
			NewCS = #{csid => CSID, ref => erlang:make_ref()},
			decode({mh, Fmt}, State#{list => [{CSID, NewCS} | lists:keyreplace(CurrCSID, 1, List, {CurrCSID, CS})]}, NewCS, Buf);
		{CSID, NextCS} ->
			decode({mh, Fmt}, State#{list => lists:keyreplace(CurrCSID, 1, List, {CurrCSID, CS})}, NextCS, Buf)
	end;
decode({csid, Fmt, _CSID}, State, CS, Buf) -> 
	decode({mh, Fmt}, State, CS, Buf);
	
%% Message header
decode({mh, 0}, State, CS, <<Ts:24,  Len:24, Type:8, Sid:8, _Bin:24, Buf/binary>>)	-> decode(cpl, State, CS#{ts  => Ts,  len => Len, type => Type, sid => Sid}, Buf);
decode({mh, 1}, State, CS, <<Tsd:24, Len:24, Type:8, Buf/binary>>)					-> decode(cpl, State, CS#{tsd => Tsd, len => Len, type => Type}, Buf);
decode({mh, 2}, State, CS, <<Tsd:24, Buf/binary>>)									-> decode(cpl, State, CS#{tsd => Tsd}, Buf);
decode({mh, 3}, State, CS, <<>>)													-> {ok, State#{decode_state => {mh, 3}, chunk_stream => CS, buffer => <<>>}};
decode({mh, 3}, State, CS, Buf)														-> decode(cpl, State, CS, Buf);
decode({mh, Fmt}, State, CS, Buf)													-> {ok, State#{decode_state => {mh, Fmt}, chunk_stream => CS, buffer => Buf}};

%% Chunk payload
decode(cpl, State, #{data := Data, len := Len, received := Received, csize := CSize} = CS, Buf) when Len - Received > CSize ->
	case CSize =< byte_size(Buf) of
		true ->
			{Payload, Rest} = split_binary(Buf, CSize),
			decode(bh, State, CS#{received => Received + CSize, data => <<Data/binary, Payload/binary>>}, Rest);
		false -> 
			{ok, State#{decode_state => cpl, chunk_stream => CS, buffer => Buf}}
	end;
decode(cpl, State, #{data := Data, len := Len, received := Received} = CS, Buf) ->
	RestLen = Len - Received,
	case RestLen =< byte_size(Buf) of
		true ->
			{Payload, Rest} = split_binary(Buf, RestLen),
			decode(md, State, CS#{received => 0, data => <<Data/binary, Payload/binary>>}, Rest);
		false ->
			{ok, State#{decode_state => cpl, chunk_stream => CS, buffer => Buf}}
	end;

%% Message data
decode(md, State, #{data := Data, type := Type} = CS, Buf) ->
	case Type of
		?RTMP_MSG_COMMAND_AMF0 ->
			Msg = amf0:decode_args(Data),
			decode(send, State, CS#{data => <<>>}, Buf, {command, Msg});
		?RTMP_MSG_COMMAND_AMF3 ->
			<<AmfType:8, Bin/binary>> = Data,
			Msg = case AmfType of
				0 -> amf0:decode_args(Bin);
				3 -> amf:decode(3, Bin);
				Code ->
					lager:error("decode: nomatch type code for AMF3 command: ~p; Chunk stream:~n~p", [Code, CS]),
					{error, nomatch}
			end,
			decode(send, State, CS#{data => <<>>}, Buf, {command, Msg});
		?RTMP_PCM_USER_CONTROL_MESSAGE ->
			<<EventType:16, EventData/binary>> = Data,
			case EventType of
				?RTMP_UCM_STREAM_BEGIN ->
					<<StreamID:32>> = EventData,
					decode(send, State, CS#{data => <<>>}, Buf, {user_control_message, stream_begin, StreamID});
				?RTMP_UCM_STREAM_EOF ->
					<<StreamID:32>> = EventData,
					decode(send, State, CS#{data => <<>>}, Buf, {user_control_message, stream_eof, StreamID});
				?RTMP_UCM_STREAM_IS_RECORDED ->
					<<StreamID:32>> = EventData,
					decode(send, State, CS#{data => <<>>}, Buf, {user_control_message, stream_is_recorded, StreamID});
				?RTMP_UCM_SET_BUFFER_LENGTH ->
					<<StreamID:32, BufferLength:32>> = EventData,
					decode(send, State, CS#{data => <<>>}, Buf, {user_control_message, set_buffer_length, StreamID, BufferLength})
			end;
		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
			<<Size:32>> = Data,
			decode(send, State, CS#{data => <<>>}, Buf, {asknowledgement_window_size, Size});
		?RTMP_PCM_ACKNOWLEDGEMENT ->
			<<Size:32>> = Data,
			decode(send, State, CS#{data => <<>>}, Buf, {asknowledgement, Size});
		?RTMP_MSG_AUDIO ->
			decode(send, State, CS#{data => <<>>}, Buf, {publish, {data, Data, ?RTMP_MSG_AUDIO}});
		?RTMP_MSG_VIDEO ->
			decode(send, State, CS#{data => <<>>}, Buf, {publish, {data, Data, ?RTMP_MSG_VIDEO}});
		ANY_TYPE ->
			?LOG(?MODULE, self(), "Unknown type number: ~w", [ANY_TYPE]),
			{ok, State#{chunk_stream => CS, buffer => Buf}}
	end.
	
%% Send message to channel
decode(send, #{channel := Channel} = State, #{sid := SID} = CS, Buf, Message) ->
	rtmp_channel:message(Channel, SID, Message),
	decode(bh, State, CS, Buf).