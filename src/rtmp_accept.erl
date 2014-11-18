%%====================================================================
%% Description : Accept new connection for RTMP channels
%%====================================================================

-module(rtmp_accept).
-copyright("LiveTex").
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions
-export([start/0, start_link/0, stop/0]).

%% supervisor callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record
-record(state, {name, srv, sup, lport, lsock, tref}).

%%====================================================================
%% API
%%====================================================================

start() ->
	start_link().

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
	
stop() ->
	gen_server:call(?MODULE, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description : Initiates the accepter
%%--------------------------------------------------------------------

init([]) ->
	lager:debug("Start rtmp_accept"),
	gen_server:cast(self(), listen),
	Port = rtmp:get_env(rtmp_listen_port, 1935),
	{ok, #state{lport = Port}};
	
init(Args) ->
	lager:error("init: nomatch Args:~n~p", [Args]),
	{stop, {error, nomatch}}.

%%--------------------------------------------------------------------
%% Description : Handling call stop message
%%--------------------------------------------------------------------

handle_call(stop, _From, State) ->
	lager:debug("handle_call: stop"),
	{stop, normal, ok, State};
	
handle_call(Request, _From, State) ->
	lager:error("handle_call: nomatch Request:~n~p", [Request]),
	Error = {error, nomatch},
	{stop, Error, Error, State}.

%%--------------------------------------------------------------------
%% Description : Handling cast error message from accepter
%%--------------------------------------------------------------------

handle_cast(listen, State) ->
	case gen_tcp:listen(?State.lport, [binary, {active, false}, {nodelay, true}]) of
		{ok, LSock} ->
			lager:debug("Listen port: ~p", [?State.lport]),
			gen_server:cast(self(), accept),
			{noreply, ?State{lsock = LSock}};
		{error, eaddrinuse} ->
			lager:debug("handle_cast: gen_tcp:listen() error: eaddrinuse"),
			timer:apply_after(5000, gen_server, cast, [self(), listen]),
			{noreply, State};
		{error, Reason} ->
			lager:error("handle_cast: gen_tcp:listen() error:~n~p", [Reason]),
			{stop, {error, Reason}, State}
	end;

handle_cast(accept, State) ->
	case gen_tcp:accept(?State.lsock, 5000) of
		{ok, Socket} ->
			rtmp_channel:start(Socket),
			gen_server:cast(self(), accept),
			{noreply, State};
		{error, timeout} ->
			gen_server:cast(self(), accept),
			{noreply, State};
		{error, Reason} ->
			lager:error("handle_cast: gen_tcp:accept() error:~n~p", [Reason]),
			{stop, {error, Reason}, State}
	end;

handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p", [Msg]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------
%% Description : Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info(Info, State) ->
	lager:error("handle_info: nomatch Info:~n~p", [Info]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------
%% Description : Terminate gen_server
%%--------------------------------------------------------------------

terminate(Reason, _State) ->
	lager:debug("terminate:~n~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Description : Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
