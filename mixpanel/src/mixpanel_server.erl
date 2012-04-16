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
    application:start(inets),
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
    Data = binary_to_list(Payload),
    Url = string:concat("http://api.mixpanel.com/track/?", Data),
    io:format("DEBUG: ~p~n", [Url]), 
    {ok, ReqId} = httpc:request(get, {Url, []}, [], [{sync, false}]),
    % Store ReqId->Tag in dict and acknowledge when response is received
    NewState = State#consumer_state{map = dict:store(ReqId, Tag, Map)},
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

