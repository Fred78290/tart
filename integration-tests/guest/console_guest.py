#!/usr/bin/env python3
import os
import time


def readmessage(fd):
    while True:
        data = fd.read(8)
        if data:
            length = int.from_bytes(data, byteorder='big')

            print("Expected message length: {0}".format(length))

            response = bytearray()

            while length > 0:
                data = fd.read(min(8192, length))
                if data:
                    length -= len(data)
                    response.extend(data)

            with open("received.txt", "w") as text_file:
                text_file.write(response.decode())

            return response

def writemessage(fd, message):
    length = len(message).to_bytes(8, "big")

    print("Send message length: {0}".format(len(message)))

    fd.write(length)
    fd.write(message)

message = bytearray()

with open("/dev/virtio-ports/tart-agent", "rb") as pipe:
    message = readmessage(pipe)
    pipe.close()

with open("/dev/virtio-ports/tart-agent", "wb") as pipe:
    writemessage(pipe, message)
    time.sleep(1)
    pipe.close()
