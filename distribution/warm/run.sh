#!/bin/sh
# Registry total CPU time per GET on the final trees of #5081 and #5052, and on upstream main.
# Usage (cwd = the directory of measure-filereader-bypass.py; the clone with the three revisions is in upstream/):
#   sh warm/run.sh pilot    n = 2 per arm (1 process lifetime x 2 repetitions)
#   sh warm/run.sh n15      n = 15 per arm (3 process lifetimes x 5 repetitions)
# It runs the unmodified measure-filereader-bypass.py twice. The script compares two revisions
# ("main" = --base, "bypass" = --bypass), so the three revisions are two comparisons that share #5081:
#   1. 5081-vs-5052   --base = #5081 commit, --bypass = #5052 commit   (measured first: the pair that matters most)
#   2. main-vs-5081   --base = upstream main, --bypass = #5081 commit
# In comparison 1 the script's arm name "main" therefore means #5081 and "bypass" means #5052.
set -eu
phase=$1
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
MAIN=f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b
PR5081=910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9
PR5052=0eb9d5768544e74a8410d282d83146f326148de1
CASES=whole-4mib,whole-32mib,range-1mib,range-32mib
case "$phase" in
	pilot) quick=--quick ;;
	n15) quick= ;;
	*) echo "usage: run.sh pilot|n15" >&2; exit 2 ;;
esac
cd "$root"
date -u '+%Y-%m-%dT%H:%M:%SZ start comparison 5081-vs-5052'
python3 -B measure-filereader-bypass.py --repo upstream $quick --base "$PR5081" --bypass "$PR5052" --buffer-caps-kib '' --cases "$CASES" \
	--out "$here/$phase-5081-vs-5052" --report-name script-report.arm-main-is-5081.arm-bypass-is-5052.md
date -u '+%Y-%m-%dT%H:%M:%SZ start comparison main-vs-5081'
python3 -B measure-filereader-bypass.py --repo upstream $quick --base "$MAIN" --bypass "$PR5081" --buffer-caps-kib '' --cases "$CASES" \
	--out "$here/$phase-main-vs-5081" --report-name script-report.md
date -u '+%Y-%m-%dT%H:%M:%SZ done'
