# encoding: utf-8
import os
import time
from lib.tarantool_server import TarantoolServer

ID_BEGIN = 0
ID_STEP = 10

def insert_tuples(server, begin, end, msg = "tuple"):
    server_sql = server.sql
    for i in range(begin, end):
        server_sql("insert into t0 values (%d, '%s %d')" % (i, msg, i))

def select_tuples(server, begin, end):
    server_sql = server.sql
    # the last lsn is end id + 1
    server.wait_lsn(end + 1)
    for i in range(begin, end):
        server_sql("select * from t0 where k0 = %d" % i)

# master server
master = server

# replica server
replica = TarantoolServer()
replica.deploy("replication/cfg/replica.cfg",
               replica.find_exe(self.args.builddir),
               os.path.join(self.args.vardir, "replica"))

# Id counter
id = 0


print "insert to master [%d, %d) entries" % (id, id + ID_STEP)
insert_tuples(master, id, id + ID_STEP, "mater")

print "select from replica [%d, %d) entries" % (id, id + ID_STEP)
select_tuples(replica, id, id + ID_STEP)
id += ID_STEP

print "master lsn = %s" % master.get_param("lsn")
print "replica lsn = %s" % replica.get_param("lsn")


print """
#
# mater lsn > replica lsn
#
"""
print """
# reconfigure replica to master
"""
replica.reconfigure("replication/cfg/replica_to_master.cfg")

print "insert to master [%d, %d) entries" % (id, id + ID_STEP)
insert_tuples(master, id, id + ID_STEP, "mater")
print "select from master [%d, %d) entries" % (id, id + ID_STEP)
select_tuples(master, id, id + ID_STEP)

print "insert to replica [%d, %d) entries" % (id, id + (ID_STEP / 2))
insert_tuples(replica, id, id + (ID_STEP / 2), "replica")
print "select from replica [%d, %d) entries" % (id, id + (ID_STEP / 2))
select_tuples(replica, id, id + (ID_STEP / 2))

print "master lsn = %s" % master.get_param("lsn")
print "replica lsn = %s" % replica.get_param("lsn")

print """
# rollback replica
"""
replica.reconfigure("replication/cfg/replica.cfg")

print "select from replica [%d, %d) entries" % (id, id + ID_STEP)
select_tuples(replica, id, id + ID_STEP)
id += ID_STEP

print "master lsn = %s" % master.get_param("lsn")
print "replica lsn = %s" % replica.get_param("lsn")


print """
#
# master lsn == replica lsn
#
"""
print """
# reconfigure replica to master
"""
replica.reconfigure("replication/cfg/replica_to_master.cfg")

print "insert to master [%d, %d) entries" % (id, id + ID_STEP)
insert_tuples(master, id, id + ID_STEP, "mater")
print "select from master [%d, %d) entries" % (id, id + ID_STEP)
select_tuples(master, id, id + ID_STEP)

print "insert to replica [%d, %d) entries" % (id, id + ID_STEP)
insert_tuples(replica, id, id + ID_STEP, "replica")
print "select from replica [%d, %d) entries" % (id, id + ID_STEP)
select_tuples(replica, id, id + ID_STEP)

print "master lsn = %s" % master.get_param("lsn")
print "replica lsn = %s" % replica.get_param("lsn")

print """
# rollback replica
"""
replica.reconfigure("replication/cfg/replica.cfg")

print "select from replica [%d, %d) entries" % (id, id + ID_STEP)
select_tuples(replica, id, id + ID_STEP)
id += ID_STEP

print "master lsn = %s" % master.get_param("lsn")
print "replica lsn = %s" % replica.get_param("lsn")


print """
#
# mater lsn < replica lsn
#
"""
print """
#reconfigure replica to master
"""
replica.reconfigure("replication/cfg/replica_to_master.cfg")

print "insert to master [%d, %d) entries" % (id, id + ID_STEP)
insert_tuples(master, id, id + ID_STEP, "mater")
print "select from master [%d, %d) entries" % (id, id + ID_STEP)
select_tuples(master, id, id + ID_STEP)

print "insert to replica [%d, %d) entries" % (id, id + (ID_STEP * 2))
insert_tuples(replica, id, id + (ID_STEP * 2), "replica")
print "select from replica [%d, %d) entries" % (id, id + (ID_STEP * 2))
select_tuples(replica, id, id + (ID_STEP * 2))

print "master lsn = %s" % master.get_param("lsn")
print "replica lsn = %s" % replica.get_param("lsn")

print """
# rollback replica
"""
replica.reconfigure("replication/cfg/replica.cfg")

print "select from replica [%d, %d) entries" % (id, id + (ID_STEP * 2))
select_tuples(replica, id, id + (ID_STEP * 2))
id += ID_STEP

print "insert to master [%d, %d) entries" % (id, id + (ID_STEP * 2))
insert_tuples(master, id, id + (ID_STEP * 2), "master")

print "select from replica [%d, %d) entries" % (id, id + (ID_STEP * 2))
select_tuples(replica, id, id + (ID_STEP * 2))

print "master lsn = %s" % master.get_param("lsn")
print "replica lsn = %s" % replica.get_param("lsn")
# Test that a replica replies with master connection URL on
# update requests.
replica_sql = replica.sql
replica_sql("insert into t0 values (0, 'replica is read only')")

# Cleanup.
replica.stop()
replica.cleanup(True)
server.stop()
server.deploy(self.suite_ini["config"])

# vim: syntax=python
