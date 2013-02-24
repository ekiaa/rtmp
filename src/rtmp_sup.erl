%%%-------------------------------------------------------------------
%%% File        : rtmp_sup.erl
%%% Author      : Artem A. Ekimov <ekimov-artem@ya.ru>
%%% Description : Supervisor API and callbacks module
%%% Created     : 28.04.2012
%%%-------------------------------------------------------------------

-module(rtmp_sup).

-bahaviour(supervisor).

-include("rtmp.hrl").

%% API functions

-export([start/0, start_link/0]).

%% supervisor callbacks

-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================

start() ->
	start_link().

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% supervisor callbacks
%%====================================================================

init([]) ->
	{ok, {{one_for_all, 1, 10}, [
		{rtmp_channel_sup, {rtmp_channel_sup, start, []}, permanent, infinity, supervisor, [rtmp_channel_sup]},
		{rtmp_stream_sup, {rtmp_stream_sup, start, []}, permanent, infinity, supervisor, [rtmp_stream_sup]},
		{rtmp_decode_sup, {rtmp_decode_sup, start, []}, permanent, infinity, supervisor, [rtmp_decode_sup]},
		{rtmp_encode_sup, {rtmp_encode_sup, start, []}, permanent, infinity, supervisor, [rtmp_encode_sup]},
		{rtmp_send_sup, {rtmp_send_sup, start, []}, permanent, infinity, supervisor, [rtmp_send_sup]},
		{rtmp_recv_sup, {rtmp_recv_sup, start, []}, permanent, infinity, supervisor, [rtmp_recv_sup]},
		{rtmp_accept, {rtmp_accept, start, []}, permanent, 1000, worker, [rtmp_accept]}
	]}}.

	