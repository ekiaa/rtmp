%%====================================================================
%% Description : Supervisor API and callbacks module
%%====================================================================

-module(rtmp_publish_sup).

-author("Artem Ekimov <ekimov-artem@ya.ru>").

-bahaviour(supervisor).

-include("rtmp.hrl").

%% API functions
-export([start/0, start_link/0, start_child/0]).

%% supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================

start() ->
	start_link().

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child() ->
	supervisor:start_child(?MODULE, []).

%%====================================================================
%% supervisor callbacks
%%====================================================================

init([]) ->
	{ok, {{simple_one_for_one, 1, 10}, [
		{undefined, {gen_event, start_link, []}, temporary, 1000, worker, dynamic}
	]}}.

	