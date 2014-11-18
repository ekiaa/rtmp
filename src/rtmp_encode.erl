%%====================================================================
%% Description : Encode RTMP data
%%====================================================================

-module(rtmp_encode).
-copyright("LiveTex").
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions
-export([start/4, start_link/4, send_message/3, create_stream/2]).
-export([wait_mainframe/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record
-record(state, {channel, socket, keyout, encrypted = false, csid=3, csize = ?RTMP_CONST_CHUNK_SIZE, list = []}).

%% Chunk stream record
-record(stream, {id, sid, csid, csid_bin, type = 0, len = 0, fts, ts, tsd = 0}).
-define(Stream, Stream#stream). %{}

%%====================================================================
%% API functions
%%====================================================================

start(Channel, Socket, Encrypted, KeyOut) ->
	rtmp_encode_sup:start_encode([Channel, Socket, Encrypted, KeyOut]).
	
start_link(Channel, Socket, Encrypted, KeyOut) ->
	gen_server:start_link(?MODULE, {Channel, Socket, Encrypted, KeyOut}, []).

% send_by_cmd(Encode, Message) ->
% 	gen_server:cast(Encode, {send_message, cmd, Message}).

% send_by_amf(Encode, Message) ->
% 	gen_server:cast(Encode, {send_message, amf, Message}).

create_stream(Encode, StreamID) ->
	gen_server:cast(Encode, {create_stream, StreamID}).

send_message(Encode, StreamID, Message) ->
	gen_server:cast(Encode, {send_message, StreamID, Message}).	

%%--------------------------------------------------------------------
	
% send(Encode, Msg) ->
% 	gen_server:cast(Encode, {send, Msg}).
	
wait_mainframe(Encode) ->
	gen_server:cast(Encode, wait_mainframe).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init({Channel, Socket, Encrypted, KeyOut}) ->
	lager:debug("Start rtmp_encode; Channel: ~p; Socket: ~p", [Channel, Socket]),
	erlang:monitor(process, Channel),
	% CmdStream = #stream{id = cmd, csid = 2, sid = 0},
	% AmfStream = #stream{id = amf, csid = 3, sid = 0},
	% List = [CmdStream, AmfStream],
	% HID = SID * 16#1000000,
	{ok, #state{socket = Socket, channel = Channel, encrypted = Encrypted, keyout = KeyOut}};
	
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

handle_cast({send_message, StreamID, Message}, State) ->
	case lists:keyfind(StreamID, 2, ?State.list) of
		false ->
			lager:error("send_message: nomatch StreamID: ~p", [StreamID]),
			{stop, {error, nomatch}, State};
		Stream ->
			case start_encode(Message, Stream, State) of
				{ok, NewState} ->
					{noreply, NewState};
				{error, Reason} ->
					lager:error("send_message error:~n~p", [Reason]),
					{stop, {error, Reason}, State}
			end
	end;

handle_cast({create_stream, StreamID}, State) ->
	Stream = #stream{id = StreamID, sid = StreamID * 16#1000000, csid = ?State.csid},
	lager:debug("create_stream: ~p", [Stream]),
	{noreply, ?State{list = [Stream | ?State.list], csid = ?State.csid + 1}};

%%--------------------------------------------------------------------

handle_cast(wait_mainframe, S) ->
	{noreply, S};

% handle_cast({send, Msg}, S) when S#state.fts == undefined ->
% 	encode(type, S#state{fts = erlang:now()}, Msg);

% handle_cast({send, Msg}, S) ->
% 	encode(type, S, Msg);

handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p", [Msg]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%-----------------------------------------Z--------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, State) ->
	{stop, normal, State};

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

% send_message(Message, Stream, State) ->
% 	case encode(type, Stream, State, Message) of
% 		{ok, {NewStream, NewState}} ->
% 			{ok, NewState#state{list = lists:keyreplace(NewStream#stream.id, 2, NewState#state.list)}};
% 		{error, Reason} ->
% 			{error, Reason}
% 	end.

start_encode({Type, Message}, Stream, State) when ?Stream.fts == undefined ->
	encode({type, Type, Message}, ?Stream{fts = erlang:now()}, State);

start_encode({Type, Message}, Stream, State) ->
	encode({type, Type, Message}, Stream, State).

encode({type, Type, Msg}, Stream, State) ->
	case Type of
		?RTMP_PCM_SET_CHUNK_SIZE ->
			encode({fmt_0, Type, 4, <<Msg:32>>}, ?Stream{csid_bin = <<2:6>>}, State);
		?RTMP_PCM_ACKNOWLEDGEMENT ->
			encode({fmt_0, Type, 4, <<Msg:32>>}, ?Stream{csid_bin = <<2:6>>}, State);
		?RTMP_PCM_USER_CONTROL_MESSAGE ->
			case Msg of
				{?RTMP_UCM_SET_BUFFER_LENGTH, {StreamId, BufferLength}} ->
					encode({fmt_0, Type, 10, <<?RTMP_UCM_SET_BUFFER_LENGTH:16, StreamId:32, BufferLength:32>>}, ?Stream{csid_bin = <<2:6>>}, State);
				{EventType, EventData} ->
					encode({fmt_0, Type, 6, <<EventType:16, EventData:32>>}, ?Stream{csid_bin = <<2:6>>}, State)
			end;
		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
			encode({fmt_0, Type, 4, <<Msg:32>>}, ?Stream{csid_bin = <<2:6>>}, State);
		?RTMP_PCM_SET_PEER_BANDWIDTH ->
			{Size, LimitType} = Msg,
			encode({fmt_0, Type, 5, <<Size:32, LimitType:8>>}, ?Stream{csid_bin = <<2:6>>}, State);
		?RTMP_MSG_AUDIO ->
			encode({msghead, Type, byte_size(Msg), Msg}, ?Stream{csid_bin = <<(?Stream.csid):6>>}, State);
		?RTMP_MSG_VIDEO ->
			encode({msghead, Type, byte_size(Msg), Msg}, ?Stream{csid_bin = <<(?Stream.csid):6>>}, State);
		?RTMP_MSG_DATA_AMF0 ->
			Bin = amf0:encode_args(Msg),
			encode({msghead, Type, byte_size(Bin), Bin}, ?Stream{csid_bin = <<(?Stream.csid):6>>}, State);
		?RTMP_MSG_COMMAND_AMF0 ->
			Bin = amf0:encode_args(Msg),
			encode({fmt_0, Type, byte_size(Bin), Bin}, ?Stream{csid_bin = <<3:6>>}, State);
		?RTMP_MSG_COMMAND_AMF3 ->
			Bin = <<0:8, (amf0:encode_args(Msg))/binary>>,
			encode({fmt_0, Type, byte_size(Bin), Bin}, ?Stream{csid_bin = <<3:6>>}, State);
		Type ->
			lager:error("encode: nomatch Type: ~p", [Type]),
			{error, nomatch}
	end;

encode({msghead, Type, Len, Bin}, Stream, State) when ?Stream.type == Type, ?Stream.len == Len -> % fmt == 2
	{Ts, Tsd} = get_timestamp_diff(?Stream.ts),
	encode({chunk, <<2:2, (?Stream.csid_bin)/bitstring, Tsd:24>>, Bin, <<>>}, ?Stream{ts = Ts}, State);

encode({msghead, Type, Len, Bin}, Stream, State) when ?Stream.type == Type -> %fmt == 1
	{Ts, Tsd} = get_timestamp_diff(?Stream.ts),
	encode({chunk, <<1:2, (?Stream.csid_bin)/bitstring, Tsd:24, Len:24, Type:8>>, Bin, <<>>}, ?Stream{ts = Ts, len = Len}, State);

encode({msghead, Type, Len, Bin}, Stream, State) ->
	encode({msghead, Type, Bin}, ?Stream{type = Type, len = Len}, State);

	% case Type of
	% 	?RTMP_MSG_AUDIO ->
	% 		encode({msghead, Type, Bin}, ?Stream{type = Type, len = Len}, State);
	% 	?RTMP_MSG_VIDEO ->
	% 		encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
	% 	?RTMP_MSG_DATA_AMF0 ->
	% 		encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
	% 	?RTMP_MSG_COMMAND_AMF0 ->
	% 		encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
	% 	_CMD ->
	% 		encode(msghead, S#state{len = Len}, {Type, Bin})
	% end;

encode({msghead, Type, Bin}, Stream, State) -> % fmt == 0
	{Ts, Tsd} = get_timestamp_diff(?Stream.fts),
	encode({chunk, <<0:2, (?Stream.csid_bin)/bitstring, Tsd:24, (?Stream.len):24, Type:8, (?Stream.sid):32>>, Bin, <<>>}, ?Stream{ts = Ts}, State);

encode({fmt_0, Type, Len, Bin}, Stream, State) ->
	% {Ts, Tsd} = get_timestamp_diff(?Stream.fts),
	encode({chunk, <<0:2, (?Stream.csid_bin)/bitstring, 0:24, Len:24, Type:8, (?Stream.sid):32>>, Bin, <<>>}, ?Stream{len = Len}, State);

encode({chunk, Head, Bin, Buf}, Stream, State) ->
	case byte_size(Bin) > ?State.csize of
		true ->
			{Payload, Rest} = split_binary(Bin, ?State.csize),
			encode({chunk, <<3:2, (?Stream.csid_bin)/bitstring>>, Rest, <<Buf/binary, Head/binary, Payload/binary>>}, Stream, State);
		false ->
			encode({crypt, <<Buf/binary, Head/binary, Bin/binary>>}, Stream, State)
	end;

encode({crypt, Buf}, Stream, State) ->
	case ?State.encrypted of
		true ->
			{KeyOut, EncryptedData} = crypto:rc4_encrypt_with_state(?State.keyout, Buf),
			encode({send, EncryptedData}, Stream, ?State{keyout = KeyOut});
		false ->
			encode({send, Buf}, Stream, State)
	end;

encode({send, Data}, Stream, State) ->
	case gen_tcp:send(?State.socket, Data) of
		ok ->
			{ok, ?State{list = lists:keyreplace(?Stream.id, 2, ?State.list, Stream)}};
		{error, Reason} ->
			lager:error("encode: gen_tcp:send() error:~n~p", [Reason]),
			{error, Reason}
	end.

get_timestamp_diff(Ts1) ->
	Ts2 = now(),
	{Ts2, round(timer:now_diff(Ts2, Ts1)/1000)}.
