%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp_channel.erl
%%% Author      : Ekimov Artem <ekimov-artem@ya.ru>
%%% Description : RTMP channel API and callbacks
%%% Created     : 10.05.2012
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp_channel).

-author('ekimov-artem@ya.ru').

-behaviour(gen_server).

-include("rtmp.hrl").
-include("ptcl.hrl").

%% API external functions

-export([start/2, start_link/2, stop/1]).

-export([srv_request/4, srv_response/3, srv_error/3, srv_notify/4, send_cmd/2]).

%% API internal functions

-export([app_response/4, app_notify/3, client_msg/2, app_msg/2, ackwinsize/2, get_stream/2, get_send/1]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {parent, recv, send, cmdec, amfec, socket, gsid, sid=1, csid=4, slist=[], rlist=[]}).

%%====================================================================
%% API
%%====================================================================

start(Parent, Socket) ->
	supervisor:start_child(?CHANNEL_SUP, [Parent, Socket]).
	
start_link(Parent, Socket) ->
	gen_server:start_link(?MODULE, {Parent, Socket}, []).
	
stop(Pid) ->
	gen_server:call(Pid, stop).

srv_request(Channel, GSID, Cmd, Args) ->
	gen_server:call(Channel, {srv, {request, GSID, Cmd, Args}}).

srv_response(Channel, TrID, Response) ->
	gen_server:cast(Channel, {srv, {response, TrID, Response}}).

srv_error(Channel, TrID, Error) ->
	gen_server:cast(Channel, {srv, {error, TrID, Error}}).

srv_notify(Channel, GSID, Cmd, Args) ->
	gen_server:cast(Channel, {srv, {notify, GSID, Cmd, Args}}).
	
ackwinsize(Channel, Len) ->
	gen_server:cast(Channel, {ackwinsize, Len}).
	
get_stream(Channel, SID) ->
	gen_server:call(Channel, {get_stream, SID}).
	
get_send(Channel) ->
	gen_server:call(Channel, get_send).

send_cmd(Channel, Cmd) ->
	gen_server:cast(Channel, {stream, {send_cmd, Cmd}}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init({Parent, Socket}) ->
	?LOG(?MODULE, self(), "start: {~w, ~w}", [Parent, Socket]),
	gen_server:cast(self(), init),
	erlang:monitor(process, Parent),
	{ok, #state{parent = Parent, socket = Socket}};

init(_Args) ->
	{stop, {error, {?MODULE, self(), no_matching, init}}}.
	
%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------

% Message for application

handle_call({srv, {request, Stream, Cmd, Args}}, _From, S) ->
	{ok, TrID} = rtmp:srv_request(S#state.parent, S#state.gsid, Cmd, Args),
	{reply, {ok, TrID}, S#state{rlist = [{TrID, Stream, Cmd} | S#state.rlist]}};	

% Запрос от rtmp_decode на сопоставление Stream ID сo Stream pid
handle_call({get_stream, 0}, _From, S) ->
	{reply, {ok, self()}, S};

handle_call({get_stream, SID}, _From, S) ->
	case lists:keyfind(SID, 1, S#state.slist) of
		{_, _, Stream} ->
			{reply, {ok, Stream}, S};
		false ->
			?LOG(?MODULE, self(), "get_stream error: nostream for ID = ~w", [SID]),
			{reply, {error, nostream}, S}
	end;

% Запрос от rtmp_encode на получение pid rtmp_send	
handle_call(get_send, _From, S) ->
	{reply, {ok, S#state.send}, S};

handle_call(_Request, _From, State) ->
	Error = {error, {?MODULE, self(), no_matching, handle_call}},
	{stop, Error, Error, State}.
	
%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
	
handle_cast(init, S) ->
	% {ok, Send} = rtmp:start_send(self(), S#state.socket),
	{ok, Recv} = rtmp:start_recv(self(), S#state.socket),
	% erlang:monitor(process, Send),
	erlang:monitor(process, Recv),
	{ok, CmdEc} = rtmp_encode:start(self(), S#state.socket, 0, 2),
	{ok, AmfEc} = rtmp_encode:start(self(), S#state.socket, 0, 3),
	{ok, GSID} = rtmp:stream(),
	{noreply, S#state{recv = Recv, cmdec = CmdEc, amfec = AmfEc, gsid = GSID}};

% Сообщения от клиента
handle_cast({client_message, Msg}, S) ->
	client_msg(Msg, S);

% Message for application 

handle_cast({srv, {response, TrID, Response}}, S) ->
	rtmp:srv_response(S#state.parent, TrID, Response),
	{noreply, S};

handle_cast({srv, {error, TrID, Error}}, S) ->
	rtmp:srv_error(S#state.parent, TrID, Error),
	{noreply, S};

handle_cast({srv, {notify, _GSID, Cmd, Args}}, S) ->
	rtmp:srv_notify(S#state.parent, S#state.gsid, Cmd, Args),
	{noreply, S};

% Message from application

handle_cast({app, Msg}, S) ->
	?MODULE:app_msg(Msg, S);

% Message from client
	
handle_cast({ackwinsize, Len}, S) ->
	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT(Len)),
	{noreply, S};

% Message from stream

handle_cast({stream, {send_cmd, Cmd}}, S) ->
	rtmp_encode:send(S#state.cmdec, Cmd),
	{noreply, S};	
	
handle_cast(_Msg, State) ->
	{stop, {error, {?MODULE, self(), no_matching, handle_cast}}, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, Pid, _Info}, S) when S#state.send == Pid; S#state.recv == Pid ->
	{stop, normal, S};

handle_info({'DOWN', _MonRef, process, _Stream, _Info}, S) ->
	{noreply, S};	

handle_info(_Info, State) ->
	{stop, {error, {?MODULE, self(), no_matching, handle_info}}, State}.
	
%%--------------------------------------------------------------------
%% Description: terminate process
%%--------------------------------------------------------------------

terminate(_Reason, _State) ->
	?LOG(?MODULE, self(), "terminate", []),
	ok.

%%--------------------------------------------------------------------
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
	?LOG(?MODULE, self(), "code_change", []),
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Client messages
%%--------------------------------------------------------------------

% Принимаем сообщения от rtmp_decode
% Принята команда RTMP на соединение
client_msg({command, [{?STRING, "connect"} = Cmd, _CTrID, Object]}, S) ->
	?LOG(?MODULE, self(), "rtmp_command connect", []),
	{ok, TrID} = rtmp:srv_request(S#state.parent, S#state.gsid, Cmd, Object),
	{noreply, S#state{rlist = [{TrID, self(), Cmd} | S#state.rlist]}};
	
% Принята команда RTMP на создание нового потока
client_msg({command, [{?STRING, "createStream"}, TrID | _]}, S) ->
	?LOG(?MODULE, self(), "rtmp_command createStream", []),
	{ok, Stream} = rtmp_stream:start(self(), S#state.socket, S#state.sid, S#state.csid),
	erlang:monitor(process, Stream),
	rtmp_encode:send(S#state.amfec, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CREATE_STREAM, {TrID, S#state.sid})),
%	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_UCM_STREAM_BEGIN(N)),	
	{noreply, S#state{sid = S#state.sid + 1, csid = S#state.csid + 1, slist = [{S#state.sid, undefined, Stream} | S#state.slist]}};

client_msg({asknowledgement_window_size, _Size}, S) ->
%	?LOG(?MODULE, self(), "stream ~w: receive asknowledgement window size = ~w", [self(), Size]),
%	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_PCM_SET_CHUNK_SIZE(4096)),
	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_UCM_STREAM_BEGIN(0)),
	rtmp_encode:send(S#state.amfec, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CONNECT, {1})),
	{noreply, S};

client_msg({asknowledgement, _Size}, S) ->
	{noreply, S};

client_msg(Message, S) ->
	?LOG(?MODULE, self(), "client message:~n~p", [Message]),
	{noreply, S}.
	
%%--------------------------------------------------------------------
%% Application messages
%%--------------------------------------------------------------------

app_msg({request, GSID, Cmd, Args, TrID}, S) when S#state.gsid == GSID ->
	?MODULE:app_request(Cmd, Args, TrID, S); % Message for self

app_msg({request, GSID, Cmd, Args, TrID}, S) ->
	case rtmp:stream(GSID) of
		{ok, Stream} ->
			rtmp_stream:app_request(Stream, Cmd, Args, TrID),
			{noreply, S};
		{error, Reason} ->
			?LOG(?MODULE, self(), "app_request: get_stream {error, ~p}", [Reason]),
			{noreply, S}
	end;

app_msg({response, TrID, Response}, S) ->
	case lists:keyfind(TrID, 1, S#state.rlist) of
		{_, Stream, Cmd} when Stream == self() ->
			?MODULE:app_response(Cmd, Response, TrID, S); % Message for self
		{_, Stream, Cmd} ->
			rtmp_stream:app_response(Stream, Cmd, Response, TrID),
			{noreply, S};
		false ->
			?LOG(?MODULE, self(), "app_response: no TrID = ~w", [TrID]),
			{noreply, S}
	end;

app_msg({error, TrID, Error}, S) ->
	case lists:keyfind(TrID, 1, S#state.rlist) of
		{_, Stream, Cmd} when Stream == self() ->
			?MODULE:app_error(Cmd, Error, TrID, S); % Message for self
		{_, Stream, Cmd} ->
			rtmp_stream:app_error(Stream, Cmd, Error, TrID),
			{noreply, S};
		false ->
			{noreply, S}
	end;

app_msg({notify, GSID, Cmd, Args}, S) when S#state.gsid == GSID ->
	?MODULE:app_notify(Cmd, Args, S); % Message for self

app_msg({notify, GSID, Cmd, Args}, S) ->
	case rtmp:stream(GSID) of
		{ok, Stream} ->
			rtmp_stream:app_notify(Stream, Cmd, Args),
			{noreply, S};
		{error, Reason} ->
			?LOG(?MODULE, self(), "app_notify: get_stream {error, ~p}", [Reason]),
			{noreply, S}
	end.

%%--------------------------------------------------------------------
%% Application messages to channel
%%--------------------------------------------------------------------

app_response({?STRING, "connect"}, true, _TrID, S) ->
	?LOG(?MODULE, self(), "connect: ok", []),
	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE),
	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_PCM_SET_PEER_BANDWIDTH),
	{noreply, S};

app_response(Cmd, Response, TrID, S) ->
	?LOG(?MODULE, self(), "app_response ~p (~p):~n~p", [Cmd, TrID, Response]),
	{noreply, S}.

app_notify(Cmd, Args, S) ->
	?LOG(?MODULE, self(), "app_notify ~p:~n~p", [Cmd, Args]),
	{noreply, S}.
	