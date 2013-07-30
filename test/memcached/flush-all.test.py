# encoding: utf-8
import time
import yaml

###################################
def get_memcached_len(serv):
    serv_admin = serv.admin
    resp = serv_admin("box.space[box.cfg.memcached_space]:len()", silent=True)
    return yaml.load(resp)[0]

def wait_for_empty_space(serv = server):
    serv_admin = serv.admin
    while True:
        if get_memcached_len(serv) == 0:
            return
        time.sleep(0.01)
###################################

print """# Test flush_all with zero delay. """
memcached("set foo 0 0 6\r\nfooval\r\n")
memcached("get foo\r\n")
memcached("flush_all\r\n")
memcached("get foo\r\n")

print """# check that flush_all doesn't blow away items that immediately get set """
memcached("set foo 0 0 3\r\nnew\r\n")
memcached("get foo\r\n")

print """# and the other form, specifying a flush_all time... """
expire = time.time() + 1
print "flush_all time + 1"
print memcached("flush_all %d\r\n" % expire, silent=True)
memcached("get foo\r\n")

memcached("set foo 0 0 3\r\n123\r\n")
memcached("get foo\r\n")
wait_for_empty_space()
memcached("get foo\r\n")

# resore default suite config
server.stop()
server.deploy(self.suite_ini["config"])
# vim: syntax=python
