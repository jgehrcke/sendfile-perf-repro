#!/bin/sh
# Cold page cache, whole-blob GETs of 1 GiB blobs, main / #5081 / #5052, plain HTTP (TLS if TRANSPORTS=http,tls).
# Usage (cwd = project root):
#   sh <this dir>/run.sh pilot|nN   pilot = n=2 per arm; "full" = COLD_LIFETIMES x COLD_REPETITIONS from the environment
# Two comparisons of the unmodified repro/measure-filereader-bypass.py that share #5081:
#   5081-vs-5052   --base #5081, --bypass #5052 (script arm "main" = #5081, "bypass" = #5052)
#   main-vs-5081   --base main,  --bypass #5081
# Cases cold-c1 (one GET at a time) and cold-c8 (8 GETs at once): 8 blobs of 1 GiB; before every repetition each blob
# file is dropped with posix_fadvise(DONTNEED) and mincore() must show 0 resident pages (the script stops otherwise).
set -eu
phase=$1
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
MAIN=f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b
PR5081=910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9
PR5052=0eb9d5768544e74a8410d282d83146f326148de1
CASES=${CASES:-cold-c1,cold-c8}
TRANSPORTS=${TRANSPORTS:-http}
case "$phase" in
	pilot) opts="--quick" ;;
	full) opts="--lifetimes ${COLD_LIFETIMES:-3} --repetitions ${COLD_REPETITIONS:-5}" ;;
	*) echo "usage: run.sh pilot|full" >&2; exit 2 ;;
esac
cd "$root"
date -u '+%Y-%m-%dT%H:%M:%SZ start comparison 5081-vs-5052'
python3 -B repro/measure-filereader-bypass.py $opts --base "$PR5081" --bypass "$PR5052" --buffer-caps-kib '' --cases "$CASES" --transports "$TRANSPORTS" \
	--out "$here/$phase-5081-vs-5052" --report-name script-report.arm-main-is-5081.arm-bypass-is-5052.md
date -u '+%Y-%m-%dT%H:%M:%SZ start comparison main-vs-5081'
python3 -B repro/measure-filereader-bypass.py $opts --base "$MAIN" --bypass "$PR5081" --buffer-caps-kib '' --cases "$CASES" --transports "$TRANSPORTS" \
	--out "$here/$phase-main-vs-5081" --report-name script-report.md
date -u '+%Y-%m-%dT%H:%M:%SZ done'
