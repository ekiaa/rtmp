-module(amf).
-compile(export_all).


decode(0, Data) ->
	amf0:decode(Data);

decode(3, <<0:8, Data/binary>>) ->
	decode_amf0(Data);

decode(3, <<3:8, Data/binary>>) ->
	decode_amf3(Data);

decode(_N, _Data) ->
	[].
	
decode_amf0(Data) ->
	decode_amf0(Data, []).
	
decode_amf0(<<>>, Msg) ->
	lists:reverse(Msg);
	
decode_amf0(Data, Msg) ->
	{AMF, Rest} = amf0:decode(Data),
	decode_amf0(Rest, [AMF | Msg]).
	
decode_amf3(Data) ->
	decode_amf3(Data, []).

decode_amf3(<<>>, Msg) ->
	lists:reverse(Msg);
	
decode_amf3(Data, Msg) ->
	{AMF, Rest} = amf3:decode(Data),
	decode_amf3(Rest, [AMF | Msg]).
	
encode(0, Msg) ->
	amf0:encode(Msg);
	
encode(3, Msg) ->
	amf3:encode(Msg);

encode(_N, _Msg) ->
	<<>>.
	
encode_amf0([], Data) ->
	Data;
	
encode_amf0([Value | Rest], Data) ->
	Bin = amf0:encode(Value),
	encode_amf0(Rest, <<Data/binary, Bin/binary>>).
	
encode_amf3([], Data) ->
	Data;
	
encode_amf3([Value | Rest], Data) ->
	Bin = amf0:encode(Value),
	encode_amf0(Rest, <<Data/binary, Bin/binary>>).
	
-define(AMF0_NUMBER, 16#00).
-define(TEST_COUNT, 1000).
-define(TEST_LIST, [?AMF0_NUMBER]).

	
%test_msg() ->
%	io:format("Test message:~n~p~n", [?TEST_MSG]),
%	test_msg(?TEST_MSG).
test_msg(Msg) ->
	{Te, Bin} = timer:tc(amf, encode, [0, Msg]),
	Size = byte_size(Bin),
	{Td, _Res} = timer:tc(amf, decode, [0, Bin]),
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