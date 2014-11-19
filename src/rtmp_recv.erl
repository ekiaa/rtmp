%%====================================================================
%%% Description : Read RTMP data from socket
%%====================================================================

-module(rtmp_recv).
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-11").
-version("0.1").

%%--------------------------------------------------------------------

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions
-export([start/2, start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record
-record(state, {connection, socket}).

% rlen: length of received data from client
% srlen: rlen value sended to client

%%====================================================================
%% API
%%====================================================================

start(Connection, Socket) ->
	rtmp_recv_sup:start_recv([Connection, Socket]).
	
start_link(Connection, Socket) ->
	gen_server:start_link(?MODULE, {Connection, Socket}, []).
	
%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init({Connection, Socket}) ->
	lager:debug("Start rtmp_recv; Connection: ~p; Socket: ~p", [Connection, Socket]),
	erlang:monitor(process, Connection),
	gen_server:cast(self(), recv),
	{ok, #state{connection = Connection, socket = Socket}};

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
			rtmp_connection:received(?State.connection, Data),
			gen_server:cast(self(), recv),
			{noreply, State};
		{error, timeout} ->
			gen_server:cast(self(), recv),
			{noreply, State};
		{error, Reason} ->
			lager:error("handle_cast: gen_tcp:recv() error:~n~p", [Reason]),
			{stop, normal, State}
	end;

handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p", [Msg]),
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

terminate(Reason, _State) ->
	lager:debug("terminate:~n~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.