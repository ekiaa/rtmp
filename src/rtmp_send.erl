%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp_send.erl
%%% Author      : Ekimov Artem <ekimov-artem@ya.ru>
%%% Description : RTMP TCP sending API and callbacks
%%% Created     : 28.04.2012
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp_send).

-author('ekimov-artem@ya.ru').

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions

-export([start/2, start_link/2, stop/1, send/2]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {channel, socket, sending = false, bin = <<>>}).

%%====================================================================
%% API
%%====================================================================

start(Channel, Socket) ->
	start_link(Channel, Socket).
	
start_link(Channel, Socket) ->
	gen_server:start_link(?MODULE, {Channel, Socket}, []).
	
stop(Pid) ->
	gen_server:call(Pid, stop).
	
send(Send, Data) ->
	gen_server:cast(Send, {send, Data}).
	
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

handle_cast({send, Data}, S) when S#state.sending == false ->
%	?LOG(?MODULE, self(), "send data <<~w>> when sending is false", [byte_size(Data)]),
	gen_server:cast(self(), send),
	{noreply, S#state{sending = true, bin = <<(S#state.bin)/binary, Data/binary>>}};
	
handle_cast({send, Data}, S) ->
%	?LOG(?MODULE, self(), "send data <<~w>> when sending is true", [byte_size(Data)]),
	{noreply, S#state{bin = <<(S#state.bin)/binary, Data/binary>>}};
	
handle_cast(send, S) ->
	case gen_tcp:send(S#state.socket, S#state.bin) of
		ok ->
		%	?LOG(?MODULE, self(), "send data <<~w>>", [byte_size(S#state.bin)]),
			{noreply, S#state{sending = false, bin = <<>>}};
		{error, Reason} ->
			?LOG(?MODULE, self(), "error: ~w", [Reason]),
			{stop, {error, Reason}, S}
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