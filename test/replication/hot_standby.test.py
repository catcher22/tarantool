# encoding: utf-8
import os
import time
from lib.tarantool_server import TarantoolServer

# master server
master = server

# hot standby server
hot_standby = TarantoolServer()
hot_standby.deploy("replication/cfg/hot_standby.cfg",
                   hot_standby.find_exe(self.args.builddir),
                   os.path.join(self.args.vardir, "hot_standby"), need_init=False)

# replica server
replica = TarantoolServer()
replica.deploy("replication/cfg/replica.cfg",
               replica.find_exe(self.args.builddir),
               os.path.join(self.args.vardir, "replica"))

# Begin tuple id
id = 1


print """
# Insert 10 tuples to master
"""
for i in range(id, id + 10):
    master.sql.insert(0, (i, 'the tuple ' + str(i)))


print """
# Select 10 tuples from master
"""
for i in range(id, id + 10):
    master.sql.select(0, i)


print """
# Select 10 tuples from replica
"""
replica.wait_lsn(11)
for i in range(id, id + 10):
    replica.sql.select(0, i)


print """
# Shutdown master server (now the hot_standby must be a primary server)
"""
server.stop()

id += 10

# White while hot_standby server not bind masters ports
time.sleep(0.2)

print """
# Insert 10 tuples to hot_standby
"""
for i in range(id, id + 10):
    hot_standby.sql.insert(0, (i, 'the tuple ' + str(i)))


print """
# Select 10 tuples from hot_standby
"""
for i in range(id, id + 10):
    hot_standby.sql.select(0, i)


print """
# Select 10 tuples from replica
"""
replica.wait_lsn(21)
for i in range(id, id + 10):
    replica.sql.select(0, i)


# Cleanup.
hot_standby.stop()
hot_standby.cleanup(True)
replica.stop()
replica.cleanup(True)
server.deploy(self.suite_ini["config"])

# vim: syntax=python
