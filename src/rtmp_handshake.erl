%%====================================================================
%% Description : RTMP handshake
%%====================================================================

-module(rtmp_handshake).

-author("Artem Ekimov <ekimov-artem@ya.ru>").

-include("rtmp.hrl").

-define(RTMP_HS_BODY_LEN, 1536).
-define(RTMP_UNCRYPTED_CONNECTION, 3).
-define(RTMP_ENCRYPTED_CONNECTION, 6).
-define(FLASH_CLIENT_OLD, v1).
-define(FLASH_CLIENT_NEW, v2).
-define(DH_KEY_SIZE, 128).
-define(DH_G, <<2>>).
-define(DH_P,
	<<16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
	  16#c9, 16#0f, 16#da, 16#a2, 16#21, 16#68, 16#c2, 16#34,
	  16#c4, 16#c6, 16#62, 16#8b, 16#80, 16#dc, 16#1c, 16#d1,
	  16#29, 16#02, 16#4e, 16#08, 16#8a, 16#67, 16#cc, 16#74,
	  16#02, 16#0b, 16#be, 16#a6, 16#3b, 16#13, 16#9b, 16#22,
	  16#51, 16#4a, 16#08, 16#79, 16#8e, 16#34, 16#04, 16#dd,
	  16#ef, 16#95, 16#19, 16#b3, 16#cd, 16#3a, 16#43, 16#1b,
	  16#30, 16#2b, 16#0a, 16#6d, 16#f2, 16#5f, 16#14, 16#37,
	  16#4f, 16#e1, 16#35, 16#6d, 16#6d, 16#51, 16#c2, 16#45,
	  16#e4, 16#85, 16#b5, 16#76, 16#62, 16#5e, 16#7e, 16#c6,
	  16#f4, 16#4c, 16#42, 16#e9, 16#a6, 16#37, 16#ed, 16#6b,
	  16#0b, 16#ff, 16#5c, 16#b6, 16#f4, 16#06, 16#b7, 16#ed,
	  16#ee, 16#38, 16#6b, 16#fb, 16#5a, 16#89, 16#9f, 16#a5,
	  16#ae, 16#9f, 16#24, 16#11, 16#7c, 16#4b, 16#1f, 16#e6,
	  16#49, 16#28, 16#66, 16#51, 16#ec, 16#e6, 16#53, 16#81,
	  16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff>>).
-define(GENUINE_FMS_KEY, 
	<<"Genuine Adobe Flash Media Server 001",
	  16#f0, 16#ee, 16#c2, 16#4a, 16#80, 16#68, 16#be, 16#e8,
	  16#2e, 16#00, 16#d0, 16#d1, 16#02, 16#9e, 16#7e, 16#57,
	  16#6e, 16#ec, 16#5d, 16#2d, 16#29, 16#80, 16#6f, 16#ab,
	  16#93, 16#b8, 16#e6, 16#36, 16#cf, 16#eb, 16#31, 16#ae>>).
-define(GENUINE_FP_KEY, 
	<<"Genuine Adobe Flash Player 001",
	  16#F0, 16#EE, 16#C2, 16#4A, 16#80, 16#68, 16#BE, 16#E8,
	  16#2E, 16#00, 16#D0, 16#D1, 16#02, 16#9E, 16#7E, 16#57,
	  16#6E, 16#EC, 16#5D, 16#2D, 16#29, 16#80, 16#6F, 16#AB,
	  16#93, 16#B8, 16#E6, 16#36, 16#CF, 16#EB, 16#31, 16#AE>>).

%% API external functions
-export([init/1]).

-define(HANDSHAKE_STATE, 
	#{
		socket      => undefined,
		version     => undefined,
		encrypted   => false,
		client_type => undefined,
		keyin       => undefined,
		keyout      => undefined
	}).

%%====================================================================
%% API functions
%%====================================================================

init(Socket) ->
	State = ?HANDSHAKE_STATE,
	handshake(State#{socket => Socket}).

handshake(State) ->
	handshake(init, State).

handshake(init, State) ->
	handshake(handshake_C0, State);

handshake(handshake_C0, #{socket := Socket} = State) ->
	case gen_tcp:recv(Socket, 1, 10000) of
		{ok, <<Version:8>>} ->
			case Version of
				?RTMP_UNCRYPTED_CONNECTION ->
					lager:debug("handshake: RTMP connection"),
					handshake(handshake_C1, State#{version => Version});
				?RTMP_ENCRYPTED_CONNECTION ->
					lager:debug("handshake: RTMPE connection"),
					handshake(handshake_C1, State#{version => Version, encrypted => true});
				true ->
					lager:error("handshake: nomatch Version: ~p", [Version]),
					{error, nomatch}
			end;
		{error, Reason} ->
			lager:error("handshake: gen_tcp:recv() error:~n~p", [Reason]),
			{error, Reason}
	end;

handshake(handshake_C1, #{socket := Socket} = State) ->
	case gen_tcp:recv(Socket, ?RTMP_HS_BODY_LEN, 10000) of
		{ok, C1} ->
			Type = get_client_type(C1),
			handshake({handshake_S0, C1}, State#{client_type => Type});
		{error, Reason} ->
			lager:error("handshake: gen_tcp:recv() error:~n~p", [Reason]),
			{error, Reason}
	end;

handshake({handshake_S0, C1}, #{version := ?RTMP_ENCRYPTED_CONNECTION, client_type := ClientType} = State) ->
	Bin = <<0:32, 3:8, 0:8, 2:8, 1:8, (crypto:rand_bytes(?RTMP_HS_BODY_LEN - 8))/binary>>,
	{_, ClientPublic, _} = get_dh_key(ClientType, C1),
	{ServerPublic, SharedSecret} = generate_dh(ClientPublic),
	{ServerFirst, _, ServerRest} = get_dh_key(ClientType, Bin),
	Response = <<ServerFirst/binary, ServerPublic/binary, ServerRest/binary>>,
	{KeyIn, KeyOut} = crypto_keys(ServerPublic, ClientPublic, SharedSecret),
	handshake({handshake_S1_S2, Response, C1}, State#{keyin => KeyIn, keyout => KeyOut});

handshake({handshake_S0, C1}, #{version := ?RTMP_UNCRYPTED_CONNECTION} = State) ->
	Response = <<0:32, 3:8, 0:8, 2:8, 1:8, (crypto:rand_bytes(?RTMP_HS_BODY_LEN - 8))/binary>>,
	handshake({handshake_S1_S2, Response, C1}, State);

handshake({handshake_S1_S2, Response, C1}, #{socket := Socket, version := Version, client_type := ClientType} = State) ->
	{Digest1, _, Digest2} = client_digest(ClientType, Response),
	{ServerFMSKey, _} = erlang:split_binary(?GENUINE_FMS_KEY, 36),
	ServerDigest = hmac256:digest_bin(ServerFMSKey, <<Digest1/binary, Digest2/binary>>),
	S1 = <<Digest1/binary, ServerDigest/binary, Digest2/binary>>,

	Response2 = crypto:rand_bytes(?RTMP_HS_BODY_LEN - 32),
	{_, ClientDigest, _} = client_digest(ClientType, C1),
	TempHash = hmac256:digest_bin(?GENUINE_FMS_KEY, ClientDigest),
	ClientHash = hmac256:digest_bin(TempHash, Response2),
	S2 = <<Response2/binary, ClientHash/binary>>,
	
	case gen_tcp:send(Socket, <<Version:8, S1/binary, S2/binary>>) of
		ok ->
			% lager:debug("handshake: send S1 and S2 ok"),
			handshake(handshake_C2, State);
		{error, Reason} ->
			lager:error("handshake: gen_tcp:send() error:~n~p", [Reason]),
			{error, Reason}
	end;

handshake(handshake_C2, #{socket := Socket, encrypted := Encrypted, keyin := KeyIn, keyout := KeyOut}) ->
	case gen_tcp:recv(Socket, ?RTMP_HS_BODY_LEN) of
		{ok, _C2} ->
			{ok, {Encrypted, KeyIn, KeyOut}};
		{error, Reason} ->
			lager:error("handshake: gen_tcp:recv() error:~n~p", [Reason]),
			{error, Reason}
	end.

%%--------------------------------------------------------------------

get_client_type(C1) ->
	case check_client_type(?FLASH_CLIENT_OLD, C1) of
		true -> ?FLASH_CLIENT_OLD;
		false -> 
			case check_client_type(?FLASH_CLIENT_NEW, C1) of
				true -> ?FLASH_CLIENT_NEW;
				false -> ?FLASH_CLIENT_OLD	
			end
	end.

check_client_type(Type, C1) ->
	{First, Seed, Rest} = client_digest(Type, C1),
	{Key, _} = erlang:split_binary(?GENUINE_FP_KEY, 30),
	Seed == hmac256:digest_bin(Key, <<First/binary, Rest/binary>>).

client_digest(?FLASH_CLIENT_OLD, <<_:8/binary, P1, P2, P3, P4, _/binary>> = C1) -> % Flash before 10.0.32.18
	Offset = (P1+P2+P3+P4) rem 728 + 12,
	% lager:debug("client_digest: Offset: ~p; ~p", [Offset, {P1, P2, P3, P4}]),
	client_digest(Offset, C1);

client_digest(?FLASH_CLIENT_NEW, <<_:772/binary, P1, P2, P3, P4, _/binary>> = C1) -> % Flash from 10.0.32.18
	Offset = (P1+P2+P3+P4) rem 728 + 776,
	% lager:debug("client_digest: Offset: ~p; ~p", [Offset, {P1, P2, P3, P4}]),
	client_digest(Offset, C1);

client_digest(Offset, C1) ->
	<<First:Offset/binary, Seed:32/binary, Rest/binary>> = C1,
	{First, Seed, Rest}.


get_dh_key(?FLASH_CLIENT_OLD, <<_:1532/binary, P1, P2, P3, P4, _/binary>> = C1) ->
	Offset = (P1+P2+P3+P4) rem 632 + 772,
	get_dh_key(Offset, C1);

get_dh_key(?FLASH_CLIENT_NEW, <<_:768/binary, P1, P2, P3, P4, _/binary>> = C1) ->
	Offset = (P1+P2+P3+P4) rem 632 + 8,
	get_dh_key(Offset, C1);

get_dh_key(Offset, C1) ->
	<<First:Offset/binary, Seed:?DH_KEY_SIZE/binary, Last/binary>> = C1,
	{First, Seed, Last}.

generate_dh(ClientPublic) ->
	P = <<(size(?DH_P)):32, ?DH_P/binary>>,
	G = <<(size(?DH_G)):32, ?DH_G/binary>>,
	{<<?DH_KEY_SIZE:32, ServerPublic:?DH_KEY_SIZE/binary>>, Private} = crypto:generate_key(dh, [P, G]),
	SharedSecret = crypto:compute_key(dh, <<(size(ClientPublic)):32, ClientPublic/binary>>, Private, [P, G]),
	{ServerPublic, SharedSecret}.

crypto_keys(ServerPublic, ClientPublic, SharedSecret) ->
	KeyOut1 = rc4_key(SharedSecret, ClientPublic),
	KeyIn1 = rc4_key(SharedSecret, ServerPublic),
	D1 = crypto:rand_bytes(?RTMP_HS_BODY_LEN),
	{KeyIn, D2} = crypto:stream_encrypt(KeyIn1, D1),
	{KeyOut, _} = crypto:stream_encrypt(KeyOut1, D2),
	{KeyIn, KeyOut}.

rc4_key(Key, Data) ->
	<<Out:16/binary, _/binary>> = hmac256:digest_bin(Key, Data),
	crypto:stream_init(rc4, Out).