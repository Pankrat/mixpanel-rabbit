-module(mixpanel_server).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(QUEUE_NAME, <<"mixpanel">>).

% How many events to transmit in parallel. This limits how many concurrent
% connections are opened to Mixpanel.
-define(MAX_CONCURRENT_REQUESTS, 20).

% After a transmission error requeue messages if there are less than the
% specified amount of messages in the queue. Otherwise drop it.
-define(REQUEUE_LIMIT, 10000).

% Timeout in milliseconds.
-define(MIXPANEL_TIMEOUT, 30000).

-record(consumer_state, {connection, channel, map}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    {ok, Connection} = amqp_connection:start(#amqp_params_network{}), 
    {ok, Channel} = amqp_connection:open_channel(Connection),
    Qos = #'basic.qos'{prefetch_count = ?MAX_CONCURRENT_REQUESTS},
    amqp_channel:call(Channel, Qos),
    Qdef = #'queue.declare'{queue = ?QUEUE_NAME, 
                            auto_delete = false,
                            exclusive = false,
                            durable = true},
    #'queue.declare_ok'{queue = Queue} = amqp_channel:call(Channel, Qdef),
    amqp_channel:subscribe(Channel, #'basic.consume'{queue = Queue}, self()), 
    Map = dict:new(),
    {ok, #consumer_state{connection = Connection, channel = Channel, map = Map}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info({#'basic.deliver'{delivery_tag = Tag}, 
             #amqp_msg{payload = Payload}},
            State = #consumer_state{map = Map}) -> 
    Url = mixpanel_url(Payload),
    {ok, ReqId} = httpc:request(get, 
                                {Url, []}, 
                                [{timeout, ?MIXPANEL_TIMEOUT}], 
                                [{sync, false}]),
    % Store ReqId->Tag in dict and acknowledge when response is received
    NewState = State#consumer_state{map = dict:store(ReqId, Tag, Map)},
    {noreply, NewState};

% HTTP error. Most likely a connection or response timeout. Instruct RabbitMQ
% to put the event back into the queue. If there are too many entries in the
% queue, drop the message.
handle_info({http, {ReqId, {error, HttpError}}}, 
            State = #consumer_state{channel = Channel, map = Map}) ->
    Tag = dict:fetch(ReqId, Map),
    QueueSize = messages_in_queue(Channel),
    Requeue = QueueSize < ?REQUEUE_LIMIT,
    io:format("WARNING [http]: Error=~p QueueSize=~p Requeue=~p~n", [HttpError, QueueSize, Requeue]),
    amqp_channel:cast(Channel, #'basic.reject'{delivery_tag = Tag, requeue = Requeue}),
    NewState = State#consumer_state{map = dict:erase(ReqId, Map)},
    {noreply, NewState};

handle_info({http, {ReqId, Result}}, 
            State = #consumer_state{channel = Channel, map = Map}) ->
    Tag = dict:fetch(ReqId, Map),
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag}),
    {{_, 200, _}, _Headers, <<"1">>} = Result,
    NewState = State#consumer_state{map = dict:erase(ReqId, Map)},
    {noreply, NewState}.

terminate(_Reason, #consumer_state{connection = Connection, channel = Channel}) ->
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

decode_json(Json) ->
    jiffy:decode(Json).

encode_json(Struct) ->
    jiffy:encode(Struct).

messages_in_queue(Channel) ->
    Qdef = #'queue.declare'{queue = ?QUEUE_NAME, 
                            exclusive = false, 
                            auto_delete = false,
                            durable = true,
                            passive = true},
    #'queue.declare_ok'{message_count = Cnt} = amqp_channel:call(Channel, Qdef),
    Cnt.

modify_properties(Properties, Token) ->
    Dict = dict:from_list(Properties),
    {Msec, Sec, _} = erlang:now(),
    UnixTime = Msec * 1000000 + Sec,
    Inject = [{<<"token">>, Token}, {<<"time">>, UnixTime}],
    TokenDict = dict:from_list(Inject),
    Merged = dict:merge(fun(_, V, _) -> V end, Dict, TokenDict),
    dict:to_list(Merged).

add_token(Raw, Token) ->
    {Data} = decode_json(Raw),
    Dict = orddict:from_list(Data),
    {Prop} = orddict:fetch(<<"properties">>, Dict),
    NewProp = modify_properties(Prop, Token),
    NewDict = orddict:store(<<"properties">>, {NewProp}, Dict),
    NewData = {orddict:to_list(NewDict)},
    encode_json(NewData).

get_token() ->
    {ok, Token} = application:get_env(mixpanel, token),
    Token.

mixpanel_url(Payload) ->
    ModPayload = add_token(Payload, get_token()),
    Data = base64:encode_to_string(ModPayload),
    string:concat("http://api.mixpanel.com/track/?data=", Data).

%%
%% Tests
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

modify_properties_test() ->
    [{<<"time">>, _}, {<<"token">>, <<"Duke">>}] = modify_properties([], <<"Duke">>),
    [{<<"time">>, _}, {<<"token">>, <<"Gonzo">>}] = modify_properties([{<<"token">>, <<"Gonzo">>}], <<"Duke">>),
    [{<<"time">>, 123}, {<<"token">>, <<"Duke">>}] = modify_properties([{<<"time">>, 123}], <<"Duke">>).

add_token_test() ->
    <<"{\"properties\":{\"time\":123,\"token\":\"Tom\"}}">> = 
        add_token(<<"{\"properties\":{\"time\":123}}">>, <<"Tom">>),
    <<"{\"event\":\"lunch\",\"properties\":{\"ip\":\"10.0.0.1\",\"time\":123,\"token\":\"Tanya\"}}">> = 
        add_token(<<"{\"event\":\"lunch\",\"properties\":{\"ip\":\"10.0.0.1\",\"time\":123}}">>, <<"Tanya">>),
    ok.

messages_in_queue_test() ->
    {ok, Connection} = amqp_connection:start(#amqp_params_network{}), 
    {ok, Channel} = amqp_connection:open_channel(Connection),
    0 = messages_in_queue(Channel),
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    ok.


-endif.
