-module(mixpanel_server).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(QUEUE_NAME, <<"mixpanel">>).

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
    QDeclare = #'queue.declare'{queue = ?QUEUE_NAME, durable = true},
    #'queue.declare_ok'{queue = Queue} = amqp_channel:call(Channel, QDeclare),
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
    io:format("DEBUG: ~p~n", [Url]), 
    {ok, ReqId} = httpc:request(get, {Url, []}, [{timeout, 2000}], [{sync, false}]),
    % Store ReqId->Tag in dict and acknowledge when response is received
    NewState = State#consumer_state{map = dict:store(ReqId, Tag, Map)},
    {noreply, NewState};

% HTTP error. Most likely a connection or response timeout. Instruct RabbitMQ
% to put the event back into the queue. TODO: There should be an upper limit
% for requeuing per message or timeframe.
handle_info({http, {ReqId, {error, HttpError}}}, 
            State = #consumer_state{channel = Channel, map = Map}) ->
    Tag = dict:fetch(ReqId, Map),
    amqp_channel:cast(Channel, #'basic.reject'{delivery_tag = Tag, requeue = true}),
    io:format("ERROR [http]: ~p~n", [HttpError]),
    NewState = State#consumer_state{map = dict:erase(ReqId, Map)},
    {noreply, NewState};

handle_info({http, {ReqId, Result}}, 
            State = #consumer_state{channel = Channel, map = Map}) ->
    Tag = dict:fetch(ReqId, Map),
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag}),
    {{_, Code, _}, _Headers, Body} = Result,
    io:format("DEBUG [http]: Code=~p Body=~p~n", [Code, Body]),
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

-endif.
