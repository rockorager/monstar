#!/usr/bin/env python3
"""cat flood: flood.py FILE COPIES RESULT_JSON. Runs `cat FILE` COPIES times
in one cat on this terminal and records CLOCK_MONOTONIC start and end."""
import json
import os
import subprocess
import sys
import time

path, copies, result = sys.argv[1], int(sys.argv[2]), sys.argv[3]
start = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
code = subprocess.call(["cat"] + [path] * copies)
end = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
tmp = result + ".tmp"
with open(tmp, "w") as f:
    json.dump({"start_ns": start, "end_ns": end, "bytes": os.path.getsize(path) * copies, "exit": code}, f)
os.rename(tmp, result)
time.sleep(3600)  # keep the final screen until the tool closes the window
