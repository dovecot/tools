#!/usr/bin/python3

### This utility allows you to watch the new-style stats, so you can
### see rate of change.

import json
import subprocess
import shlex
import sys
import time

def display_difference(sa, sb, n):
    for idx, ma in enumerate(sa):
        mb = sb[idx]
        name = ma["metric_name"]
        rqs = (mb["count"]-ma["count"]) / n
        adur = (mb["sum"]-ma["sum"])
        if rqs > 0:
            adur = adur / rqs / n / 1000000
        if len(sys.argv) < 2 or name in sys.argv[1:]:
            print(f"{name}: {rqs}/cs {adur} sec")

def get_stats():
    result = subprocess.run(shlex.split("doveadm -fjson stats dump"), check=True,
            capture_output=True)
    return json.loads(result.stdout.decode())

def main():
    sa = get_stats()
    while True:
        time.sleep(2)
        sb = get_stats()
        display_difference(sa, sb, 2)
        print("\n")
        sa = sb

if __name__ == '__main__':
    main()
