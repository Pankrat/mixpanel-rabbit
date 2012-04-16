Mixpanel Event Queue
====================

Transmit events to Mixpanel that were logged to a queue using RabbitMQ. Erlang
and RabbitMQ needs to be installed.

At the moment the queue name is hardwired to "mixpanel".

Usage
-----

Get the required libraries:

`./rebar get-deps`

Build the application:

`./rebar clean compile generate`

Run:

`./rel/mixpanel/bin/mixpanel start`
