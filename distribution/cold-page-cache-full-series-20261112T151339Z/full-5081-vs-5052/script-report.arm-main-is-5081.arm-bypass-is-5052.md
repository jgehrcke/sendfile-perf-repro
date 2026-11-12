# fileReader bypass: registry CPU time and wall time against main

Measured 2026-11-12 with `repro/measure-filereader-bypass.py` (command: `--lifetimes 2 --repetitions 3 --base 910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9 --bypass 0eb9d5768544e74a8410d282d83146f326148de1 --buffer-caps-kib  --cases cold-c1,cold-c8 --transports http --out /path/to/sendfile-perf-repro/distribution/repro/cold-page-cache-full-series-20261112T151339Z/full-5081-vs-5052 --report-name script-report.arm-main-is-5081.arm-bypass-is-5052.md`), which drives `repro/run-repro.sh`. Every arm and case: 2 process lifetime(s) of 3 repetitions. All ± values are sample standard deviations over repetitions.

## Arms

- main: upstream main, commit 910dd4f2, tree `cf3fa2a7`.
- bypass: bypass branch, commit 0eb9d576, tree `f7cc5450`.

## Method and environment

- Placement: registry and load client pinned to disjoint CPU sets of NUMA node 0 with `numactl --physcpubind --membind` (`NUMA_PIN=same-socket`): registry CPUs 0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70, client CPUs 1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71.
- Network: registry and client run in a private network namespace whose loopback has no netfilter rules (`LOOPBACK_NET=isolated`); HTTP/1.1 on loopback for both transports.
- Verified, not assumed: for each of the 24 repetitions in 8 process lifetimes the load client recorded the CPU affinity of every thread, the memory policy of every mapping and the network namespace of registry and client; all match the requested placement and the namespace the harness verified (only `lo`, empty nftables ruleset). The script stops otherwise.
- Foreign load: per repetition, the busy time of the pinned CPUs (user, nice, system, irq, softirq from `/proc/stat`) minus registry and client CPU time. A repetition is flagged when that remainder exceeds 0.3 s and 20% of the busy time. Flagged: 5 of 24 repetitions (sessions/cold-c1-http--main+bypass/http/patched-default-n8-l1-r3.json, sessions/cold-c1-http--main+bypass/http/unpatched-default-n8-l2-r1.json, sessions/cold-c8-http--main+bypass/http/patched-default-n8-l1-r2.json, sessions/cold-c8-http--main+bypass/http/patched-default-n8-l2-r2.json, sessions/cold-c8-http--main+bypass/http/unpatched-default-n8-l2-r1.json; they are included in the tables). Largest remainder: 4.05 s, 45% of the busy time of that repetition. The CPUs were also checked to be idle before every harness invocation.
- CPU time: `/proc/<pid>/stat` of the registry process, resolution 0.01 s per repetition. Access logging disabled, `OTEL_TRACES_EXPORTER=none`.
- Host: NVIDIA DGX GB200 Compute Tray, Neoverse-V2, 2 sockets with 72 cores each, aarch64, Linux 6.14.0-1015-nvidia-64k, page size 64 KiB, Ubuntu 24.04.3 LTS.
- Build: go1.26.10 linux/arm64, `go build -mod=vendor -trimpath ./cmd/registry`; main `910dd4f2` (tree `cf3fa2a7`), bypass `0eb9d576` (tree `f7cc5450`). Source and Go version of every binary verified.
- Registry storage: ext4 on `nvme0n1p3` (SAMSUNG MZ1L21T9HCLS-00A07, not a rotating disk), readahead 256 KiB.

## Whole-blob GETs, cold page cache

One repetition is 8 GET requests, one for each of 8 distinct blobs of 1 GiB (8 GiB), one at a time or all at once. Before every repetition each blob file is dropped from the page cache with `posix_fadvise(POSIX_FADV_DONTNEED)`; `mincore()` showed no page of the files in the page cache before and every page after, in every repetition.

Storage: ext4 on SAMSUNG MZ1L21T9HCLS-00A07 (NVMe solid-state drive), readahead 256 KiB. A result on this device says nothing about rotating disks or network filesystems.

| Transport | Concurrency | Metric | main (mean ± sample SD, s) | n | bypass (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 1 | Wall time per repetition | 3.401 ± 0.017 | 6 | 1.77 ± 0.10 | 6 | -48.1% | yes |
| Plain HTTP | 1 | Registry total CPU time per repetition | 2.852 ± 0.025 | 6 | 0.785 ± 0.010 | 6 | -72.5% | yes |
| Plain HTTP | 1 | Registry user CPU time per repetition | 0.145 ± 0.014 | 6 | 0.0083 ± 0.0041 | 6 | -94.3% | yes |
| Plain HTTP | 1 | Registry kernel CPU time per repetition | 2.707 ± 0.027 | 6 | 0.777 ± 0.010 | 6 | -71.3% | yes |
| Plain HTTP | 8 | Wall time per repetition | 2.56466 ± 0.00057 | 6 | 2.56465 ± 0.00027 | 6 | -0.0% | no |
| Plain HTTP | 8 | Registry total CPU time per repetition | 2.923 ± 0.015 | 6 | 0.7417 ± 0.0075 | 6 | -74.6% | yes |
| Plain HTTP | 8 | Registry user CPU time per repetition | 0.203 ± 0.021 | 6 | 0.0017 ± 0.0041 | 6 | -99.2% | yes |
| Plain HTTP | 8 | Registry kernel CPU time per repetition | 2.720 ± 0.017 | 6 | 0.7400 ± 0.0063 | 6 | -72.8% | yes |

## Distributions

Checked for every case and arm, registry total CPU time and wall time: the sorted values are split at their largest gap; a bimodal candidate is reported when both sides hold at least three values and the gap is at least four pooled within-side sample SDs and 0.03 s.

No bimodal candidate.

## Run

2 harness invocations, 495 s from the first to the last. Per-repetition values: `data.json`; raw harness result files: `sessions/`; harness logs: `logs/`.
