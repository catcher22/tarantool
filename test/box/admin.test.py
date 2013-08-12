import sys
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
# clear statistics:
server.stop()
server.deploy()
admin("exit")
admin("show stat")
admin("help")
admin("show configuration")
admin("show stat")
sql.insert(0, (1, 'tuple'))
admin("save snapshot")
sql.delete(0, 1)
sys.stdout.push_filter("(\d)\.\d\.\d(-\d+-\w+)?", "\\1.minor.patch-<rev>-<commit>")
sys.stdout.push_filter("pid: \d+", "pid: <pid>")
sys.stdout.push_filter("logger_pid: \d+", "pid: <pid>")
sys.stdout.push_filter("uptime: \d+", "uptime: <uptime>")
sys.stdout.push_filter("uptime: \d+", "uptime: <uptime>")
sys.stdout.push_filter("(/\S+)+/tarantool", "tarantool")
admin("show info")
sys.stdout.clear_all_filters()
sys.stdout.push_filter(".*", "")
admin("show fiber")
admin("show slab")
admin("show palloc")

sys.stdout.clear_all_filters()
