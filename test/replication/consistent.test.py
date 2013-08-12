import os
import time
from lib.tarantool_server import TarantoolServer
import tarantool

ID_BEGIN = 0
ID_STEP = 10

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
master.sql.set_schema({
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

# replica server
replica = TarantoolServer()
replica.deploy("replication/cfg/replica.cfg",
               replica.find_exe(self.args.builddir),
               os.path.join(self.args.vardir, "replica"))
replica.sql.set_schema({
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
replica.sql.insert(0, (0, 'replica is read only'))

# Cleanup.
replica.stop()
replica.cleanup(True)
server.stop()
server.deploy(self.suite_ini["config"])
