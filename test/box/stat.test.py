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
# clear statistics
server.restart()

print """#
# check stat_cleanup
#  add several tuples
#
"""
for i in range(10):
  sql.insert(0, (i, 'tuple'))
admin("show stat")
print """#
# restart server
#
"""
server.restart()
print """#
# statistics must be zero
#
"""
admin("show stat")

# cleanup
for i in range(10):
  sql.delete(0, i)
