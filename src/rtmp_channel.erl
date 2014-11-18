%%====================================================================
%% Description : RTMP channel API and callbacks
%%====================================================================

-module(rtmp_channel).
-copyright("LiveTex").
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

-behaviour(gen_server).

-include("rtmp.hrl").
-include("ptcl.hrl").

%% API external functions
-export([start/1, start_link/1, message/3, accept_connection/1, reject_connection/1, send_command/3, start_publish/2, ackwinsize/2]).
% -export([srv_request/4, srv_response/3, srv_error/3, srv_notify/4, send_cmd/2]).

%% API internal functions
% -export([app_response/4, app_notify/3, client_msg/2, app_msg/2, ackwinsize/2, get_stream/2, get_send/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record
-record(state, {decode, encode, socket, connected = false, sid=1, list=[]}).

-record(stream, {sid, csid, ref, name, gsid, list=[], publish=false, play=false}).
-define(Stream, Stream#stream). %{}

%%====================================================================
%% API
%%====================================================================

start(Socket) ->
	rtmp_channel_sup:start_channel([Socket]).
	
start_link(Socket) ->
	gen_server:start_link(?MODULE, Socket, []).

message(Channel, StreamID, Message) ->
	gen_server:cast(Channel, {message, StreamID, Message}).

send_command(Channel, Command, Params) ->
	gen_server:cast(Channel, {send_command, Command, Params}).

accept_connection(Channel) ->
	gen_server:cast(Channel, {connect, accept}).

reject_connection(Channel) ->
	gen_server:cast(Channel, {connect, reject}).

start_publish(Channel, StreamID) ->
	gen_server:cast(Channel, {message, StreamID, start_publish}).

ackwinsize(Channel, Len) ->
	gen_server:cast(Channel, {ackwinsize, Len}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init(Socket) when is_port(Socket)  ->
	lager:debug("Start rtmp_channel; Socket: ~p", [Socket]),
	gen_server:cast(self(), init),
	{ok, #state{socket = Socket}};

init(Args) ->
	lager:error("init: nomatch Args:~n~p", [Args]),
	{stop, {error, nomatch}}.
	
%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------

% % Message for application

% handle_call({srv, {request, Stream, Cmd, Args}}, _From, S) ->
% 	{ok, TrID} = rtmp:srv_request(S#state.parent, S#state.gsid, Cmd, Args),
% 	{reply, {ok, TrID}, S#state{rlist = [{TrID, Stream, Cmd} | S#state.rlist]}};	

% % Запрос от rtmp_decode на сопоставление Stream ID сo Stream pid
% handle_call({get_stream, 0}, _From, S) ->
% 	{reply, {ok, self()}, S};

% handle_call({get_stream, SID}, _From, S) ->
% 	case lists:keyfind(SID, 1, S#state.slist) of
% 		{_, _, Stream} ->
% 			{reply, {ok, Stream}, S};
% 		false ->
% 			?LOG(?MODULE, self(), "get_stream error: nostream for ID = ~w", [SID]),
% 			{reply, {error, nostream}, S}
% 	end;

% % Запрос от rtmp_encode на получение pid rtmp_send	
% handle_call(get_send, _From, S) ->
% 	{reply, {ok, S#state.send}, S};

handle_call(Request, _From, State) ->
	lager:error("handle_call: nomatch Request:~n~p", [Request]),
	Error = {error, nomatch},
	{stop, Error, Error, State}.
	
%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
	
handle_cast(init, State) ->
	case rtmp_handshake:init(?State.socket) of
		{ok, {Encrypted, KeyIn, KeyOut}} ->
			{ok, Encode} = rtmp_encode:start(self(), ?State.socket, Encrypted, KeyOut),
			erlang:monitor(process, Encode),
			Stream = #stream{sid = 0},
			rtmp_encode:create_stream(Encode, 0),
			{ok, Decode} = rtmp_decode:start(self(), ?State.socket, Encrypted, KeyIn),
			erlang:monitor(process, Decode),
			{noreply, ?State{decode = Decode, encode = Encode, list = [Stream]}};
		{error, Reason} ->
			lager:error("rtmp_handshake:init() error:~n~p", [Reason]),
			{stop, {error, Reason}, State}
	end;

handle_cast({message, StreamID, Message}, State) ->
	case stream_message(Message, StreamID, State) of
		{ok, NewState} ->
			{noreply, NewState};
		{error, Reason} ->
			lager:error("handle_cast: stream_message error:~n~p", [Reason]),
			{stop, {error, Reason}, State}
	end;

handle_cast({connect, Result}, State) ->
	case Result of
		accept ->
			lager:debug("handle_cast: accept connection"),
			rtmp_encode:send_message(?State.encode, 0, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE),
			rtmp_encode:send_message(?State.encode, 0, ?RTMP_CMD_PCM_SET_PEER_BANDWIDTH),
			{noreply, ?State{connected = true}};
		reject ->
			lager:debug("handle_cast: reject connection"),
			{stop, normal, State}
	end;

handle_cast({send_command, Command, Params}, State) ->
	lager:debug("send_command: ~p; Params:~n~p", [Command, Params]),
	rtmp_encode:send_message(?State.encode, 0, rtmp:cmd(?RTMP_CMD_AMF0, {Command, Params})),
	{noreply, State};

handle_cast({ackwinsize, Len}, State) ->
	rtmp_encode:send_message(?State.encode, 0, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT(Len)),
	{noreply, State};

handle_cast({timeout, connect}, State) ->
	case ?State.connected of
		true -> {noreply, State};
		false -> 
			lager:debug("handle_cast: timeout connect"),
			{stop, normal, State}
	end;

%%--------------------------------------------------------------------

% Сообщения от клиента
% handle_cast({client_message, Msg}, S) ->
% 	client_msg(Msg, S);

% Message for application 

% handle_cast({srv, {response, TrID, Response}}, S) ->
% 	rtmp:srv_response(S#state.parent, TrID, Response),
% 	{noreply, S};

% handle_cast({srv, {error, TrID, Error}}, S) ->
% 	rtmp:srv_error(S#state.parent, TrID, Error),
% 	{noreply, S};

% handle_cast({srv, {notify, _GSID, Cmd, Args}}, S) ->
% 	rtmp:srv_notify(S#state.parent, S#state.gsid, Cmd, Args),
% 	{noreply, S};

% Message from application

% handle_cast({app, Msg}, S) ->
% 	?MODULE:app_msg(Msg, S);

% Message from client
	


% Message from stream

% handle_cast({stream, {send_cmd, Cmd}}, S) ->
% 	rtmp_encode:send(S#state.cmdec, Cmd),
% 	{noreply, S};	
	
handle_cast(Msg, State) ->
	lager:error("handle_cast: nomatch Msg:~n~p", [Msg]),
	{stop, {error, nomatch}, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, Pid, _Info}, S) when S#state.encode == Pid; S#state.decode == Pid ->
	{stop, normal, S};

handle_info({'DOWN', _MonRef, process, _Stream, _Info}, S) ->
	{noreply, S};

handle_info(timeout, State) ->
	lager:debug("handle_info: timeout"),
	{stop, normal, State};

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
	?LOG(?MODULE, self(), "code_change", []),
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Description: Stream messages
%%--------------------------------------------------------------------

stream_message(Message, StreamID, State) when is_integer(StreamID) ->
	case lists:keyfind(StreamID, 2, ?State.list) of
		false ->
			lager:error("stream_message: nomatch StreamID: ~p", [StreamID]),
			{error, nomatch};
		Stream ->
			case stream_message(Message, Stream, State) of
				{ok, NewState} ->
					{ok, NewState};
				{ok, NewStream, NewState} ->
					{ok, NewState#state{list = lists:keyreplace(NewStream#stream.sid, 2, NewState#state.list, NewStream)}};
				{error, Reason} ->
					{error, Reason}
			end
	end;

stream_message({command, [{?STRING, "connect"}, _TrID, Object | _Rest]}, _Stream, State) ->
	% lager:debug("stream_message: command connect:~n~p~nRest: ~p", [Object, _Rest]),
	rtmp_event:notify({rtmp_event, self(), {new_channel, Object}}),
	timer:apply_after(60000, gen_server, cast, [self(), {timeout, connect}]),
	{ok, State};

stream_message({command, [{?STRING, "createStream"}, TrID | _]}, _Stream, State) ->
	Stream = #stream{sid = ?State.sid, gsid = rtmp:get_id()},
	rtmp_encode:create_stream(?State.encode, ?Stream.sid),
	rtmp_encode:send_message(?State.encode, 0, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CREATE_STREAM, {TrID, ?Stream.sid})),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, ?RTMP_CMD_UCM_STREAM_BEGIN(?Stream.sid)),
	rtmp_event:notify({rtmp_event, self(), {new_stream, ?Stream.sid}}),
	{ok, ?State{list = [Stream | ?State.list], sid = ?State.sid + 1}};

stream_message({command, [{?STRING, "publish"}, 0.0, null, {?STRING, StreamName}, {?STRING, Type}]}, Stream, State) ->
	rtmp_event:notify({rtmp_event, self(), {stream, ?Stream.sid, {publish, StreamName, Type}}}),
	{ok, ?Stream{name = StreamName}, State};

stream_message({command, [{?STRING, CMD}, 0.0, null, Params]}, _Stream, State) ->
	% lager:debug("stream_message: RTMP command: ~p~nParams: ~p", [CMD, Params]),
	rtmp_event:notify({rtmp_event, self(), {command, CMD, Params}}),
	{ok, State};

stream_message({asknowledgement_window_size, AckWinSize}, _Stream, State) ->
	rtmp_decode:setAckWinSize(?State.decode, AckWinSize),
	rtmp_encode:send_message(?State.encode, 0, ?RTMP_CMD_UCM_STREAM_BEGIN(0)),
	rtmp_encode:send_message(?State.encode, 0, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CONNECT, {1})),
	{ok, State};

stream_message(start_publish, Stream, State) ->
	lager:debug("start_publish: Stream:~n~p", [Stream]),
	rtmp_encode:send_message(?State.encode, ?Stream.sid, rtmp:cmd(?RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_START, {?Stream.name, ?Stream.gsid})),
	{ok, ?Stream{publish = true}, State};

stream_message(Message, Stream, State) ->
	lager:debug("stream_message:~nMessage: ~p~nStream: ~p", [Message, Stream]),
	{ok, State}.


%%--------------------------------------------------------------------
%% Client messages
%%--------------------------------------------------------------------

% Принимаем сообщения от rtmp_decode
% Принята команда RTMP на соединение
% client_msg({command, [{?STRING, "connect"}, _CTrID, Object]}, State) ->
% 	lager:debug("client_msg: connect:~n~p", [Object]),
% 	{noreply, State, 60000};
	
% Принята команда RTMP на создание нового потока
% client_msg({command, [{?STRING, "createStream"}, TrID | _]}, S) ->
% 	?LOG(?MODULE, self(), "rtmp_command createStream", []),
% 	{ok, Stream} = rtmp_stream:start(self(), S#state.socket, S#state.sid, S#state.csid),
% 	erlang:monitor(process, Stream),
% 	rtmp_encode:send(S#state.amfec, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CREATE_STREAM, {TrID, S#state.sid})),
% %	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_UCM_STREAM_BEGIN(N)),	
% 	{noreply, S#state{sid = S#state.sid + 1, csid = S#state.csid + 1, slist = [{S#state.sid, undefined, Stream} | S#state.slist]}};

% client_msg({asknowledgement_window_size, _Size}, S) ->
% %	?LOG(?MODULE, self(), "stream ~w: receive asknowledgement window size = ~w", [self(), Size]),
% %	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_PCM_SET_CHUNK_SIZE(4096)),
% 	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_UCM_STREAM_BEGIN(0)),
% 	rtmp_encode:send(S#state.amfec, rtmp:cmd(?RTMP_CMD_AMF0_RESULT_CONNECT, {1})),
% 	{noreply, S};

client_msg({asknowledgement, _Size}, S) ->
	{noreply, S};

client_msg(Message, S) ->
	?LOG(?MODULE, self(), "client message:~n~p", [Message]),
	{noreply, S}.
	
%%--------------------------------------------------------------------
%% Application messages
%%--------------------------------------------------------------------

% app_msg({request, GSID, Cmd, Args, TrID}, S) when S#state.gsid == GSID ->
% 	?MODULE:app_request(Cmd, Args, TrID, S); % Message for self

% app_msg({request, GSID, Cmd, Args, TrID}, S) ->
% 	case rtmp:stream(GSID) of
% 		{ok, Stream} ->
% 			rtmp_stream:app_request(Stream, Cmd, Args, TrID),
% 			{noreply, S};
% 		{error, Reason} ->
% 			?LOG(?MODULE, self(), "app_request: get_stream {error, ~p}", [Reason]),
% 			{noreply, S}
% 	end;

% app_msg({response, TrID, Response}, S) ->
% 	case lists:keyfind(TrID, 1, S#state.rlist) of
% 		{_, Stream, Cmd} when Stream == self() ->
% 			?MODULE:app_response(Cmd, Response, TrID, S); % Message for self
% 		{_, Stream, Cmd} ->
% 			rtmp_stream:app_response(Stream, Cmd, Response, TrID),
% 			{noreply, S};
% 		false ->
% 			?LOG(?MODULE, self(), "app_response: no TrID = ~w", [TrID]),
% 			{noreply, S}
% 	end;

% app_msg({error, TrID, Error}, S) ->
% 	case lists:keyfind(TrID, 1, S#state.rlist) of
% 		{_, Stream, Cmd} when Stream == self() ->
% 			?MODULE:app_error(Cmd, Error, TrID, S); % Message for self
% 		{_, Stream, Cmd} ->
% 			rtmp_stream:app_error(Stream, Cmd, Error, TrID),
% 			{noreply, S};
% 		false ->
% 			{noreply, S}
% 	end;

% app_msg({notify, GSID, Cmd, Args}, S) when S#state.gsid == GSID ->
% 	?MODULE:app_notify(Cmd, Args, S); % Message for self

% app_msg({notify, GSID, Cmd, Args}, S) ->
% 	case rtmp:stream(GSID) of
% 		{ok, Stream} ->
% 			rtmp_stream:app_notify(Stream, Cmd, Args),
% 			{noreply, S};
% 		{error, Reason} ->
% 			?LOG(?MODULE, self(), "app_notify: get_stream {error, ~p}", [Reason]),
% 			{noreply, S}
% 	end.

%%--------------------------------------------------------------------
%% Application messages to channel
%%--------------------------------------------------------------------

% app_response({?STRING, "connect"}, true, _TrID, S) ->
% 	?LOG(?MODULE, self(), "connect: ok", []),
% 	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE),
% 	rtmp_encode:send(S#state.cmdec, ?RTMP_CMD_PCM_SET_PEER_BANDWIDTH),
% 	{noreply, S};

% app_response(Cmd, Response, TrID, S) ->
% 	?LOG(?MODULE, self(), "app_response ~p (~p):~n~p", [Cmd, TrID, Response]),
% 	{noreply, S}.

% app_notify(Cmd, Args, S) ->
% 	?LOG(?MODULE, self(), "app_notify ~p:~n~p", [Cmd, Args]),
% 	{noreply, S}.
	