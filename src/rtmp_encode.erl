%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp_encode.erl
%%% Author      : Ekimov Artem <ekimov-artem@ya.ru>
%%% Description : RTMP encode API and callbacks
%%% Created     : 28.04.2012
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp_encode).

-author('ekimov-artem@ya.ru').

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions

-export([start/4, start_link/4, stop/1]).

-export([wait_mainframe/1, send/2]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {stream, socket, csid, sid, type = 0, len = 0, fts, ts, tsd = 0, csize = ?RTMP_CONST_CHUNK_SIZE, csidb}).

%%====================================================================
%% API
%%====================================================================

start(Stream, Socket, SID, CSID) ->
	supervisor:start_child(?ENCODE_SUP, [Stream, Socket, SID, CSID]).
	
start_link(Stream, Socket, SID, CSID) ->
	gen_server:start_link(?MODULE, {Stream, Socket, SID, CSID}, []).
	
stop(Pid) ->
	gen_server:call(Pid, stop).
	
send(Encode, Msg) ->
	gen_server:cast(Encode, {send, Msg}).
	
wait_mainframe(Encode) ->
	gen_server:cast(Encode, wait_mainframe).

%%==============================================================================================================================================
%% gen_server callbacks
%%==============================================================================================================================================

%%--------------------------------------------------------------------
%% Function:    init(Args) -> {ok, State} |
%%                            {ok, State, Timeout} |
%%                            ignore               |
%%                            {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------

init({Stream, Socket, SID, CSID}) ->
	?LOG(?MODULE, self(), "init: {~w, ~w, ~w, ~w}", [Stream, Socket, SID, CSID]),
	erlang:monitor(process, Stream),
	HID = SID * 16#1000000,
	{ok, #state{socket = Socket, stream = Stream, csid = CSID, sid = HID, csidb = <<CSID:6>>}};
	
init(Args) ->
	{stop, {error, {init, Args}}}.
	
%%--------------------------------------------------------------------
%% Function:    handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call(_Request, _From, State) ->
	Error = {error, {no_matching, handle_cast}},
	{stop, Error, Error, State}.
	
%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------

handle_cast(wait_mainframe, S) ->
	{noreply, S};

handle_cast({send, Msg}, S) when S#state.fts == undefined ->
	encode(type, S#state{fts = erlang:now()}, Msg);

handle_cast({send, Msg}, S) ->
	encode(type, S, Msg);

handle_cast(_Msg, State) ->
	{stop, {error, {no_matching, handle_cast}}, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%-----------------------------------------Z--------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, S) ->
	{stop, normal, S};

handle_info(_Info, State) ->
	{stop, {error, {no_matching, handle_info}}, State}.
	
%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: terminate process
%%--------------------------------------------------------------------

terminate(_Reason, _State) ->
	?LOG(?MODULE, self(), "terminate", []),
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

encode(type, S, {Type, Msg}) ->
%	?LOG(?MODULE, self(), "type: ~w", [Type]),
	case Type of
		?RTMP_PCM_SET_CHUNK_SIZE ->
			encode(msghead, S, {Type, 4, <<Msg:32>>});
		?RTMP_PCM_ACKNOWLEDGEMENT ->
			encode(msghead, S, {Type, 4, <<Msg:32>>});
		?RTMP_PCM_USER_CONTROL_MESSAGE ->
			case Msg of
				{?RTMP_UCM_SET_BUFFER_LENGTH, {StreamId, BufferLength}} ->
					encode(msghead, S, {Type, 10, <<?RTMP_UCM_SET_BUFFER_LENGTH:16, StreamId:32, BufferLength:32>>});
				{EventType, EventData} ->
					encode(msghead, S, {Type, 6, <<EventType:16, EventData:32>>})
			end;
		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
			encode(msghead, S, {Type, 4, <<Msg:32>>});
		?RTMP_PCM_SET_PEER_BANDWIDTH ->
			{Size, LimitType} = Msg,
			encode(msghead, S, {Type, 5, <<Size:32, LimitType:8>>});
		?RTMP_MSG_AUDIO ->
			encode(msghead, S, {Type, byte_size(Msg), Msg});
		?RTMP_MSG_VIDEO ->
			encode(msghead, S, {Type, byte_size(Msg), Msg});
		?RTMP_MSG_DATA_AMF0 ->
			Bin = amf0:encode_args(Msg),
			encode(msghead, S, {Type, byte_size(Bin), Bin});
		?RTMP_MSG_COMMAND_AMF0 ->
			Bin = amf0:encode_args(Msg),
			encode(msghead, S, {Type, byte_size(Bin), Bin});
		_Type ->
			?LOG(?MODULE, self(), "type: unmatched message type: ~w", [_Type]),
			{noreply, S}
	end;

encode(msghead, S, {Type, Len, Bin}) when S#state.type == Type, S#state.len == Len -> % fmt == 2
	{Ts, Tsd} = get_timestamp_diff(S#state.ts),
	encode(chunk, S#state{ts = Ts}, <<2:2, (S#state.csidb)/bitstring, Tsd:24>>, Bin);

encode(msghead, S, {Type, Len, Bin}) when S#state.type == Type -> %fmt == 1
	{Ts, Tsd} = get_timestamp_diff(S#state.ts),
	encode(chunk, S#state{ts = Ts, len = Len}, <<1:2, (S#state.csidb)/bitstring, Tsd:24, Len:24, Type:8>>, Bin);

encode(msghead, S, {Type, Len, Bin}) ->
	case Type of
		?RTMP_MSG_AUDIO ->
			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
		?RTMP_MSG_VIDEO ->
			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
		?RTMP_MSG_DATA_AMF0 ->
			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
		?RTMP_MSG_COMMAND_AMF0 ->
			encode(msghead, S#state{type = Type, len = Len}, {Type, Bin});
		_CMD ->
			encode(msghead, S#state{len = Len}, {Type, Bin})
	end;

encode(msghead, S, {Type, Bin}) -> % fmt == 0
	{Ts, Tsd} = get_timestamp_diff(S#state.fts),
	encode(chunk, S#state{ts = Ts}, <<0:2, (S#state.csidb)/bitstring, Tsd:24, (S#state.len):24, Type:8, (S#state.sid):32>>, Bin).

encode(chunk, S, _Head, <<>>) ->
	{noreply, S};

encode(chunk, S, Head, Bin) ->
	case byte_size(Bin) > S#state.csize of
		true ->
			{P, R} = split_binary(Bin, S#state.csize),
			encode(send, S, <<Head/binary, P/binary>>, R);
		false ->
			encode(send, S, <<Head/binary, Bin/binary>>, <<>>)
	end;

encode(send, S, Chunk, Bin) ->
	case gen_tcp:send(S#state.socket, Chunk) of
		ok ->
			encode(chunk, S, <<3:2, (S#state.csidb)/bitstring>>, Bin);
		{error, Reason} ->
			?LOG(?MODULE, self(), "send error:~n~p", [Reason]),
			{stop, {error, Reason}, S}
	end.

get_timestamp_diff(Ts1) ->
	Ts2 = now(),
	{Ts2, round(timer:now_diff(Ts2, Ts1)/1000)}.
