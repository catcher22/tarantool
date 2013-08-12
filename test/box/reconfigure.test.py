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
admin("box.cfg.too_long_threshold")
# bad1
server.reconfigure("box/tarantool_bad1.cfg")
admin("box.cfg.too_long_threshold")
# bad2
server.reconfigure("box/tarantool_bad2.cfg")
# bad3
server.reconfigure("box/tarantool_bad3.cfg")
# bad4
server.reconfigure("box/tarantool_bad4.cfg")
# bad5
server.reconfigure("box/tarantool_bad5.cfg")
# good
server.reconfigure("box/tarantool_good.cfg")
admin("box.cfg.too_long_threshold")
admin("box.cfg.snap_io_rate_limit")
admin("box.cfg.io_collect_interval")
# empty
server.reconfigure("box/tarantool_empty.cfg")
admin("box.cfg.too_long_threshold")

# no config
server.reconfigure(None)

# cleanup
# restore default
server.reconfigure(self.suite_ini["config"])
admin("box.cfg.too_long_threshold")

print """#
# A test case for http://bugs.launchpad.net/bugs/712447:
# Valgrind reports use of not initialized memory after 'reload
# configuration'
#"""

sql.insert(0, (1, 'tuple'))
admin("save snapshot")
server.reconfigure(None)

sql.insert(0, (2, 'tuple 2'))
admin("save snapshot")
server.reconfigure("box/tarantool_good.cfg")
sql.insert(0, (3, 'tuple 3'))
admin("save snapshot")
# Cleanup
server.reconfigure(self.suite_ini["config"])
admin("box.space[0]:truncate()")

# vim: syntax=python
