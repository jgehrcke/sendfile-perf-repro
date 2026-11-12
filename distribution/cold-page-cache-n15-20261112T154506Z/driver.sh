#!/bin/sh
# Priority 1 then priority 2, back to back; stops at the first failure.
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"
sh "$here/run.sh" p1-http-1gib cold-c1 http 5 3 > "$here/console/p1.log" 2>&1; rc=$?; echo "exit=$rc" >> "$here/console/p1.log"; [ $rc = 0 ] || exit $rc
sh "$here/run.sh" p2-tls-1gib cold-c1 tls 5 3 > "$here/console/p2.log" 2>&1; rc=$?; echo "exit=$rc" >> "$here/console/p2.log"
