-module(amf0).
-author('ekimov-artem@ya.ru').
-compile(export_all).
-include("ptcl.hrl").

decode_args(Data) ->
	decode_args(Data, []).
decode_args(<<>>, List) ->
%	io:format("~ndecode_args: list = ~p~n", [List]),
	lists:reverse(List);
decode_args(Data, List) ->
%	Res = ?MODULE:decode(Data),
%	io:format("~ndecode_args:~nRes = ~p~nList = ~p~n", [Res, List]),
	case ?MODULE:decode(Data) of
		{decode, Element, Rest} ->
			decode_args(Rest, [Element | List]);
		Element ->
			decode_args(<<>>, [Element | List])
	end.

decode(<<>>) ->
	nil;
decode(Data) ->
	decode(value, [], empty, empty, Data).
	
decode(value, Stack, empty, empty, Data) ->
	decode(type, [{value, empty} | Stack], empty, empty, Data);
decode(value, [], empty, Value, <<>>) ->
	Value;
decode(value, [], empty, Value, Data) ->
	{decode, Value, Data};
decode(value, [{STATE, MSG} | Stack], empty, Value, Data) ->
	decode(STATE, Stack, MSG, Value, Data);

decode(map, Stack, Type, empty, Data) ->
	decode(mapkey, [{map, {Type, []}} | Stack], empty, empty, Data);
decode(map, [{STATE, MSG} | Stack], {notyped, Map}, mapend, Data) ->
	decode(STATE, Stack, MSG, {map, lists:reverse(Map)}, Data);
decode(map, [{STATE, MSG} | Stack], {Type, Map}, [], Data) ->
	decode(STATE, Stack, MSG, {map, Type, lists:reverse(Map)}, Data);
decode(map, Stack, {Type, Map}, KeyValue, Data) ->
	decode(mapkey, [{map, {Type, [KeyValue | Map]}} | Stack], empty, empty, Data);

decode(mapkey, [{STATE, MSG} | Stack], empty, empty, <<0:16, ?AMF0_OBJECTEND:8, Data/binary>>) ->
	decode(STATE, Stack, MSG, mapend, Data);	
decode(mapkey, Stack, empty, empty, <<L:16, MapKey:L/binary, Data/binary>>) ->
	decode(mapvalue, Stack, {?STRING, binary_to_list(MapKey)}, empty, Data);
	
decode(mapvalue, Stack, MapKey, empty, Data) ->
	decode(type, [{mapvalue, MapKey} | Stack], empty, empty, Data);
decode(mapvalue, [{STATE, MSG} | Stack], MapKey, MapValue, Data) ->
	decode(STATE, Stack, MSG, {MapKey, MapValue}, Data);
	
decode(array, Stack, {LA, Array}, empty, Data) ->
	decode(type, [{array, {LA-1, Array}} | Stack], empty, empty, Data);
decode(array, [{STATE, MSG} | Stack], {0, Array}, Value, Data) ->
	decode(STATE, Stack, MSG, lists:reverse([Value | Array]), Data);
decode(array, Stack, {LA, Array}, Value, Data) ->
	decode(type, [{array, {LA-1, [Value | Array]}} | Stack], empty, empty, Data);
	
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_NUMBER:8, NANs:8/binary, Data/binary>>) ->
	case NANs of
		?POS_INFINITY ->
			decode(STATE, Stack, MSG, {?FLOATNANS, ?POS_INFINITY}, Data);
		?NEG_INFINITY ->
			decode(STATE, Stack, MSG, {?FLOATNANS, ?NEG_INFINITY}, Data);
		?QNAN ->
			decode(STATE, Stack, MSG, {?FLOATNANS, ?QNAN}, Data);
		?SNAN ->
			decode(STATE, Stack, MSG, {?FLOATNANS, ?SNAN}, Data);
		<<Float:64/float>> ->
			decode(STATE, Stack, MSG, Float, Data);
		Bin ->
			decode(STATE, Stack, MSG, {?FLOATNANS, Bin}, Data)
	end;
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_BOOL:8, 0:8, Data/binary>>) ->
	decode(STATE, Stack, MSG, false, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_BOOL:8, _:8, Data/binary>>) ->
	decode(STATE, Stack, MSG, true, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_STRING:8, L:16, String:L/binary, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?STRING, binary_to_list(String)}, Data);
decode(type, Stack, empty, empty, <<?AMF0_OBJECT:8, Data/binary>>) ->
	decode(map, Stack, notyped, empty, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_NULL:8, Data/binary>>) ->
	decode(STATE, Stack, MSG, null, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_UNDEFINED:8, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?AMF0_UNDEFINED, <<>>}, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_REFERENCE:8, Num:2/binary, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?AMF0_REFERENCE, Num}, Data);
decode(type, Stack, empty, empty, <<?AMF0_ECMAARRAY:8, _Size:32, Data/binary>>) ->
	decode(map, Stack, [], empty, Data);
decode(type, Stack, empty, empty, <<?AMF0_STRICTARRAY:8, Size:32, Data/binary>>) ->
	decode(array, Stack, {Size, []}, empty, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_DATE:8, Date:10/binary, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?AMF0_DATE, Date}, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_LONGSTRING:8, L:32, String:L/binary, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?STRING, binary_to_list(String)}, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_UNSUPPORTED:8, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?AMF0_UNSUPPORTED, <<>>}, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_XMLDOCUMENT:8, L:32, String:L/binary, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?AMF0_XMLDOCUMENT, <<L:32, String/binary>>}, Data);
decode(type, Stack, empty, empty, <<?AMF0_TYPEDOBJECT:8, L:16, Class:L/binary, Data/binary>>) ->
	decode(map, Stack, {?STRING, Class}, empty, Data);
decode(type, [{STATE, MSG} | Stack], empty, empty, <<?AMF0_AVMPLUSOBJECT:8, Data/binary>>) ->
	decode(STATE, Stack, MSG, {?AMF0_AVMPLUSOBJECT, Data}, <<>>);
	
decode(Type, Stack, Msg, Value, Data) ->
	io:format("~w (~w): amf0 decode error:~nType = ~p~nStack = ~p~nMsg = ~p~nValue = ~p~nData = ~p~n", [?MODULE, self(), Type, Stack, Msg, Value, Data]),
	null.
	
	

encode_args(List) ->
	encode_args(List, <<>>).
encode_args([], Data) ->
	Data;
encode_args([Element | List], Data) ->
	Bin = ?MODULE:encode(Element),
%	io:format("~nencode_args: ~p~n", [List]),
	encode_args(List, <<Data/binary, Bin/binary>>).
	
encode(Msg) ->
	encode(value, [], Msg, <<>>).
	
encode(value, [], empty, Data) ->
	Data;
encode(value, [], Msg, Data) ->
	encode(type, [{value, empty}], Msg, Data);
	
encode(float, [{STATE, MSG} | Stack], Number, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_NUMBER:8, Number:64/float>>);
	
encode(string, [{STATE, MSG} | Stack], String, Data) ->
	Bin = list_to_binary(String),
	Len = byte_size(Bin),
	Type = if
		Len < 16#10000 ->
			<<?AMF0_STRING:8, Len:16>>;
		true ->
			<<?AMF0_LONGSTRING:8, Len:32>>
	end,
	encode(STATE, Stack, MSG, <<Data/binary, Type/binary, Bin/binary>>);
	
encode(array, [{STATE, MSG} | Stack], {0, []}, Data) ->
	encode(STATE, Stack, MSG, Data);
encode(array, Stack, {LA, [Element | Array]}, Data) ->
	encode(type, [{array, {LA-1, Array}} | Stack], Element, Data);
encode(array, Stack, Array, Data) ->
	LA = erlang:length(Array),
	encode(array, Stack, {LA, Array}, <<Data/binary, ?AMF0_STRICTARRAY:8, LA:32>>);
	
encode(map, [{STATE, MSG} | Stack], [], Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, 0:16, ?AMF0_OBJECTEND:8>>);
encode(map, Stack, {[], List}, Data) ->
	encode(map, Stack, List, <<Data/binary, ?AMF0_OBJECT:8>>);
encode(map, Stack, {{?STRING, ClassName}, List}, Data) ->
	Len = byte_size(ClassName),
	encode(map, Stack, List, <<Data/binary, ?AMF0_TYPEDOBJECT:8, Len:16, ClassName/binary>>);
encode(map, Stack, [Element | List], Data) ->
	encode(mapkey, [{map, List} | Stack], Element, Data);
	
encode(mapkey, Stack, {{?STRING, Key}, Value}, Data) ->
	Bin = list_to_binary(Key),
	Len = byte_size(Bin),
	encode(type, Stack, Value, <<Data/binary, Len:16, Bin/binary>>);	
	
encode(type, Stack, Msg, Data) when is_integer(Msg) ->
	encode(float, Stack, Msg, Data);
encode(type, Stack, Msg, Data) when is_float(Msg) ->
	encode(float, Stack, Msg, Data);
encode(type, Stack, Msg, Data) when is_binary(Msg) ->
	encode(raw, Stack, Msg, Data);
encode(type, Stack, Msg, Data) when is_list(Msg) ->
	encode(array, Stack, Msg, Data);
encode(type, [{STATE, MSG} | Stack], null, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_NULL:8>>);
encode(type, [{STATE, MSG} | Stack], true, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_BOOL:8, 1:8>>);
encode(type, [{STATE, MSG} | Stack], false, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_BOOL:8, 0:8>>);
encode(type, Stack, {map, Map}, Data) ->
	encode(map, Stack, {[], Map}, Data);
encode(type, Stack, {map, ClassName, Map}, Data) ->
	encode(map, Stack, {ClassName, Map}, Data);
encode(type, [{STATE, MSG} | Stack], {?BINARY, _Binary}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_NULL:8>>);
encode(type, Stack, {?STRING, String}, Data) ->
	encode(string, Stack, String, Data);
encode(type, [{STATE, MSG} | Stack], {?FLOATNANS, NANs}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_NUMBER:8, NANs/binary>>);
encode(type, [{STATE, MSG} | Stack], {?AMF0_UNDEFINED, <<>>}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_UNDEFINED:8>>);
encode(type, [{STATE, MSG} | Stack], {?AMF0_REFERENCE, Num}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_REFERENCE:8, Num/binary>>);
encode(type, [{STATE, MSG} | Stack], {?AMF0_DATE, Date}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_DATE:8, Date/binary>>);
encode(type, [{STATE, MSG} | Stack], {?AMF0_UNSUPPORTED, <<>>}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_UNSUPPORTED:8>>);
encode(type, [{STATE, MSG} | Stack], {?AMF0_XMLDOCUMENT, XMLDocument}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_XMLDOCUMENT:8, XMLDocument/binary>>);
encode(type, [{STATE, MSG} | Stack], {?AMF0_AVMPLUSOBJECT, ObjData}, Data) ->
	encode(STATE, Stack, MSG, <<Data/binary, ?AMF0_AVMPLUSOBJECT:8, ObjData/binary>>);
	
encode(Type, Stack, Msg, Data) ->
	io:format("~w (~w): amf0 encode error:~nType = ~p~nStack = ~p~nMsg = ~p~nData = ~p~n", [?MODULE, self(), Type, Stack, Msg, Data]),
	<<?AMF0_NULL:8>>.

-define(TEST_MSG,
		[
			{<<?STRING:8>>, <<"Test message for AMF0 module">>},
			1,
			1.0,
			true,
			false,
			null,
			{map, [
				{{<<?STRING:8>>, <<"Property 1">>}, {<<?STRING:8>>, <<"Value 1">>}}
			]}
		]
	).
-define(TEST_COUNT, 1000).
-define(TEST_LIST, [?AMF0_NUMBER]).

	
test_msg() ->
	io:format("Test message:~n~p~n", [?TEST_MSG]),
	test_msg(?TEST_MSG).
test_msg(Msg) ->
	{Te, Bin} = timer:tc(?MODULE, encode, [Msg]),
	Size = byte_size(Bin),
	{Td, _Res} = timer:tc(?MODULE, decode, [Bin]),
	{round(Te/1000), round(Td/1000), Size}.
	
test() ->
	test(?TEST_COUNT).
test(Count) ->
	F = fun(Type) ->
		{Name, Msg} = get_test_msg(Type, Count),
		Res = test_msg(Msg),
		io:format("Test: ~w (~w), count: ~w, result: ~w~n", [Name, Type, Count, Res])
	end,
	lists:foreach(F, ?TEST_LIST).
	
get_test_msg(?AMF0_NUMBER, Count) ->
	{number, get_msg(-1*math:pi(), Count)}.
	
get_msg(Value, Count) ->
	get_msg(Value, Count, []).
get_msg(_Value, 0, List) ->
	lists:reverse(List);
get_msg(Value, Count, List) ->
	get_msg(Value, Count-1, [Value | List]).