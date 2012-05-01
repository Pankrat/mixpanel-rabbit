-module(client).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([send/1, recv/0, logevent/0]).

-define(QUEUE_NAME, <<"mixpanel">>).


connect(QueueName) ->
    {ok, Connection} = amqp_connection:start(#amqp_params_network{}),
    {ok, Channel} = amqp_connection:open_channel(Connection),

    QDeclare = #'queue.declare'{queue = QueueName, durable = true},
    #'queue.declare_ok'{queue = Queue} = amqp_channel:call(Channel, QDeclare),
    {Connection, Channel, Queue}.

send(Payload) -> 
    {Connection, Channel, Queue} = connect(?QUEUE_NAME),

    %% Publish a message
    Publish = #'basic.publish'{exchange = <<>>, routing_key = Queue},
    amqp_channel:cast(Channel, Publish, #amqp_msg{payload = Payload}),

    amqp_channel:close(Channel),
    amqp_connection:close(Connection),

    ok.

recv() ->
    {Connection, Channel, Queue} = connect(?QUEUE_NAME),

    Get = #'basic.get'{queue = Queue},
    {#'basic.get_ok'{delivery_tag = Tag}, Content} = amqp_channel:call(Channel, Get),

    #amqp_msg{payload = Payload} = Content,
    io:format("DEBUG: Received message ~s.~n", [Payload]),

    %% Ack the message
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag}),

    amqp_channel:close(Channel),
    amqp_connection:close(Connection),

    Payload.

logevent() ->
    send(<<"{\"event\": \"login\", \"properties\": {}}">>).

