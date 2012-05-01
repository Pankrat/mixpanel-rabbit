import json
import pika

from time import sleep

QUEUE = 'test_mp'


def connect():
    return pika.BlockingConnection(pika.ConnectionParameters(host='localhost'))

def open_channel(connection):
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE, durable=True, exclusive=False, auto_delete=False, callback=callback)
    return channel

def callback(*args, **kwargs):
    import sys; sys.stdout = sys.__stdout__; import ipdb; ipdb.set_trace()

def log_event(channel, event):
    data = dict(event=event, properties=dict())
    print ("LOG: " + json.dumps(data))
    properties = pika.BasicProperties(delivery_mode=2)
    channel.basic_publish(exchange='',
                          routing_key=QUEUE,
                          body="helloworld", #json.dumps(data),
                          properties=properties,
                          mandatory=True)


connection = connect()
sleep(1.0)
channel = open_channel(connection)
sleep(1.0)
log_event(channel, "login")
import sys; sys.stdout = sys.__stdout__; import ipdb; ipdb.set_trace()
channel.close()
connection.close()
