# encoding: utf-8
import os
import sys
import time
import yaml

from lib.memcached_connection import MemcachedConnection
from lib.tarantool_server import TarantoolServer

sonet = """The expense of spirit
in a waste of shame
Is lust in action;
and till action, lust""".split('\n')

master = server
master_memcached = master.memcached

replica = TarantoolServer()
replica.deploy("replication/cfg/replica.cfg",
           replica.find_exe(self.args.builddir),
           os.path.join(self.args.vardir, "replica"))
replica_memcached = replica.memcached

###################################
def get_lsn(serv):
    serv_admin = serv.admin
    resp = serv_admin("box.info.lsn", silent=True)
    return yaml.load(resp)[0]

def wait(serv_master = master, serv_replica = replica):
    lsn = get_lsn(serv_master)
    serv_replica.wait_lsn(lsn)
    return lsn

def get_memcached_len(serv):
    serv_admin = serv.admin
    resp = serv_admin("box.space[box.cfg.memcached_space]:len()", silent=True)
    return yaml.load(resp)[0]

def wait_for_empty_space(serv):
    serv_admin = serv.admin
    while True:
        if get_memcached_len(serv) == 0:
            return
        time.sleep(0.01)

###################################

print """# set initial k-v pairs"""
for i in xrange(10):
    master_memcached("set %d 0 0 5\r\ngood%d\r\n" % (i, i), silent=True)

print """# wait and get last k-v pair from replica"""
wait()
replica_memcached("get 9\r\n")

print """# make multiple cnanges with master"""
answer = master_memcached("gets 9\r\n", silent=True)
cas = int(answer.split()[4])
master_memcached("append 1 0 0 3\r\nafk\r\n", silent=True)
master_memcached("prepend 2 0 0 3\r\nkfa\r\n", silent=True)
master_memcached("set 3 0 0 2\r\n80\r\n", silent=True)
master_memcached("set 4 0 0 2\r\n60\r\n", silent=True)
master_memcached("delete 6\r\n", silent=True)
master_memcached("replace 7 0 0 %d\r\n%s\r\n" % (len(sonet[0]), sonet[0]), silent=True)
master_memcached("replace 8 0 0 %d\r\n%s\r\n" % (len(sonet[1]), sonet[1]), silent=True)
master_memcached("cas 9 0 0 %d %d\r\n%s\r\n" % (len(sonet[2]), cas, sonet[2]), silent=True) 
master_memcached("add 10 0 0 %d\r\n%s\r\n" % (len(sonet[3]), sonet[3]), silent=True)
master_memcached("incr 3 15\r\n", silent=True)
master_memcached("decr 4 15\r\n", silent=True)

print """# wait and get k-v's from replicas"""
wait()
replica_memcached("get 1 2 3 4 5 7 8 9 10\r\n")

print """# get deleted value"""
replica_memcached("get 6\r\n")

print """# flush all k-v on master and try to get them from replica"""
master_memcached("flush_all\r\n", silent=True)
wait_for_empty_space(replica)
replica_memcached("get 10\r\n")


print """# check that expiration is working properly on replica"""
master_memcached("set 1 0 1 %d\r\n%s\r\n" % (len(sonet[0]), sonet[0]), silent=True)
lsn = wait()
replica_memcached("get 1\r\n")
replica.wait_lsn(lsn + 1)
replica_memcached("get 1\r\n")

print """# check that expiration is working properly, when replica becomes master"""
master_memcached("set 1 0 1 %d\r\n%s\r\n" % (len(sonet[0]), sonet[0]), silent=True)
lsn = wait()
replica.reconfigure("replication/cfg/replica_to_master.cfg")
replica_memcached("get 1\r\n")
replica.wait_lsn(lsn + 1)
replica_memcached("get 1\r\n")


# restore default suite config
replica.stop()
replica.cleanup(True)
master.stop()
master.deploy(self.suite_ini["config"])
# vim: syntax=python
