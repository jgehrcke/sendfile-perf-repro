#!/bin/sh
# Addition to run.sh, after its n15 phase: more registry process lifetimes for the TLS cases of #5081 against #5052.
# Reason: in the n15 phase the process lifetime means of one revision differ by more than the repetitions within a
# lifetime (TLS, 32 MiB), so 3 process lifetimes do not show whether #5052 differs from #5081 over TLS.
# 12 process lifetimes x 3 repetitions per arm and case (n = 36 repetitions per arm), arms alternating per lifetime.
# Usage (cwd = project root): sh repro/pr5052-final-trees-<stamp>/run-tls-lifetimes.sh
# Arm names of the script: "main" = #5081, "bypass" = #5052.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
PR5081=910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9
PR5052=0eb9d5768544e74a8410d282d83146f326148de1
cd "$root"
date -u '+%Y-%m-%dT%H:%M:%SZ start tls-lifetimes 5081-vs-5052'
python3 -B repro/measure-filereader-bypass.py --base "$PR5081" --bypass "$PR5052" --buffer-caps-kib '' \
	--cases whole-4mib,whole-32mib,range-1mib,range-32mib --transports tls --lifetimes 12 --repetitions 3 \
	--out "$here/tls-lifetimes-5081-vs-5052" --report-name script-report.arm-main-is-5081.arm-bypass-is-5052.md
date -u '+%Y-%m-%dT%H:%M:%SZ done'
