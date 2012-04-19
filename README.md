Mixpanel Event Queue
====================

Transmit events to Mixpanel that were logged to a queue using RabbitMQ. Just
push the JSON representation of your event to a durable RabbitMQ queue called
`mixpanel`. *mixpanel-rabbit*  inserts your Mixpanel token, base64-encodes the
data and sends it to Mixpanel.

Erlang and RabbitMQ needs to be installed.

At the moment the queue name is hardwired to "mixpanel".

Usage
-----

Get the required libraries:

`./rebar get-deps`

Build the application:

`./rebar clean compile generate`

Edit `rel/mixpanel/releases/*/sys.config` and insert your Mixpanel token.

Run:

`./rel/mixpanel/bin/mixpanel start`

Deployment
----------

Copy `rel/mixpanel` to a folder on the destination server.
