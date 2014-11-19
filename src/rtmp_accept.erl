%%====================================================================
%% Description : Accept new connection for RTMP channels
%%====================================================================

-module(rtmp_accept).
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions
-export([start_link/0]).

%% supervisor callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%====================================================================
%% API
%%====================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description : Initiates the accepter
%%--------------------------------------------------------------------

init([]) ->
	self() ! listen,
	Port = rtmp:get_env(rtmp_listen_port, 1935),
	{ok, #{listened => false, lport => Port}};
	
init(Args) ->
	{stop, {?MODULE, ?LINE, no_matching, Args}}.

%%--------------------------------------------------------------------
%% Description : Handling call stop message
%%--------------------------------------------------------------------
	
handle_call(Request, _From, State) ->
	{stop, {?MODULE, ?LINE, no_matching, Request}, {error, no_matching}, State}.

%%--------------------------------------------------------------------
%% Description : Handling cast error message from accepter
%%--------------------------------------------------------------------

handle_cast(Message, State) ->
	{stop, {?MODULE, ?LINE, no_matching, Message}, State}.

%%--------------------------------------------------------------------
%% Description : Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info(listen, #{listened := false, lport := LPort} = State) ->
	case gen_tcp:listen(LPort, [binary, {active, false}, {nodelay, true}]) of
		{ok, LSock} ->
			self() ! accept,
			{noreply, State#{lsock => LSock, listened => true}};
		{error, eaddrinuse} ->
			timer:send_after(5000, listen),
			{noreply, State};
		{error, Reason} ->
			lager:error("handle_cast: gen_tcp:listen() error:~n~p", [Reason]),
			{stop, {?MODULE, ?LINE, error, Reason}, State}
	end;

handle_info(listen, State) ->
	{noreply, State};

handle_info(accept, #{lsock := LSock} = State) ->
	case gen_tcp:accept(LSock, 5000) of
		{ok, Socket} ->
			rtmp_channel:start(Socket),
			self() ! accept,
			{noreply, State};
		{error, timeout} ->
			self() ! accept,
			{noreply, State};
		{error, Reason} ->
			{stop, {?MODULE, ?LINE, error, Reason}, State}
	end;

handle_info(Info, State) ->
	{stop, {?MODULE, ?LINE, no_matching, Info}, State}.

%%--------------------------------------------------------------------
%% Description : Terminate gen_server
%%--------------------------------------------------------------------

terminate(normal, _) -> ok;
terminate(Reason, State) -> lager:error("terminate~nReason: ~p~nState: ~p", [Reason, State]).

%%--------------------------------------------------------------------
%% Description : Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
