# encoding: utf-8
#
sql.sort = True

print """#
# A test case for Bug#729758
# "SELECT fails with a disjunct and small LIMIT"
# https://bugs.launchpad.net/tarantool/+bug/729758
#"""

sql("insert into t0 values ('Doe', 'Richard')")
sql("insert into t0 values ('Roe', 'Richard')")
sql("insert into t0 values ('Woe', 'Richard')")
sql("insert into t0 values ('Major', 'Tomas')")
sql("insert into t0 values ('Kytes', 'Tomas')")
sql("select * from t0 where k1='Richard' or k1='Tomas' or k1='Tomas' limit 5")

print """#
# A test case for Bug#729879
# "Zero limit is treated the same as no limit"
# https://bugs.launchpad.net/tarantool/+bug/729879
#"""
sql("select * from t0 where k1='Richard' or k1='Tomas' limit 0")

# Cleanup
sql("delete from t0 where k0='Doe'")
sql("delete from t0 where k0='Roe'")
sql("delete from t0 where k0='Woe'")
sql("delete from t0 where k0='Major'")
sql("delete from t0 where k0='Kytes'")

print """#
# A test case for Bug#730593
# "Bad data if incomplete tuple"
# https://bugs.launchpad.net/tarantool/+bug/730593
# Verify that if there is an index on, say, field 2,
# we can't insert tuples with cardinality 1 and
# get away with it.
#"""
sql("insert into t0 values ('Britney')")
sql("select * from t0 where k1='Anything'")
sql("insert into t0 values ('Stephanie')")
sql("select * from t0 where k1='Anything'")
sql("insert into t0 values ('Spears', 'Britney')")
sql("select * from t0 where k0='Spears'")
sql("select * from t0 where k1='Anything'")
sql("select * from t0 where k1='Britney'")
sql("call box.select_range('0', '0', '100', 'Spears')")
sql("call box.select_range('0', '1', '100', 'Britney')")
sql("delete from t0 where k0='Spears'")
print """#
# Test composite keys with trees
#"""
sql("insert into t1 values ('key1', 'part1', 'part2')")
# Test a duplicate insert on unique index that once resulted in a crash (bug #926080)
sql("replace into t1 values ('key1', 'part1', 'part2')")
sql("insert into t1 values ('key2', 'part1', 'part2_a')")
sql("insert into t1 values ('key3', 'part1', 'part2_b')")
admin("for k, v in box.space[1]:pairs() do print(v) end")
sql("select * from t1 where k0='key1'")
sql("select * from t1 where k0='key2'")
sql("select * from t1 where k0='key3'")
sql("select * from t1 where k1='part1'")
sql("call box.select_range('1', '1', '100', 'part1')")
sql("call box.select_range('1', '0', '100', 'key2')")
sql("call box.select_range('1', '1', '100', 'part1', 'part2_a')")
# check non-unique multipart keys
sql("insert into t5 values ('01234567', 'part1', 'part2')")
sql("insert into t5 values ('11234567', 'part1', 'part2')")
sql("insert into t5 values ('21234567', 'part1', 'part2_a')")
sql("insert into t5 values ('31234567', 'part1_a', 'part2')")
sql("insert into t5 values ('41234567', 'part1_a', 'part2_a')")
admin("for k, v in box.space[5]:pairs() do print(v) end")
sql("select * from t5 where k0='01234567'")
sql("select * from t5 where k0='11234567'")
sql("select * from t5 where k0='21234567'")
sql("select * from t5 where k1='part1'")
sql("select * from t5 where k1='part1_a'")
sql("select * from t5 where k1='part_none'")
sql("call box.select('5', '1', 'part1', 'part2')")
sql("insert into t7 values (1, 'hello')")
sql("insert into t7 values (2, 'brave')")
sql("insert into t7 values (3, 'new')")
sql("insert into t7 values (4, 'world')")
# Check how build_idnexes() works
server.stop()
server.start()
print """#
# Bug#929654 - secondary hash index is not built with build_indexes()
#"""
sql("select * from t7 where k1='hello'")
sql("select * from t7 where k1='brave'")
sql("select * from t7 where k1='new'")
sql("select * from t7 where k1='world'")
admin("box.space[7]:truncate()")
sql("select * from t1 where k0='key1'")
sql("select * from t1 where k0='key2'")
sql("select * from t1 where k0='key3'")
sql("select * from t1 where k1='part1'")
sql("delete from t1 where k0='key1'")
sql("delete from t1 where k0='key2'")
sql("delete from t1 where k0='key3'")
sql("select * from t5 where k1='part1'")
sql("select * from t5 where k1='part2'")
# cleanup
sql("delete from t5 where k0='01234567'")
sql("delete from t5 where k0='11234567'")
sql("delete from t5 where k0='21234567'")
sql("delete from t5 where k0='31234567'")
sql("delete from t5 where k0='41234567'")
admin("for k, v in box.space[5]:pairs() do print(v) end")

print """
#
# A test case for: http://bugs.launchpad.net/bugs/735140
# Partial REPLACE corrupts index.
#
"""
# clean data and restart with appropriate config

sql("insert into t4 values ('Spears', 'Britney')")
sql("select * from t4 where k0='Spears'")
sql("select * from t4 where k1='Britney'")
# try to insert the incoplete tuple
sql("replace into t4 values ('Spears')")
# check that nothing has been updated
sql("select * from t4 where k0='Spears'")
# cleanup
sql("delete from t4 where k0='Spears'")

#
# Test retrieval of duplicates via a secondary key
#
sql("insert into t4 values (1, 'duplicate one')")
sql("insert into t4 values (2, 'duplicate one')")
sql("insert into t4 values (3, 'duplicate one')")
sql("insert into t4 values (4, 'duplicate one')")
sql("insert into t4 values (5, 'duplicate one')")
sql("insert into t4 values (6, 'duplicate two')")
sql("insert into t4 values (7, 'duplicate two')")
sql("insert into t4 values (8, 'duplicate two')")
sql("insert into t4 values (9, 'duplicate two')")
sql("insert into t4 values (10, 'duplicate two')")
sql("insert into t4 values (11, 'duplicate three')")
sql("insert into t4 values (12, 'duplicate three')")
sql("insert into t4 values (13, 'duplicate three')")
sql("insert into t4 values (14, 'duplicate three')")
sql("insert into t4 values (15, 'duplicate three')")
sql("select * from t4 where k1='duplicate one'")
sql("select * from t4 where k1='duplicate two'")
sql("select * from t4 where k1='duplicate three'")
sql("delete from t4 where k0=1")
sql("delete from t4 where k0=2")
sql("delete from t4 where k0=3")
sql("delete from t4 where k0=4")
sql("delete from t4 where k0=5")
sql("delete from t4 where k0=6")
sql("delete from t4 where k0=7")
sql("delete from t4 where k0=8")
sql("delete from t4 where k0=9")
sql("delete from t4 where k0=10")
sql("delete from t4 where k0=11")
sql("delete from t4 where k0=12")
sql("delete from t4 where k0=13")
sql("delete from t4 where k0=14")
sql("delete from t4 where k0=15")
#
# Check min() and max() functions
#
sql("insert into t4 values(1, 'Aardvark ')")
sql("insert into t4 values(2, 'Bilimbi')")
sql("insert into t4 values(3, 'Creature ')")
admin("for k, v in box.space[4]:pairs() do print(v) end")
admin("box.space[4].index[0].idx:min()")
admin("box.space[4].index[0].idx:max()")
admin("box.space[4].index[1].idx:min()")
admin("box.space[4].index[1].idx:max()")
sql("delete from t4 where k0=1")
sql("delete from t4 where k0=2")
sql("delete from t4 where k0=3")

sql.sort = False
# vim: syntax=python
