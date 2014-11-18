%%====================================================================
%% Description: RTMP application supervisor for rtmp_recv
%%====================================================================

-module(rtmp_recv_sup).
-copyright("LiveTex").
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-10").
-version("0.1").

%%--------------------------------------------------------------------

-bahaviour(supervisor).

-include("rtmp.hrl").

%% API functions
-export([start/0, start_link/0, start_recv/1]).

%% supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================

start() ->
	start_link().

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_recv(Args) ->
	supervisor:start_child(?MODULE, Args).

%%====================================================================
%% supervisor callbacks
%%====================================================================

init([]) ->
	{ok, {{simple_one_for_one, 1, 10}, [
		{undefined, {rtmp_recv, start_link, []}, temporary, 1000, worker, [rtmp_recv]}
	]}}.

	