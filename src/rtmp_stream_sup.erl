%%%-------------------------------------------------------------------
%%% File        : rtmp_stream_sup.erl
%%% Author      : Artem A. Ekimov <ekimov-artem@ya.ru>
%%% Description : Supervisor API and callbacks module
%%% Created     : 28.04.2012
%%%-------------------------------------------------------------------

-module(rtmp_stream_sup).

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
		{undefined, {rtmp_stream, start_link, []}, temporary, 1000, worker, [rtmp_stream]}
	]}}.

	