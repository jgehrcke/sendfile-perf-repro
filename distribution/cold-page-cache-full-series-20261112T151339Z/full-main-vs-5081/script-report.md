# fileReader bypass: registry CPU time and wall time against main

Measured 2026-11-12 with `repro/measure-filereader-bypass.py` (command: `--lifetimes 2 --repetitions 3 --base f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b --bypass 910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9 --buffer-caps-kib  --cases cold-c1,cold-c8 --transports http --out /path/to/sendfile-perf-repro/distribution/repro/cold-page-cache-full-series-20261112T151339Z/full-main-vs-5081 --report-name script-report.md`), which drives `repro/run-repro.sh`. Every arm and case: 2 process lifetime(s) of 3 repetitions. All ± values are sample standard deviations over repetitions.

## Arms

- main: upstream main, commit f38cd9c0, tree `0208cb1a`.
- bypass: bypass branch, commit 910dd4f2, tree `cf3fa2a7`.

## Method and environment

- Placement: registry and load client pinned to disjoint CPU sets of NUMA node 0 with `numactl --physcpubind --membind` (`NUMA_PIN=same-socket`): registry CPUs 0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70, client CPUs 1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71.
- Network: registry and client run in a private network namespace whose loopback has no netfilter rules (`LOOPBACK_NET=isolated`); HTTP/1.1 on loopback for both transports.
- Verified, not assumed: for each of the 24 repetitions in 8 process lifetimes the load client recorded the CPU affinity of every thread, the memory policy of every mapping and the network namespace of registry and client; all match the requested placement and the namespace the harness verified (only `lo`, empty nftables ruleset). The script stops otherwise.
- Foreign load: per repetition, the busy time of the pinned CPUs (user, nice, system, irq, softirq from `/proc/stat`) minus registry and client CPU time. A repetition is flagged when that remainder exceeds 0.3 s and 20% of the busy time. Flagged: 0 of 24 repetitions. Largest remainder: 0.90 s, 17% of the busy time of that repetition. The CPUs were also checked to be idle before every harness invocation.
- CPU time: `/proc/<pid>/stat` of the registry process, resolution 0.01 s per repetition. Access logging disabled, `OTEL_TRACES_EXPORTER=none`.
- Host: NVIDIA DGX GB200 Compute Tray, Neoverse-V2, 2 sockets with 72 cores each, aarch64, Linux 6.14.0-1015-nvidia-64k, page size 64 KiB, Ubuntu 24.04.3 LTS.
- Build: go1.26.10 linux/arm64, `go build -mod=vendor -trimpath ./cmd/registry`; main `f38cd9c0` (tree `0208cb1a`), bypass `910dd4f2` (tree `cf3fa2a7`). Source and Go version of every binary verified.
- Registry storage: ext4 on `nvme0n1p3` (SAMSUNG MZ1L21T9HCLS-00A07, not a rotating disk), readahead 256 KiB.

## Whole-blob GETs, cold page cache

One repetition is 8 GET requests, one for each of 8 distinct blobs of 1 GiB (8 GiB), one at a time or all at once. Before every repetition each blob file is dropped from the page cache with `posix_fadvise(POSIX_FADV_DONTNEED)`; `mincore()` showed no page of the files in the page cache before and every page after, in every repetition.

Storage: ext4 on SAMSUNG MZ1L21T9HCLS-00A07 (NVMe solid-state drive), readahead 256 KiB. A result on this device says nothing about rotating disks or network filesystems.

| Transport | Concurrency | Metric | main (mean ± sample SD, s) | n | bypass (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 1 | Wall time per repetition | 3.370 ± 0.060 | 6 | 3.396 ± 0.013 | 6 | +0.8% | yes |
| Plain HTTP | 1 | Registry total CPU time per repetition | 2.770 ± 0.030 | 6 | 2.835 ± 0.026 | 6 | +2.3% | yes |
| Plain HTTP | 1 | Registry user CPU time per repetition | 0.505 ± 0.023 | 6 | 0.1383 ± 0.0098 | 6 | -72.6% | yes |
| Plain HTTP | 1 | Registry kernel CPU time per repetition | 2.265 ± 0.029 | 6 | 2.697 ± 0.027 | 6 | +19.1% | yes |
| Plain HTTP | 8 | Wall time per repetition | 2.46 ± 0.25 | 6 | 2.56465 ± 0.00098 | 6 | +4.1% | no |
| Plain HTTP | 8 | Registry total CPU time per repetition | 2.803 ± 0.015 | 6 | 2.933 ± 0.018 | 6 | +4.6% | yes |
| Plain HTTP | 8 | Registry user CPU time per repetition | 0.557 ± 0.084 | 6 | 0.213 ± 0.018 | 6 | -61.7% | yes |
| Plain HTTP | 8 | Registry kernel CPU time per repetition | 2.247 ± 0.076 | 6 | 2.720 ± 0.022 | 6 | +21.1% | yes |

## Distributions

Checked for every case and arm, registry total CPU time and wall time: the sorted values are split at their largest gap; a bimodal candidate is reported when both sides hold at least three values and the gap is at least four pooled within-side sample SDs and 0.03 s.

- cold-c1-http, main, registry total CPU time: two groups, 3 values with mean 2.743 s and 3 values with mean 2.797 s, gap 0.040 s; the groups do not follow process lifetimes.

## Run

2 harness invocations, 175 s from the first to the last. Per-repetition values: `data.json`; raw harness result files: `sessions/`; harness logs: `logs/`.
