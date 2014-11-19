%%====================================================================
%% Description: RTMP application supervisor
%%====================================================================

-module(rtmp_sup).
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

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
		{rtmp_event, {gen_event, start_link, [{local, rtmp_event}]}, permanent, 1000, worker, dynamic},
		{rtmp_channel_sup, {rtmp_channel_sup, start, []}, permanent, infinity, supervisor, [rtmp_channel_sup]},
		{rtmp_decode_sup, {rtmp_decode_sup, start, []}, permanent, infinity, supervisor, [rtmp_decode_sup]},
		{rtmp_encode_sup, {rtmp_encode_sup, start, []}, permanent, infinity, supervisor, [rtmp_encode_sup]},
		{rtmp_publish_sup, {rtmp_publish_sup, start, []}, permanent, infinity, supervisor, [rtmp_publish_sup]},
		{rtmp_accept, {rtmp_accept, start, []}, permanent, 5000, worker, [rtmp_accept]}
	]}}.

	