# encoding: utf-8
import os
import time
from lib.tarantool_server import TarantoolServer

REPEAT = 20
ID_BEGIN = 0
ID_STEP = 5

def insert_tuples(server, begin, end, msg = "tuple"):
    for i in range(begin, end):
        server.sql.insert(0, (i, msg + " " + str(i)))

def select_tuples(server, begin, end):
    # the last lsn is end id + 1
    server.wait_lsn(end + 1)
    for i in range(begin, end):
        server.sql.select(0, i)

# master server
master = server

# replica server
replica = TarantoolServer()
replica.deploy("replication/cfg/replica.cfg",
               replica.find_exe(self.args.builddir),
               os.path.join(self.args.vardir, "replica"))

id = ID_BEGIN
for i in range(REPEAT):
    print "test %d iteration" % i

    # insert to master
    insert_tuples(master, id, id + ID_STEP)
    # select from replica
    select_tuples(replica, id, id + ID_STEP)
    id += ID_STEP

    # insert to master
    insert_tuples(master, id, id + ID_STEP)
    # select from replica
    select_tuples(replica, id, id + ID_STEP)
    id += ID_STEP

    print "swap servers"
    # reconfigure replica to master
    replica.reconfigure("replication/cfg/replica_to_master.cfg", silent = False)
    # reconfigure master to replica
    master.reconfigure("replication/cfg/master_to_replica.cfg", silent = False)

    # insert to replica
    insert_tuples(replica, id, id + ID_STEP)
    # select from master
    select_tuples(master, id, id + ID_STEP)
    id += ID_STEP

    # insert to replica
    insert_tuples(replica, id, id + ID_STEP)
    # select from master
    select_tuples(master, id, id + ID_STEP)
    id += ID_STEP

    print "rollback servers configuration"
    # reconfigure replica to master
    master.reconfigure("replication/cfg/master.cfg", silent = False)
    # reconfigure master to replica
    replica.reconfigure("replication/cfg/replica.cfg", silent = False)


# Cleanup.
replica.stop()
replica.cleanup(True)
server.stop()
server.deploy(self.suite_ini["config"])

# vim: syntax=python
