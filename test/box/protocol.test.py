
import subprocess
import sys
import os

p = subprocess.Popen([ os.path.join(builddir, "test/box/protocol") ],
                     stdout=subprocess.PIPE)

for line in p.stdout.readlines():
      sys.stdout.write(line)

sql.delete(0, 1)
# vim: syntax=python
