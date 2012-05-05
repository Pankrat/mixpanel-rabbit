import json
import pika

from time import sleep

QUEUE = 'mixpanel'


def connect():
    return pika.BlockingConnection(pika.ConnectionParameters(host='localhost'))

def open_channel(connection):
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE, durable=True, exclusive=False, auto_delete=False)
    return channel

def log_event(channel, event):
    data = dict(event=event, properties=dict())
    print ("LOG: " + json.dumps(data))
    properties = pika.BasicProperties(delivery_mode=2)
    channel.basic_publish(exchange='',
                          routing_key=QUEUE,
                          body=json.dumps(data),
                          properties=properties,
                          mandatory=True)


connection = connect()
channel = open_channel(connection)
try:
    while True:
        log_event(channel, "login")
        sleep(1.0)
finally:
    #channel.close()
    connection.close()
