# encoding: utf-8
import os
import sys
import struct
import socket
import tarantool
sql.set_schema({
    0 : {
        'default_type' : tarantool.STR,
        'fields' : {
            0 : tarantool.NUM
            },
        'indexes' : {
            0 : [0] # HASH
            }
        }
    })

print """
#
# iproto packages test
#
"""

# opeing new connection to tarantool/box
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', server.primary_port))

print """
# Test bug #899343 (server assertion failure on incorrect packet)
"""
print "# sending the package with invalid length"
inval_request = struct.pack('<LLL', 17, 4294967290, 1)
print s.send(inval_request)
print "# checking what is server alive"
sql.ping(notime=True)

# closing connection
s.close()
