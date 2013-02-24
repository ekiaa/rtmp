%%%---------------------------------------------------------------------------------------------------------------------------------------------
%%% File        : rtmp_decode.erl
%%% Author      : Ekimov Artem <ekimov-artem@ya.ru>
%%% Description : RTMP decode API and callbacks
%%% Created     : 28.04.2012
%%%---------------------------------------------------------------------------------------------------------------------------------------------

-module(rtmp_decode).

-author('ekimov-artem@ya.ru').

-behaviour(gen_server).

-include("rtmp.hrl").

%% API functions

-export([start/1, start_link/1, stop/1]).

-export([data/2, decode/4, decode/5]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {channel, lref = 0, list = [], fmt, csid, ns=bh}).

% lref - last referense for chunk stream
% ns - next state; bh - basic header

-record(cs, {stream, sid, csid, ts, tsd, len, type, rlen=0, csize=?RTMP_CONST_CHUNK_SIZE, data}).

%%====================================================================
%% API
%%====================================================================

start(Channel) ->
	start_link(Channel).
	
start_link(Channel) ->
	gen_server:start_link(?MODULE, Channel, []).
	
stop(Pid) ->
	gen_server:call(Pid, stop).

%% Set new data for decode
data(Decode, Data) ->
	gen_server:cast(Decode, {data, Data}).
	
%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------

init(Channel) when is_pid(Channel) ->
	?LOG(?MODULE, self(), "init: ~w", [Channel]),
	erlang:monitor(process, Channel),
	gen_server:cast(self(), init),
	{ok, #state{channel = Channel}};

init(_Args) ->
	{stop, {error, {?MODULE, self(), no_matching, init}}}.
	
%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call(_Request, _From, State) ->
	Error = {error, {?MODULE, self(), no_matching, handle_cast}},
	{stop, Error, Error, State}.
	
%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------

handle_cast(init, S) ->
	C2 = #cs{stream = S#state.channel, sid = 0, csid = 2, data = <<>>},
	C3 = #cs{stream = S#state.channel, sid = 0, csid = 3, data = <<>>},
	{noreply, {S#state{list = [C3, C2]}, C3, <<>>}};
	
handle_cast({data, Data}, {S, C, B}) ->
	?MODULE:decode(S#state.ns, S, C, <<B/binary, Data/binary>>);

handle_cast(_Msg, State) ->
	{stop, {error, {?MODULE, self(), no_matching, handle_cast}}, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({'DOWN', _MonRef, process, _Pid, _Info}, S) ->
	{stop, normal, S};

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

decode(bh, S, C, <<>>) ->
%	?LOG(?MODULE, self(), "fmt ~w, csid ~w, mh: <<>>", [S#state.fmt, S#state.csid]),
	{noreply, {S#state{ns = bh}, C, <<>>}};

decode(bh, S, C, <<Fmt:2, 0:6, CSID:8, B/binary>>) ->
%	?LOG(?MODULE, self(), "basic header: <<~w:2, 0:6, ~w:8>>", [Fmt, CSID]),
	?MODULE:decode(csid, S#state{fmt=Fmt, csid=CSID}, C, B);
	
decode(bh, S, C, <<Fmt:2, 1:6, CSID:16, B/binary>>) ->
%	?LOG(?MODULE, self(), "basic header: <<~w:2, 1:6, ~w:16>>", [Fmt, CSID]),
	?MODULE:decode(csid, S#state{fmt=Fmt, csid=CSID}, C, B);
	
decode(bh, S, C, <<Fmt:2, CSID:6, B/binary>>) ->
%	?LOG(?MODULE, self(), "basic header: <<~w:2, ~w:6>>", [Fmt, CSID]),
	?MODULE:decode(csid, S#state{fmt=Fmt, csid=CSID}, C, B);

decode(csid, S, C, B) when S#state.csid /= C#cs.csid ->
	case lists:keyfind(S#state.csid, 4, S#state.list) of
		false ->
		%	?LOG(?MODULE, self(), "new chunck stream: ~w", [S#state.csid]),
			Cs = #cs{csid = S#state.csid, data = <<>>},
			List = lists:keyreplace(C#cs.csid, 4, S#state.list, C),
			?MODULE:decode(mh, S#state{list = [Cs | List]}, Cs, B);
		Cs ->
			List = lists:keyreplace(C#cs.csid, 4, S#state.list, C),
			?MODULE:decode(mh, S#state{list = List}, Cs, B)
	end;

decode(csid, S, C, B) ->
	?MODULE:decode(mh, S, C, B);
	
decode(mh, S, C, <<Ts:24, Len:24, Type:8, Sid:8, _Bin:24, B/binary>>) when S#state.fmt == 0 ->
%	?LOG(?MODULE, self(), "fmt ~w, csid ~w, ts ~w, len ~w, type ~w, sid ~w, bin ~w", [S#state.fmt, S#state.csid, Ts, Len, Type, Sid, _Bin]),
	?MODULE:decode(mng, S, C#cs{ts=Ts, len=Len, type=Type, sid=Sid}, B);

decode(mh, S, C, <<Tsd:24, Len:24, Type:8, B/binary>>) when S#state.fmt == 1 ->
%	?LOG(?MODULE, self(), "fmt ~w, csid ~w, tsd ~w, len ~w, type ~w", [S#state.fmt, S#state.csid, Tsd, Len, Type]),
	?MODULE:decode(mng, S, C#cs{tsd=Tsd, len=Len, type=Type}, B);

decode(mh, S, C, <<Tsd:24, B/binary>>) when S#state.fmt == 2 ->
%	?LOG(?MODULE, self(), "fmt ~w, csid ~w, tsd ~w", [S#state.fmt, S#state.csid, Tsd]),
	?MODULE:decode(mng, S, C#cs{tsd=Tsd}, B);
	
decode(mh, S, C, <<>>) when S#state.fmt == 3 ->
%	?LOG(?MODULE, self(), "fmt ~w, csid ~w, mh: <<>>", [S#state.fmt, S#state.csid]),
	{noreply, {S#state{ns = mh}, C, <<>>}};

decode(mh, S, C, B) when S#state.fmt == 3 ->
%	?LOG(?MODULE, self(), "fmt ~w, csid ~w", [S#state.fmt, S#state.csid]),
	?MODULE:decode(mng, S, C, B);

decode(mh, S, C, B) ->
%	?LOG(?MODULE, self(), "fmt ~w, csid ~w, B != <<>>", [S#state.fmt, S#state.csid]),
	{noreply, {S#state{ns = mh}, C, B}};

decode(mng, S, C, B) when C#cs.stream == undefined ->
	case rtmp_channel:get_stream(S#state.channel, C#cs.sid) of
		{ok, Stream} ->
		%	?LOG(?MODULE, self(), "set stream ~w, sid ~w, csid ~w)", [Stream, C#cs.sid, C#cs.csid]),
			?MODULE:decode(cpl, S, C#cs{stream = Stream}, B);
		{error, Reason} ->
			?LOG(?MODULE, self(), "rtmp_channel:get_stream error: ~w", [Reason]),
			{stop, normal, {S, C, B}}
end;

decode(mng, S, C, B) ->
	?MODULE:decode(cpl, S, C, B);

decode(cpl, S, C, B) when C#cs.len - C#cs.rlen > C#cs.csize ->
	case C#cs.csize =< byte_size(B) of
		true ->
		%	?LOG(?MODULE, self(), "part packet: len ~w, rlen ~w, <<~w>>", [C#cs.len, C#cs.rlen, byte_size(B)]),
			{Pl, R} = split_binary(B, C#cs.csize),
			?MODULE:decode(bh, S, C#cs{rlen = C#cs.rlen + C#cs.csize, data = <<(C#cs.data)/binary, Pl/binary>>}, R);
		false ->
		%	?LOG(?MODULE, self(), "no data (csize): len ~w, rlen ~w, <<~w>>", [C#cs.len, C#cs.rlen, byte_size(B)]),
			{noreply, {S#state{ns = cpl}, C, B}}
	end;

decode(cpl, S, C, B) ->
	Len = C#cs.len - C#cs.rlen,
	case Len =< byte_size(B) of
		true ->
		%	?LOG(?MODULE, self(), "end packet: len ~w, rlen ~w, <<~w>>", [C#cs.len, C#cs.rlen, byte_size(B)]),
			{Pl, R} = split_binary(B, Len),
			?MODULE:decode(md, S, C#cs{rlen = 0, data = <<(C#cs.data)/binary, Pl/binary>>}, R);
		false ->
		%	?LOG(?MODULE, self(), "no data: len ~w, rlen ~w, <<~w>>", [C#cs.len, C#cs.rlen, byte_size(B)]),
			{noreply, {S#state{ns = cpl}, C, B}}
	end;

decode(md, S, C, B) ->
	case C#cs.type of
		?RTMP_MSG_COMMAND_AMF0 ->
		%	?LOG(?MODULE, self(), "type RTMP_MSG_COMMAND_AMF0", []),
			Msg = amf0:decode_args(C#cs.data),
			?MODULE:decode(send, S, C#cs{data = <<>>}, B, {command, Msg});
		?RTMP_MSG_COMMAND_AMF3 ->
		%	?LOG(?MODULE, self(), "type RTMP_MSG_COMMAND_AMF3", []),
			<<Type:8, Data/binary>> = C#cs.data,
			Msg = case Type of 
				0 -> amf0:decode_args(Data);
				3 -> amf:decode(3, Data)
			end,
			?MODULE:decode(send, S, C#cs{data = <<>>}, B, {command, Msg});
		?RTMP_PCM_USER_CONTROL_MESSAGE ->
			<<EventType:16, EventData/binary>> = C#cs.data,
			case EventType of
				?RTMP_UCM_STREAM_BEGIN ->
					<<StreamID:32>> = EventData,
					?MODULE:decode(send, S, C#cs{data = <<>>}, B, {user_control_message, stream_begin, StreamID});
				?RTMP_UCM_STREAM_EOF ->
					<<StreamID:32>> = EventData,
					?MODULE:decode(send, S, C#cs{data = <<>>}, B, {user_control_message, stream_eof, StreamID});
				?RTMP_UCM_STREAM_IS_RECORDED ->
					<<StreamID:32>> = EventData,
					?MODULE:decode(send, S, C#cs{data = <<>>}, B, {user_control_message, stream_is_recorded, StreamID});
				?RTMP_UCM_SET_BUFFER_LENGTH ->
					<<StreamID:32, BufferLength:32>> = EventData,
					?MODULE:decode(send, S, C#cs{data = <<>>}, B, {user_control_message, set_buffer_length, StreamID, BufferLength})
			end;
		?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE ->
			<<Size:32>> = C#cs.data,
			?MODULE:decode(send, S, C#cs{data = <<>>}, B, {asknowledgement_window_size, Size});
		?RTMP_PCM_ACKNOWLEDGEMENT ->
			<<Size:32>> = C#cs.data,
			?MODULE:decode(send, S, C#cs{data = <<>>}, B, {asknowledgement, Size});
		?RTMP_MSG_AUDIO ->
			?MODULE:decode(send, S, C#cs{data = <<>>}, B, {audio, C#cs.data});
		?RTMP_MSG_VIDEO ->
			?MODULE:decode(send, S, C#cs{data = <<>>}, B, {video, C#cs.data});
		ANY_TYPE ->
			?LOG(?MODULE, self(), "Unknown type number: ~w", [ANY_TYPE]),
			{noreply, {S, C, B}}
	end.
	
decode(send, S, C, B, M) ->
	rtmp_stream:client_message(C#cs.stream, M),
	?MODULE:decode(bh, S, C, B).