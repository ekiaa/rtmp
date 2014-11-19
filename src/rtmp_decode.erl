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

%% State record
-record(state, {
	socket, %version, client_type, 
	channel,
	publish,
	encrypted,
	keyin, %keyout, 
	% decode, % must deleted
	received = 0, sended = 0, 
	lref = 0, 
	list = [],
	csid = 2, 
	ackwinsize = ?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE,
	decode_state = bh,
	chunk_stream,
	buffer = <<>>}).

% received: length of received data from client
% sended: received value sended to client

-record(cs, {stream, sid, csid, ts, tsd, len=0, type, ref, 
	received = 0, 
	csize = ?RTMP_CONST_CHUNK_SIZE, 
	data = <<>>}).
-define(CS, CS#cs). %{}

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
	{ok, #state{channel = Channel, socket = Socket, encrypted = Encrypted, keyin = KeyIn}};

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

handle_cast(recv, State) ->	
	case gen_tcp:recv(?State.socket, 0, 1000) of
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
			lager:debug("handle_cast: socket ~p closed", [?State.socket]),
			{stop, normal, State};
		{error, Reason} ->
			lager:error("handle_cast: gen_tcp:recv() error:~n~p", [Reason]),
			{stop, {error, Reason}, State}
	end;

handle_cast({setAckWinSize, AckWinSize}, State) ->
	{noreply, ?State{ackwinsize = AckWinSize}};

handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p~nState: ~p", [Msg, State]),
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
%% Description: terminate process
%%--------------------------------------------------------------------

terminate(Reason, State) ->
	catch gen_tcp:close(?State.socket),
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

ackwinsize(State, DataSize) ->
	case ?State.received - ?State.sended >= ?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE of
		true ->
			rtmp_channel:ackwinsize(?State.channel, ?State.received),
			?State{received =  ?State.received + DataSize, sended = ?State.received};
		false ->
			?State{received =  ?State.received + DataSize}
	end.

%%--------------------------------------------------------------------
%% Description: Decode RTMP data
%%--------------------------------------------------------------------

decode(Data, State) ->
	case ?State.encrypted of
		true ->
			{NewKeyIn, Bin} = crypto:rc4_encrypt_with_state(?State.keyin, Data),
			decode(?State.decode_state, ?State{received = ?State.received + byte_size(Data), keyin = NewKeyIn, chunk_stream = undefined, buffer = <<>>}, ?State.chunk_stream, <<(?State.buffer)/binary, Bin/binary>>);
		false ->
			decode(?State.decode_state, ?State{received = ?State.received + byte_size(Data), chunk_stream = undefined, buffer = <<>>}, ?State.chunk_stream, <<(?State.buffer)/binary, Data/binary>>)
	end.

%% Basic header
decode(bh, State, CS, <<>>) 										-> {ok, ?State{decode_state = bh, chunk_stream = CS, buffer = <<>>}};
decode(bh, State, CS, <<Fmt:2, 0:6, CSID:8, Buf/binary>>)			-> decode({csid, Fmt, CSID}, State, CS, Buf);
decode(bh, State, CS, <<Fmt:2, 1:6, CSID:16, Buf/binary>>)			-> decode({csid, Fmt, CSID}, State, CS, Buf);
decode(bh, State, CS, <<Fmt:2, CSID:6, Buf/binary>>) when CSID > 1	-> decode({csid, Fmt, CSID}, State, CS, Buf);
decode(bh, State, CS, Buf)											-> {ok, ?State{decode_state = bh, chunk_stream = CS, buffer = Buf}};

%% Chunk stream ID
decode({csid, Fmt, CSID}, State, undefined, Buf) ->
	NewCS = #cs{csid = CSID, ref = erlang:make_ref()},
	decode({mh, Fmt}, ?State{list = [NewCS | ?State.list]}, NewCS, Buf);
decode({csid, Fmt, CSID}, State, CS, Buf) when ?CS.csid /= CSID ->
	case lists:keyfind(CSID, 4, ?State.list) of
		false ->
			NewCS = #cs{csid = CSID, ref = erlang:make_ref()},
			List = lists:keyreplace(?CS.csid, 4, ?State.list, CS),
			decode({mh, Fmt}, ?State{list = [NewCS | List]}, NewCS, Buf);
		NextCS ->
			List = lists:keyreplace(?CS.csid, 4, ?State.list, CS),
			decode({mh, Fmt}, ?State{list = List}, NextCS, Buf)
	end;
decode({csid, Fmt, _CSID}, State, CS, Buf) -> 
	decode({mh, Fmt}, State, CS, Buf);
	
%% Message header
decode({mh, 0}, State, CS, <<Ts:24, Len:24, Type:8, Sid:8, _Bin:24, Buf/binary>>)	-> decode(cpl, State, ?CS{ts=Ts,   len=Len, type=Type, sid=Sid}, Buf);
decode({mh, 1}, State, CS, <<Tsd:24, Len:24, Type:8, Buf/binary>>)					-> decode(cpl, State, ?CS{tsd=Tsd, len=Len, type=Type}, Buf);
decode({mh, 2}, State, CS, <<Tsd:24, Buf/binary>>)									-> decode(cpl, State, ?CS{tsd=Tsd}, Buf);
decode({mh, 3}, State, CS, <<>>)													-> {ok, ?State{decode_state = {mh, 3}, chunk_stream = CS, buffer = <<>>}};
decode({mh, 3}, State, CS, Buf)														-> decode(cpl, State, CS, Buf);
decode({mh, Fmt}, State, CS, Buf)													-> {ok, ?State{decode_state = {mh, Fmt}, chunk_stream = CS, buffer = Buf}};

%% Chunk payload
decode(cpl, State, CS, Buf) when ?CS.len - ?CS.received > ?CS.csize ->
	case ?CS.csize =< byte_size(Buf) of
		true ->
			{Payload, Rest} = split_binary(Buf, ?CS.csize),
			decode(bh, State, ?CS{received = ?CS.received + ?CS.csize, data = <<(?CS.data)/binary, Payload/binary>>}, Rest);
		false -> 
			{ok, ?State{decode_state = cpl, chunk_stream = CS, buffer = Buf}}
	end;
decode(cpl, State, CS, Buf) ->
	Len = ?CS.len - ?CS.received,
	case Len =< byte_size(Buf) of
		true ->
			{Payload, Rest} = split_binary(Buf, Len),
			decode(md, State, ?CS{received = 0, data = <<(?CS.data)/binary, Payload/binary>>}, Rest);
		false ->
			{ok, ?State{decode_state = cpl, chunk_stream = CS, buffer = Buf}}
	end;

%% Message data
decode(md, State, CS, Buf) ->
	case ?CS.type of
		?RTMP_MSG_COMMAND_AMF0 ->
			Msg = amf0:decode_args(?CS.data),
			decode(send, State, ?CS{data = <<>>}, Buf, {command, Msg});
		?RTMP_MSG_COMMAND_AMF3 ->
			<<Type:8, Data/binary>> = ?CS.data,
			Msg = case Type of
				0 -> amf0:decode_args(Data);
				3 -> amf:decode(3, Data);
				Code ->
					lager:error("decode: nomatch type code for AMF3 command: ~p; Chunk stream:~n~p", [Code, CS]),
					{error, nomatch}
			end,
			decode(send, State, ?CS{data = <<>>}, Buf, {command, Msg});
		?RTMP_PCM_USER_CONTROL_MESSAGE ->
			<<EventType:16, EventData/binary>> = ?CS.data,
			case EventType of
				?RTMP_UCM_STREAM_BEGIN ->
					<<StreamID:32>> = EventData,
					decode(send, State, ?CS{data = <<>>}, Buf, {user_control_message, stream_begin, StreamID});
				?RTMP_UCM_STREAM_EOF ->
					<<StreamID:32>> = EventData,
					decode(send, State, ?CS{data = <<>>}, Buf, {user_control_message, stream_eof, StreamID});
				?RTMP_UCM_STREAM_IS_RECORDED ->
					<<StreamID:32>> = EventData,
					decode(send, State, ?CS{data = <<>>}, Buf, {user_control_message, stream_is_recorded, StreamID});
				?RTMP_UCM_SET_BUFFER_LENGTH ->
					<<StreamID:32, BufferLength:32>> = EventData,
					decode(send, State, ?CS{data = <<>>}, Buf, {user_control_message, set_buffer_length, StreamID, BufferLength})
			end;
		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
			<<Size:32>> = ?CS.data,
			decode(send, State, ?CS{data = <<>>}, Buf, {asknowledgement_window_size, Size});
		?RTMP_PCM_ACKNOWLEDGEMENT ->
			<<Size:32>> = ?CS.data,
			decode(send, State, ?CS{data = <<>>}, Buf, {asknowledgement, Size});
		?RTMP_MSG_AUDIO ->
			decode(send, State, ?CS{data = <<>>}, Buf, {publish, {data, ?CS.data, ?RTMP_MSG_AUDIO}});
		?RTMP_MSG_VIDEO ->
			decode(send, State, ?CS{data = <<>>}, Buf, {publish, {data, ?CS.data, ?RTMP_MSG_VIDEO}});
		ANY_TYPE ->
			?LOG(?MODULE, self(), "Unknown type number: ~w", [ANY_TYPE]),
			{ok, ?State{chunk_stream = CS, buffer = Buf}}
	end.
	
%% Send message to channel
decode(send, State, CS, Buf, Message) ->
	rtmp_channel:message(?State.channel, ?CS.sid, Message),
	decode(bh, State, CS, Buf).