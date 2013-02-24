%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp_accept.erl
%%% Author      : Ekimov Artem <ekimov-artem@ya.ru>
%%% Description : To accept new connection for RTMP stream
%%% Created     : 21.02.2010
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp_accept).

-author('ekimov-artem@ya.ru').

-behaviour(gen_server).

-include("rtmp.hrl").

%% API

-export([start/0, start_link/0, stop/0]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name, srv, sup, port, lsock, tref}).

%%==============================================================================================================================================
%% API
%%==============================================================================================================================================

start() ->
	start_link().

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
	
stop() ->
	gen_server:call(?MODULE, stop).

%%==============================================================================================================================================
%% gen_server callbacks
%%==============================================================================================================================================

%%----------------------------------------------------------------------------------------------------------------------------------------------
%% Function    : init() -> 
%%                   {ok, State}
%% Description : Initiates the accepter
%%----------------------------------------------------------------------------------------------------------------------------------------------

init([]) ->
	?LOG(?MODULE, self(), "init", []),
	{ok, #state{}};
	
init(Args) ->
	{stop, {error, {init, Args}}}.

%%----------------------------------------------------------------------------------------------------------------------------------------------
%% Function    : handle_call(Request, From, State) -> 
%%                   {stop, Reason, Reply, State} |
%% Request     : stop
%% Description : Handling call stop message
%%----------------------------------------------------------------------------------------------------------------------------------------------

handle_call({start_accept, Server, Port}, _From, S) ->
	case gen_tcp:listen(Port, [binary, {active, false}, {nodelay, true}]) of
		{ok, LSock} ->
			?LOG(?MODULE, self(), "listen port ~w: ok", [Port]),
			gen_server:cast(self(), accept),
			{reply, ok, S#state{srv = Server, port = Port, lsock = LSock}};
		{error, Reason} ->
			?LOG(?MODULE, self(), "listen port ~w: {error, ~w}", [Reason]),
			{reply, {error, Reason}, S}
	end;

handle_call(stop, _From, S) ->
	{stop, normal, ok, S};
	
handle_call(_Request, _From, State) ->
	Error = {error, {no_matching, handle_cast}},
	{stop, Error, Error, State}.

%%----------------------------------------------------------------------------------------------------------------------------------------------
%% Function    : handle_cast(Msg, State) -> 
%%                   {stop, Reason, State}
%% Message     : {accept_error, Reason}
%% Description : Handling cast error message from accepter
%%----------------------------------------------------------------------------------------------------------------------------------------------

handle_cast(accept, S) ->
	case gen_tcp:accept(S#state.lsock, 1000) of
		{ok, Socket} ->
			gen_server:cast(S#state.srv, {rtmp, ?MODULE, accept, Socket}),
			gen_server:cast(self(), accept),
			{noreply, S};
		{error, timeout} ->
			gen_server:cast(self(), accept),
			{noreply, S};
		{error, Reason} ->
			?LOG(?MODULE, self(), "accept: {error, ~w}", [Reason]),
			{stop, {error, Reason}, S}
	end;

handle_cast(_Msg, State) ->
	{stop, {error, {no_matching, handle_cast}}, State}.

%%----------------------------------------------------------------------------------------------------------------------------------------------
%% Function    : handle_info(Info, State) -> 
%%                   {noreply, State} |
%%                   {noreply, State, Timeout} |
%%                   {stop, Reason, State}
%% Info        : 
%% Description : Handling all non call/cast messages
%%----------------------------------------------------------------------------------------------------------------------------------------------

handle_info(_Info, State) ->
	{stop, {error, {no_matching, handle_info}}, State}.

%%----------------------------------------------------------------------------------------------------------------------------------------------
%% Function    : terminate(Reason, State) -> void()
%% Reason      : 
%% Description : This function is called by a gen_server when it is about to terminate
%%----------------------------------------------------------------------------------------------------------------------------------------------

terminate(Reason, _State) ->
	?LOG(?MODULE, self(), "terminate: ~p", [Reason]),
	ok.

%%----------------------------------------------------------------------------------------------------------------------------------------------
%% Function    : code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description : Convert process state when code is changed
%%----------------------------------------------------------------------------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%==============================================================================================================================================
%% Internal functions
%%==============================================================================================================================================

%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% End of file : rtmp_accept.erl
%%%---------------------------------------------------------------------------------------------------------------------------------------------
