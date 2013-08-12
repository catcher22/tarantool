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

admin("box.cfg.wal_mode")
sql.insert(0, (1,))
sql.insert(0, (2,))
sql.insert(0, (3,))
sql.select(0, 1, index=0)
sql.select(0, 2, index=0)
sql.select(0, 3, index=0)
sql.select(0, 4, index=0)
admin("save snapshot")
admin("save snapshot")
admin("box.space[0]:truncate()")
admin("save snapshot")
