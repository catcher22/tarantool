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
import socket
import struct
from tarantool_connection import TarantoolConnection

try:
    inspect = __import__('inspect', globals(), locals(), [], -1)
    abspath = os.path.split(inspect.getfile(inspect.currentframe()))[0]
    tnt_path = os.path.join(abspath,'tarantool-python/src/')
    print tnt_path
    sys.path.append(tnt_path)
    import tarantool
except (ImportError, OSError) as e:
    raise


class LogFunc(object):
    def __init__ (self, space=False):
        self.space = space

    def __call__(self, function):
        def log_call_log(self, *args, **kwargs):
            def merge_args():
                ans = ""
                for i in args:
                    i = ("'%s'" if isinstance(i, basestring) else str(i))
                    ans = (i if not ans else ans + ", " + i)
                for i, j in kwargs.items():
                    j = ("'%s'" if isinstance(j, basestring) else str(j))
                    ans = (i+'='+j if not ans else ans+", %s = %s"%(i, j))
                return ans
            fmt = "space[%d].%s(%s)\n" if self.space else "%s(%s)"
            if self.space:
                fmt = fmt % (function.im_self.space_no)
            formatted_string = fmt % (function.func_name, merge_args())
            sys.stdout.write(formatted_string)
            ans = function(*args, **kwargs)
            sys.stdout.write(str(ans))
            return ans
        return log_call_log

class BoxConnection(TarantoolConnection):
    def __init__(self, host, port):
        super(BoxConnection, self).__init__(host, port)
        self.newcon = tarantool.Connection(host, port, connect_now=False)
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

    def add_space(number):
        if number in self.space:
            return self.space[number]
        space = self.newcon.space(number)
        space._insert = copy.copy(space.insert)
        space.insert  = LogFunc(space=True)(space._insert) 
        space._delete = copy.copy(space.delete)
        space.delete  = LogFunc(space=True)(space._delete) 
        space._update = copy.copy(space.update)
        space.update  = LogFunc(space=True)(space._update) 
        space._select = copy.copy(space.select)
        space.select  = LogFunc(space=True)(space._select) 
        space._call   = copy.copy(space.call)
        space.call    = LogFunc(space=True)(space._call) 
        self.space[number] = space

    @LogFunc()
    def insert(self, *args, **kwargs):
        return self.newcon.insert(*args, **kwargs)
    @LogFunc()
    def delete(self, *args, **kwargs):
        return self.newcon.delete(*args, **kwargs)
    @LogFunc()
    def update(self, *args, **kwargs):
        return self.newcon.update(*args, **kwargs)
    @LogFunc()
    def select(self, *args, **kwargs):
        return self.newcon.select(*args, **kwargs)
    @LogFunc()
    def call  (self, *args, **kwargs):
        return self.newcon.call  (*args, **kwargs)
    @LogFunc()
    def ping  (self, *args, **kwargs):
        return self.newcon.ping  (*args, **kwargs)
