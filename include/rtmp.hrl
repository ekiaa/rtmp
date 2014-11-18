-define(APPLICATION, rtmp).
-define(SERVER, rtmp).
-define(ACCEPT, rtmp_accept).
-define(RTMP_ACCEPT, rtmp_accept).
-define(CORE, rtmp_core).
-define(REGISTER, rtmp_streams).
-define(CHANNEL_SUP, rtmp_channel_sup).
-define(STREAM_SUP, rtmp_stream_sup).
-define(DECODE_SUP, rtmp_decode_sup).
-define(ENCODE_SUP, rtmp_encode_sup).
-define(RECV_SUP, rtmp_recv_sup).
-define(SEND_SUP, rtmp_send_sup).
-define(TABLE_STREAMS, streams).
-define(TITLE_LENGTH, "16").
-define(LOG(M,P,F,D), lager:debug(F,D)).

%%% PCM - Protocol Control Message					
													
-define(RTMP_PCM_SET_CHUNK_SIZE, 					1).
-define(RTMP_PCM_ABORT_MESSAGE, 					2).
-define(RTMP_PCM_ACKNOWLEDGEMENT, 					3).
-define(RTMP_PCM_USER_CONTROL_MESSAGE, 				4).
-define(RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE,		5).
-define(RTMP_PCM_SET_PEER_BANDWIDTH, 				6).
													
%%% UCM - User Control Message						
													
-define(RTMP_UCM_STREAM_BEGIN, 						0).
-define(RTMP_UCM_STREAM_EOF, 						1).
-define(RTMP_UCM_STREAM_DRY, 						2).
-define(RTMP_UCM_SET_BUFFER_LENGTH, 				3).
-define(RTMP_UCM_STREAM_IS_RECORDED,			 	4).
-define(RTMP_UCM_PING_REQUEST,					 	6).
-define(RTMP_UCM_PING_RESPONSE,		 				7).
													
%%% MSG - Any type of RTMP messages					
													
-define(RTMP_MSG_AUDIO, 							8).
-define(RTMP_MSG_VIDEO, 							9).
-define(RTMP_MSG_DATA_AMF3, 						15).
-define(RTMP_MSG_SHARED_OBJECT_AMF3, 				16).
-define(RTMP_MSG_COMMAND_AMF3,						17).
-define(RTMP_MSG_DATA_AMF0, 						18).
-define(RTMP_MSG_SHARED_OBJECT_AMF0, 				19).
-define(RTMP_MSG_COMMAND_AMF0, 						20).
-define(RTMP_MSG_AGGREGATE,	 						22).
													
%%% CONST - Any RTMP constant						
													
-define(RTMP_CONST_CHUNK_SIZE, 						128).
-define(RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE, 	16#2625A0).
													
%%% CMD - Any RTMP commands							
													
-define(RTMP_CMD_PCM_SET_CHUNK_SIZE(Size),					{?RTMP_PCM_SET_CHUNK_SIZE, Size}).
-define(RTMP_CMD_PCM_ACKNOWLEDGEMENT(Size),					{?RTMP_PCM_ACKNOWLEDGEMENT, Size}).
-define(RTMP_CMD_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE,			{?RTMP_PCM_ACKNOWLEDGEMENT_WINDOW_SIZE, 
																?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE}).
-define(RTMP_CMD_PCM_SET_PEER_BANDWIDTH,					{?RTMP_PCM_SET_PEER_BANDWIDTH, 
																{?RTMP_CONST_ACKNOWLEDGEMENT_WINDOW_SIZE, 2}}).
-define(RTMP_CMD_UCM_STREAM_BEGIN(N), 						{?RTMP_PCM_USER_CONTROL_MESSAGE, 
																	{?RTMP_UCM_STREAM_BEGIN, N}}).
-define(RTMP_CMD_AMF0,										1).
-define(RTMP_CMD_AMF0_RTMPSAMPLEACCESS,						6). %		{?RTMP_MSG_DATA_AMF0, [{?STRING, "|RtmpSampleAccess">>, false, false]}).
-define(RTMP_CMD_AMF0_RESULT_CONNECT,						7).
-define(RTMP_CMD_AMF0_RESULT_CREATE_STREAM,					8).
-define(RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PUBLISH_START,		9).
-define(RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_UNPUBLISH_SUCCESS,	10).
-define(RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_START,		11).
-define(RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_RESET,		12).
-define(RTMP_CMD_AMF0_ONSTATUS_NETSTREAM_PLAY_STOP,			13).

-define(State, State#state). %{}
