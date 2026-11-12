# fileReader bypass: registry CPU time and wall time against main

Measured 2026-11-12 with `repro/measure-filereader-bypass.py` (command: `--base 910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9 --bypass 0eb9d5768544e74a8410d282d83146f326148de1 --buffer-caps-kib  --cases whole-4mib,whole-32mib,range-1mib,range-32mib --transports tls --lifetimes 12 --repetitions 3 --out /path/to/sendfile-perf-repro/distribution/repro/pr5052-final-trees-20261112T042246Z/tls-lifetimes-5081-vs-5052 --report-name script-report.arm-main-is-5081.arm-bypass-is-5052.md`), which drives `repro/run-repro.sh`. Every arm and case: 12 process lifetime(s) of 3 repetitions. All ± values are sample standard deviations over repetitions.

## Arms

- main: upstream main, commit 910dd4f2, tree `cf3fa2a7`.
- bypass: bypass branch, commit 0eb9d576, tree `f7cc5450`.

## Method and environment

- Placement: registry and load client pinned to disjoint CPU sets of NUMA node 0 with `numactl --physcpubind --membind` (`NUMA_PIN=same-socket`): registry CPUs 0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70, client CPUs 1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71.
- Network: registry and client run in a private network namespace whose loopback has no netfilter rules (`LOOPBACK_NET=isolated`); HTTP/1.1 on loopback for both transports.
- Verified, not assumed: for each of the 288 repetitions in 96 process lifetimes the load client recorded the CPU affinity of every thread, the memory policy of every mapping and the network namespace of registry and client; all match the requested placement and the namespace the harness verified (only `lo`, empty nftables ruleset). The script stops otherwise.
- Foreign load: per repetition, the busy time of the pinned CPUs (user, nice, system, irq, softirq from `/proc/stat`) minus registry and client CPU time. A repetition is flagged when that remainder exceeds 0.3 s and 20% of the busy time. Flagged: 0 of 288 repetitions. Largest remainder: 3.00 s, 7% of the busy time of that repetition. The CPUs were also checked to be idle before every harness invocation.
- CPU time: `/proc/<pid>/stat` of the registry process, resolution 0.01 s per repetition. Access logging disabled, `OTEL_TRACES_EXPORTER=none`.
- Host: NVIDIA DGX GB200 Compute Tray, Neoverse-V2, 2 sockets with 72 cores each, aarch64, Linux 6.14.0-1015-nvidia-64k, page size 64 KiB, Ubuntu 24.04.3 LTS.
- Build: go1.26.10 linux/arm64, `go build -mod=vendor -trimpath ./cmd/registry`; main `910dd4f2` (tree `cf3fa2a7`), bypass `0eb9d576` (tree `f7cc5450`). Source and Go version of every binary verified.
- Registry storage: ext4 on `nvme0n1p3` (SAMSUNG MZ1L21T9HCLS-00A07, not a rotating disk), readahead 256 KiB.

## Whole-blob GETs, warm page cache

One repetition is the stated number of GET requests for one whole blob, 10 concurrent. Registry total CPU time per request is the registry total CPU time of a repetition divided by its requests. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

TLS:

| Blob size | Requests per repetition | main: registry total CPU time per request (mean ± sample SD, µs) | n | bypass: registry total CPU time per request (mean ± sample SD, µs) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 4 MiB | 1000 | 2407 ± 20 | 36 | 2346 ± 37 | 36 | -2.6% | no |
| 32 MiB | 500 | 17693 ± 141 | 36 | 17487 ± 92 | 36 | -1.2% | no |

<details>
<summary>Whole-blob GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| TLS | 4 MiB | main | 36 | 2.407 ± 0.020 | 1.131 ± 0.025 | 1.276 ± 0.028 | 2.397, 2.460, 2.410, 2.403, 2.407, 2.393, 2.410, 2.397, 2.390, 2.403, 2.417, 2.400 |
| TLS | 4 MiB | bypass | 36 | 2.346 ± 0.037 | 1.077 ± 0.025 | 1.269 ± 0.044 | 2.323, 2.330, 2.423, 2.340, 2.340, 2.327, 2.340, 2.317, 2.333, 2.340, 2.313, 2.423 |
| TLS | 32 MiB | main | 36 | 8.847 ± 0.070 | 3.543 ± 0.068 | 5.30 ± 0.10 | 8.847, 8.783, 8.780, 8.823, 8.870, 9.003, 8.903, 8.777, 8.820, 8.930, 8.787, 8.837 |
| TLS | 32 MiB | bypass | 36 | 8.743 ± 0.046 | 3.447 ± 0.064 | 5.296 ± 0.081 | 8.783, 8.767, 8.697, 8.797, 8.743, 8.743, 8.767, 8.757, 8.720, 8.797, 8.687, 8.663 |

</details>

## Range GETs, warm page cache

One repetition is 1000 GET requests, 10 concurrent, each for one range of a 512 MiB blob at a pseudo-random multiple of the range size. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

TLS:

| Range | Requests per repetition | main: registry total CPU time per repetition (mean ± sample SD, s) | n | bypass: registry total CPU time per repetition (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 32 MiB | 1000 | 19.16 ± 0.12 | 36 | 19.06 ± 0.11 | 36 | -0.5% | no |
| 1 MiB | 1000 | 0.947 ± 0.011 | 36 | 0.8861 ± 0.0093 | 36 | -6.4% | yes |

<details>
<summary>Range GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| TLS | 32 MiB range | main | 36 | 19.16 ± 0.12 | 7.114 ± 0.062 | 12.04 ± 0.14 | 19.187, 19.463, 19.167, 19.183, 19.123, 19.110, 19.073, 19.053, 19.220, 19.207, 18.993, 19.100 |
| TLS | 32 MiB range | bypass | 36 | 19.06 ± 0.11 | 6.976 ± 0.061 | 12.08 ± 0.12 | 19.020, 18.967, 18.983, 19.120, 18.997, 19.203, 19.007, 19.287, 19.157, 19.020, 18.960, 19.013 |
| TLS | 1 MiB range | main | 36 | 0.947 ± 0.011 | 0.501 ± 0.019 | 0.446 ± 0.018 | 0.943, 0.943, 0.970, 0.947, 0.943, 0.943, 0.940, 0.947, 0.947, 0.947, 0.950, 0.943 |
| TLS | 1 MiB range | bypass | 36 | 0.8861 ± 0.0093 | 0.458 ± 0.018 | 0.429 ± 0.017 | 0.883, 0.883, 0.887, 0.887, 0.883, 0.887, 0.887, 0.883, 0.903, 0.887, 0.883, 0.880 |

</details>

## Distributions

Checked for every case and arm, registry total CPU time and wall time: the sorted values are split at their largest gap; a bimodal candidate is reported when both sides hold at least three values and the gap is at least four pooled within-side sample SDs and 0.03 s.

- whole-4mib-tls, bypass, registry total CPU time: two groups, 30 values with mean 2.330 s and 6 values with mean 2.423 s, gap 0.060 s; the groups coincide with process lifetimes.

## Run

4 harness invocations, 302 s from the first to the last. Per-repetition values: `data.json`; raw harness result files: `sessions/`; harness logs: `logs/`.
