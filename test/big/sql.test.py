import tarantool
sql.sort = True
sql.set_schema({
    0 : {
        'default_type': tarantool.STR,
        'fields' : {
            0 : tarantool.STR,
            1 : tarantool.STR
            },
        'indexes' : {
            0 : [0], # HASH
            1 : [1]  # TREE
            }
        },
    1 : {
        'default_type' : tarantool.STR,
        'fields' : {
            0 : tarantool.STR,
            1 : tarantool.STR,
            2 : tarantool.STR
            },
        'indexes' : {
            0 : [0],   # HASH
            1 : [1, 2] # TREE
            }
        },
    4 : {
        'default_type' : tarantool.STR,
        'fields' : {
            0 : tarantool.STR,
            1 : tarantool.STR
            },
        'indexes' : {
            0 : [0], # HASH
            1 : [1]  # TREE
            }
        },
    5 : {
        'default_type' : tarantool.STR,
        'fields' : {
            0 : tarantool.STR,
            1 : tarantool.STR,
            2 : tarantool.STR
            },
        'indexes' : {
            0 : [0],   # TREE
            1 : [1, 2] # TREE
            }
        },
    7 : {
        'default_type' : tarantool.STR,
        'fields' : {
            0 : tarantool.NUM,
            1 : tarantool.STR
            },
        'indexes' : {
            0 : [0], # HASH
            1 : [1]  # HASH
            }
        }
    })

print """#
# A test case for Bug#729758
# "SELECT fails with a disjunct and small LIMIT"
# https://bugs.launchpad.net/tarantool/+bug/729758
#"""
sql.insert(0, ('Doe', 'Richard'))
sql.insert(0, ('Roe', 'Richard'))
sql.insert(0, ('Woe', 'Richard'))
sql.insert(0, ('Major', 'Tomas'))
sql.insert(0, ('Kytes', 'Tomas'))
sql.select(0, ['Richard', 'Tomas', 'Tomas'], index = 1, limit = 5)


print """#
# A test case for Bug#729879
# "Zero limit is treated the same as no limit"
# https://bugs.launchpad.net/tarantool/+bug/729879
#"""
sql.select(0, ['Richard', 'Tomas'], index = 1, limit = 0)

# Cleanup
sql.delete(0, 'Doe')
sql.delete(0, 'Roe')
sql.delete(0, 'Woe')
sql.delete(0, 'Major')
sql.delete(0, 'Kytes')

print """#
# A test case for Bug#730593
# "Bad data if incomplete tuple"
# https://bugs.launchpad.net/tarantool/+bug/730593
# Verify that if there is an index on, say, field 2,
# we can't insert tuples with cardinality 1 and
# get away with it.
#"""
sql.insert(0, ('Britney',))
sql.select(0, 'Anything', index = 1)
sql.insert(0, ('Stephanie',))
sql.select(0, 'Anything', index = 1)
sql.insert(0, ('Spears', 'Britney'))
sql.select(0, 'Spears', index = 0)
sql.select(0, 'Anything', index = 1)
sql.select(0, 'Britney', index = 1)
sql.call("box.select_range", ('0', '0', '100', 'Spears'))
sql.call("box.select_range", ('0', '1', '100', 'Britney'))
sql.delete(0, 'Spears')
print """#
# Test composite keys with trees
#"""
sql.insert(1, ('key1', 'part1', 'part2'))
# Test a duplicate insert on unique index that once resulted in a crash (bug #926080)
sql.replace(1, ('key1', 'part1', 'part2'))
sql.insert(1, ('key2', 'part1', 'part2_a'))
sql.insert(1, ('key3', 'part1', 'part2_b'))
admin("for k, v in box.space[1]:pairs() do print(v) end")
sql.select(1, 'key1')
sql.select(1, 'key2')
sql.select(1, 'key3')
sql.select(1, 'part1', index=1)
sql.call("box.select_range", ('1', '1', '100', 'part1'))
sql.call("box.select_range", ('1', '0', '100', 'key2'))
sql.call("box.select_range", ('1', '1', '100', 'part1', 'part2_a'))
# check non-unique multipart keys
sql.insert(5, ('01234567', 'part1', 'part2'))
sql.insert(5, ('11234567', 'part1', 'part2'))
sql.insert(5, ('21234567', 'part1', 'part2_a'))
sql.insert(5, ('31234567', 'part1_a', 'part2'))
sql.insert(5, ('41234567', 'part1_a', 'part2_a'))
admin("for k, v in box.space[5]:pairs() do print(v) end")
sql.select(5, '01234567')
sql.select(5, '11234567')
sql.select(5, '21234567')
sql.select(5, 'part1', index=1)
sql.select(5, 'part1_a', index=1)
sql.select(5, 'part_none', index=1)
sql.call('box.select', ('5', '1', 'part1', 'part2'))
sql.insert(7, (1, 'hello'))
sql.insert(7, (2, 'brave'))
sql.insert(7, (3, 'new'))
sql.insert(7, (4, 'world'))
# Check how build_idnexes() works
server.stop()
server.start()
print """#
# Bug#929654 - secondary hash index is not built with build_indexes()
#"""
sql.select(7, 'hello', index=1)
sql.select(7, 'brave', index=1)
sql.select(7, 'new', index=1)
sql.select(7, 'world', index=1)
admin("box.space[7]:truncate()")
sql.select(1, 'key1')
sql.select(1, 'key2')
sql.select(1, 'key3')
sql.select(1, 'part1', index=1)
sql.delete(1, 'key1')
sql.delete(1, 'key2')
sql.delete(1, 'key3')
sql.select(5, 'part1', index=1)
sql.select(5, 'part2', index=1)
# cleanup
sql.delete(5, '01234567')
sql.delete(5, '11234567')
sql.delete(5, '21234567')
sql.delete(5, '31234567')
sql.delete(5, '41234567')
admin("for k, v in box.space[5]:pairs() do print(v) end")

print """
#
# A test case for: http://bugs.launchpad.net/bugs/735140
# Partial REPLACE corrupts index.
#
"""
# clean data and restart with appropriate config

sql.insert(4, ('Spears', 'Britney'))
sql.select(4, 'Spears')
sql.select(4, 'Britney', index=1)
# try to insert the incoplete tuple
sql.replace(4, ('Spears',))
# check that nothing has been updated
sql.select(4, 'Spears')
# cleanup
sql.delete(4, 'Spears')

#
# Test retrieval of duplicates via a secondary key
#
sql.insert(4, (1, 'duplicate one'))
sql.insert(4, (2, 'duplicate one'))
sql.insert(4, (3, 'duplicate one'))
sql.insert(4, (4, 'duplicate one'))
sql.insert(4, (5, 'duplicate one'))
sql.insert(4, (6, 'duplicate two'))
sql.insert(4, (7, 'duplicate two'))
sql.insert(4, (8, 'duplicate two'))
sql.insert(4, (9, 'duplicate two'))
sql.insert(4, (10, 'duplicate two'))
sql.insert(4, (11, 'duplicate three'))
sql.insert(4, (12, 'duplicate three'))
sql.insert(4, (13, 'duplicate three'))
sql.insert(4, (14, 'duplicate three'))
sql.insert(4, (15, 'duplicate three'))
sql.select(4, 'duplicate one', index=1)
sql.select(4, 'duplicate two', index=1)
sql.select(4, 'duplicate three', index=1)
sql.delete(4, 1)
sql.delete(4, 2)
sql.delete(4, 3)
sql.delete(4, 4)
sql.delete(4, 5)
sql.delete(4, 6)
sql.delete(4, 7)
sql.delete(4, 8)
sql.delete(4, 9)
sql.delete(4, 10)
sql.delete(4, 11)
sql.delete(4, 12)
sql.delete(4, 13)
sql.delete(4, 14)
sql.delete(4, 15)
#
# Check min() and max() functions
#
sql.insert(4, (1, 'Aardvark '))
sql.insert(4, (2, 'Bilimbi'))
sql.insert(4, (3, 'Creature '))
admin("for k, v in box.space[4]:pairs() do print(v) end")
admin("box.space[4].index[0].idx:min()")
admin("box.space[4].index[0].idx:max()")
admin("box.space[4].index[1].idx:min()")
admin("box.space[4].index[1].idx:max()")
sql.delete(4, 1)
sql.delete(4, 2)
sql.delete(4, 3)

sql.sort = False
