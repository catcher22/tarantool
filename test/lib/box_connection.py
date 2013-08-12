__author__ = "Konstantin Osipov <kostja.osipov@gmail.com>"

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

import os
import sys
import sql
import copy
import errno
import socket
import struct
import warnings
import yaml 
from tarantool_connection import TarantoolConnection

from pprint import pprint

try:
    inspect = __import__('inspect', globals(), locals(), [], -1)
    abspath = os.path.split(inspect.getfile(inspect.currentframe()))[0]
    tnt_path = os.path.join(abspath,'tarantool-python/src/')
    print tnt_path
    sys.path.append(tnt_path)
    import tarantool
except (ImportError, OSError) as e:
    raise

def log_call_log(function, boxcon, *args, **kwargs):
    def merge_args():
        ans = ""
        for i in args:
            i = ("'%s'" % i if isinstance(i, basestring) else str(i))
            ans = (i if not ans else ans + ", " + i)
        for i, j in kwargs.items():
            j = ("'%s'" % (i, j) if isinstance(j, basestring) else str(j))
            ans = (i + ' = ' + j if not ans else ans + ", %s = %s" % (i, j))
        return ans
    def print_tuple(t):
        return ("".join(["['", str(t[0]), "'"] + 
                       map(lambda x: ", '"+str(x)+"'", t[1:]) + 
                       ["]"]
                       )
               ) if t else []
   
    error = False
    warnings.simplefilter("ignore")
    print "%s(%s)" % (function.func_name, merge_args())
    print "---\n"
    try:
        if function.func_name == 'ping':
            kwargs['notime'] = True
        else:
            kwargs['return_tuple'] = True
        ans = function(*args, **kwargs)
        if function.func_name != 'ping' and boxcon.sort:
            ans = sorted(ans)
    except tarantool.DatabaseError as e:
        error = True
        ans = "Error: " + str(e.args)
    if error or function.func_name == 'ping':
        print ans + "\n"
    elif not ans[:]:
        print "No match\n"
    else:
        for i in ans:
            print " - ", print_tuple(i)
    print "..."
    return ans

class BoxConnection(TarantoolConnection):
    def __init__(self, host, port):
        super(BoxConnection, self).__init__(host, port)
        self.newcon = tarantool.Connection(host, port, 
                connect_now=False, reconnect_max_attempts=2, socket_timeout=None)
        self.space = {}
        self.sort = False
    def recvall(self, length):
        res = ""
        while len(res) < length:
            buf = self.socket.recv(length - len(res))
            if not buf:
                raise RuntimeError("Got EOF from socket, the server has "
                                   "probably crashed")
            res = res + buf
        return res

    def execute_no_reconnect(self, command, silent=True):
        statement = sql.parse("sql", command)
        if statement == None:
            return "You have an error in your SQL syntax\n"
        statement.sort = self.sort

        payload = statement.pack()
        header = struct.pack("<lll", statement.reqeust_type, len(payload), 0)

        self.socket.sendall(header)
        if len(payload):
            self.socket.sendall(payload)

        IPROTO_HEADER_SIZE = 12

        header = self.recvall(IPROTO_HEADER_SIZE)

        response_len = struct.unpack("<lll", header)[1]

        if response_len:
            response = self.recvall(response_len)
        else:
            response = None

        if not silent:
            print command
            print statement.unpack(response)

        return statement.unpack(response) + "\n"

    def set_schema(self, schema_dict):
        self.newcon.schema = tarantool.Schema(schema_dict)

    def insert(self, *args, **kwargs):
        kwargs['not_presented'] = True
        return log_call_log(self.newcon.insert, self, *args, **kwargs)

    def replace(self, *args, **kwargs):
        return log_call_log(self.newcon.insert, self, *args, **kwargs)

    def delete(self, *args, **kwargs):
        return log_call_log(self.newcon.delete, self, *args, **kwargs)

    def update(self, *args, **kwargs):
        return log_call_log(self.newcon.update, self, *args, **kwargs)

    def select(self, *args, **kwargs):
        return log_call_log(self.newcon.select, self, *args, **kwargs)

    def call  (self, *args, **kwargs):
        return log_call_log(self.newcon.call  , self, *args, **kwargs)

    def ping  (self,  *args, **kwargs):
        return log_call_log(self.newcon.ping  , self, *args, **kwargs)
