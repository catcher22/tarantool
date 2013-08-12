sql.ping(notime=True)
# xxx: bug -- currently selects no rows
sql.select(0)
sql.insert(0, (1, 'I am a tuple'))
sql.select(0, 1, index=0)
# currently there is no way to find out how many records
# a space contains 
sql.select(0, 0, index=0)
sql.select(0, 2, index=0)
server.restart()
sql.select(0, 1, index=0)
admin("save snapshot")
sql.select(0, 1, index=0)
server.restart()
sql.select(0, 1, index=0)
sql.delete(0, 1)
sql.select(0, 1, index=0)
# xxx: update comes through, returns 0 rows affected 
sql.update(0, 1, [(1, '=', 'I am a new tuple')])
# nothing is selected, since nothing was there
sql.select(0, 1, index=0)
sql.insert(0, (1, 'I am a new tuple'))
sql.select(0, 1, index=0)
sql.update(0, 1, [(1, '=', 'I am the newest tuple')])
sql.select(0, 1, index=0)
# this is correct, can append field to tuple
sql.update(0, 1, [(1, '=', 'Huh'), (2, '=', 'I am a new field! I was added via append')])
sql.select(0, 1, index=0)
# this is illegal
sql.update(0, 1, [(1, '=', 'Huh'), (1000, '=', 'invalid field')])
sql.select(0, 1, index=0)
sql.replace(0, (1, 'I am a new tuple', 'stub'))
sql.update(0, 1, [(1, '=', 'Huh'), (2, '=', 'Oh-ho-ho')])
sql.select(0, 1, index=0)
# check empty strings
sql.update(0, 1, [(1, '=', ''), (2, '=', '')])
sql.select(0, 1, index=0)
# check type change 
sql.update(0, 1, [(1, '=', 2), (2, '=', 3)])
sql.select(0, 1, index=0)
# check limits
sql.insert(0, (0, ))
sql.select(0, 0, index=0)
sql.insert(0, (4294967295, ))
sql.select(0, 4294967295, index=0)
# cleanup 
sql.delete(0, 0)
sql.delete(0, 4294967295)

print """#
# A test case for: http://bugs.launchpad.net/bugs/712456
# Verify that when trying to access a non-existing or
# very large space id, no crash occurs.
#
"""
sql.select(1, 0, index=0)
sql.select(65537, 0, index=0)
sql.select(4294967295, 0, index=0)
admin("box.space[0]:truncate()")

print """#
# A test case for: http://bugs.launchpad.net/bugs/716683
# Admin console should not stall on unknown command.
"""
admin("show status", simple=True)

# vim: syntax=python
