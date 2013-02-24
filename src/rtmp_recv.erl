%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp_recv.erl
%%% Author      : Ekimov Artem <ekimov-artem@ya.ru>
%%% Description : RTMP TCP receive API and callbacks
%%% Created     : 28.04.2012
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp_recv).

-author('ekimov-artem@ya.ru').

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions

-export([start/2, start_link/2, stop/1]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {channel, socket, decode, rlen = 0, srlen = 0}).

% rlen: length of received data from client
% srlen: rlen value sended to client

%%====================================================================
%% API
%%====================================================================

start(Channel, Socket) ->
	start_link(Channel, Socket).
	
start_link(Channel, Socket) ->
	gen_server:start_link(?MODULE, {Channel, Socket}, []).
	
stop(Pid) ->
	gen_server:call(Pid, stop).
	
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

init({Channel, Socket}) ->
	?LOG(?MODULE, self(), "init: {~w, ~w}", [Channel, Socket]),
	erlang:monitor(process, Channel),
	gen_server:cast(self(), init),
	{ok, #state{channel = Channel, socket = Socket}};

init(_Args) ->
	{stop, {error, {no_matching, init}}}.
	
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

handle_cast(init, S) ->
	{ok, Decode} = rtmp:start_decode(S#state.channel),
	erlang:monitor(process, Decode),
	handshaker(init, S#state{decode = Decode});

handle_cast(recv, S) ->	
	case gen_tcp:recv(S#state.socket, 0, 1000) of
		{ok, Data} ->
		%	?LOG(?MODULE, self(), "recv data <<~w>>", [byte_size(Data)]),
			rtmp_decode:data(S#state.decode, Data),
			case S#state.rlen - S#state.srlen >= ?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE of
				true ->
					rtmp_channel:ackwinsize(S#state.channel, S#state.rlen),
					gen_server:cast(self(), recv),
					{noreply, S#state{rlen =  S#state.rlen + byte_size(Data), srlen = S#state.rlen}};
				false ->
					gen_server:cast(self(), recv),
					{noreply, S#state{rlen =  S#state.rlen + byte_size(Data)}}
			end;
		{error, timeout} ->
			gen_server:cast(self(), recv),
			{noreply, S};
		{error, Reason} ->
			?LOG(?MODULE, self(), "error: ~w", [Reason]),
			{stop, normal, S}
	end;

handle_cast(_Msg, State) ->
	{stop, {error, {no_matching, handle_cast}}, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

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
	?LOG(?MODULE, self(), "code_change", []),
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

handshaker(init, S) ->
	handshaker(handshake_C0, S);

handshaker(handshake_C0, S) ->
	case gen_tcp:recv(S#state.socket, 1) of
		{ok, <<Version:8>>} ->
			if
				Version == 3 ->
					handshaker(handshake_S0_S1, S);
				true ->
					{stop, normal, S}
			end;
		{error, Reason} ->
			?LOG(?MODULE, self(), "error: ~w", [Reason]),
			{stop, normal, S}
	end;

handshaker(handshake_S0_S1, S) ->
	RandomData = get_random_packet(1528),
	case gen_tcp:send(S#state.socket, <<3:8, 0:32, 0:32, RandomData/binary>>) of
		ok ->
			handshaker(handshake_C1_S2, S);
		{error, Reason} ->
			?LOG(?MODULE, self(), "error: ~w", [Reason]),
			{stop, normal, S}
	end;
	
handshaker(handshake_C1_S2, S) ->
	case gen_tcp:recv(S#state.socket, 1536) of
		{ok, <<Time:32, _Time2:32, RandomEcho/binary>>} ->
			case gen_tcp:send(S#state.socket, <<Time:32, 1:32, RandomEcho/binary>>) of
				ok ->
					handshaker(handshake_C2, S);
				{error, Reason} ->
					?LOG(?MODULE, self(), "error: ~w", [Reason]),
					{stop, normal, S}
			end;
		{error, Reason} ->
			?LOG(?MODULE, self(), "error: ~w", [Reason]),
			{stop, normal, S}
	end;

handshaker(handshake_C2, S) ->
	case gen_tcp:recv(S#state.socket, 1536) of
		{ok, <<_Time:32, _Time2:32, _RandomEcho/binary>>} ->
			gen_server:cast(self(), recv),
			{noreply, S};
		{error, Reason} ->
			?LOG(?MODULE, self(), "error: ~w", [Reason]),
			{stop, normal, S}
	end.

get_random_packet(Size) ->
	{A1,A2,A3} = now(),
      random:seed(A1, A2, A3),
	A = random:uniform(256) - 1,
	get_random_packet([A], Size-1).

get_random_packet(Packet, 0) ->
	list_to_binary(Packet);

get_random_packet(Packet, Size) ->
	A = random:uniform(256) - 1,
	get_random_packet([Packet, A], Size-1).