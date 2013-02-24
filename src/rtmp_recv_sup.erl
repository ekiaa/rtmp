%%%-------------------------------------------------------------------
%%% File        : rtmp_recv_sup.erl
%%% Author      : Artem A. Ekimov <ekimov-artem@ya.ru>
%%% Description : Supervisor API and callbacks module
%%% Created     : 28.04.2012
%%%-------------------------------------------------------------------

-module(rtmp_recv_sup).

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
	{ok, {{simple_one_for_one, 1, 10}, [
		{undefined, {rtmp_recv, start, []}, temporary, 1000, worker, [rtmp_recv]}
	]}}.

	