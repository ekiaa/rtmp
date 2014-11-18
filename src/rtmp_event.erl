%%====================================================================
%% Description: RTMP application event manager
%%====================================================================

-module(rtmp_event).
-copyright("LiveTex").
-author("Artem Ekimov <ekimov-artem@ya.ru>").
-date("2013-09-09").
-version("0.1").

%%--------------------------------------------------------------------

%% API functions
-compile(export_all).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
	lager:debug("rtmp_event:start_link()"),
	gen_event:start_link({local, ?MODULE}).

add_handler(Handler, Args) ->
	gen_event:add_handler(?MODULE, Handler, Args).

add_sup_handler(Handler, Args) ->
	gen_event:add_sup_handler(?MODULE, Handler, Args).

notify(Event) ->
	gen_event:notify(?MODULE, Event).

sync_notify(Event) ->
	gen_event:sync_notify(?MODULE, Event).

call(Handler, Request) ->
	gen_event:call(?MODULE, Handler, Request).

call(Handler, Request, Timeout) ->
	gen_event:call(?MODULE, Handler, Request, Timeout).

delete_handler(Handler, Args) ->
	gen_event:delete_handler(?MODULE, Handler, Args).

swap_handler({Handler1, Args1}, {Handler2, Args2}) ->
	gen_event:swap_handler(?MODULE, {Handler1, Args1}, {Handler2, Args2}).

swap_sup_handler({Handler1, Args1}, {Handler2, Args2}) ->
	gen_event:swap_sup_handler(?MODULE, {Handler1, Args1}, {Handler2, Args2}).

which_handlers() ->
	gen_event:which_handlers(?MODULE).

stop() ->
	gen_event:stop(?MODULE).