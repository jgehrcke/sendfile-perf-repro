#!/bin/sh
# Cold page cache, main / #5081 / #5052, one GET at a time. Usage (cwd = project root):
#   sh <this dir>/run.sh <phase name> <cases> <transports> <process lifetimes> <repetitions per lifetime>
# Two comparisons of the unmodified repro/measure-filereader-bypass.py that share #5081 (as in the n=6 directory
# repro/cold-page-cache-full-series-20261112T151339Z): 5081-vs-5052 (script arm "main" = #5081, "bypass" = #5052), then main-vs-5081.
# Arms alternate per registry process lifetime. Before every repetition each blob file is dropped from the page cache
# (posix_fadvise DONTNEED, repeated until mincore shows 0 resident pages) and the harness stops if a page is resident.
set -eu
name=$1 cases=$2 transports=$3 lifetimes=$4 reps=$5
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
MAIN=f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b
PR5081=910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9
PR5052=0eb9d5768544e74a8410d282d83146f326148de1
cd "$root"
date -u "+%Y-%m-%dT%H:%M:%SZ start $name 5081-vs-5052"
python3 -B repro/measure-filereader-bypass.py --lifetimes "$lifetimes" --repetitions "$reps" --base "$PR5081" --bypass "$PR5052" --buffer-caps-kib '' --cases "$cases" --transports "$transports" \
	--out "$here/$name-5081-vs-5052" --report-name script-report.arm-main-is-5081.arm-bypass-is-5052.md
date -u "+%Y-%m-%dT%H:%M:%SZ start $name main-vs-5081"
python3 -B repro/measure-filereader-bypass.py --lifetimes "$lifetimes" --repetitions "$reps" --base "$MAIN" --bypass "$PR5081" --buffer-caps-kib '' --cases "$cases" --transports "$transports" \
	--out "$here/$name-main-vs-5081" --report-name script-report.md
date -u "+%Y-%m-%dT%H:%M:%SZ done $name"
