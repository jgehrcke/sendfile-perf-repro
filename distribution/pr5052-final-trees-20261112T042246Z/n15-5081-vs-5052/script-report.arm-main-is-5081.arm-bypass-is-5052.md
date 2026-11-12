# fileReader bypass: registry CPU time and wall time against main

Measured 2026-11-12 with `repro/measure-filereader-bypass.py` (command: `--base 910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9 --bypass 0eb9d5768544e74a8410d282d83146f326148de1 --buffer-caps-kib  --cases whole-4mib,whole-32mib,range-1mib,range-32mib --out /path/to/sendfile-perf-repro/distribution/repro/pr5052-final-trees-20261112T042246Z/n15-5081-vs-5052 --report-name script-report.arm-main-is-5081.arm-bypass-is-5052.md`), which drives `repro/run-repro.sh`. Every arm and case: 3 process lifetime(s) of 5 repetitions. All ± values are sample standard deviations over repetitions.

## Arms

- main: upstream main, commit 910dd4f2, tree `cf3fa2a7`.
- bypass: bypass branch, commit 0eb9d576, tree `f7cc5450`.

## Method and environment

- Placement: registry and load client pinned to disjoint CPU sets of NUMA node 0 with `numactl --physcpubind --membind` (`NUMA_PIN=same-socket`): registry CPUs 0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70, client CPUs 1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71.
- Network: registry and client run in a private network namespace whose loopback has no netfilter rules (`LOOPBACK_NET=isolated`); HTTP/1.1 on loopback for both transports.
- Verified, not assumed: for each of the 240 repetitions in 48 process lifetimes the load client recorded the CPU affinity of every thread, the memory policy of every mapping and the network namespace of registry and client; all match the requested placement and the namespace the harness verified (only `lo`, empty nftables ruleset). The script stops otherwise.
- Foreign load: per repetition, the busy time of the pinned CPUs (user, nice, system, irq, softirq from `/proc/stat`) minus registry and client CPU time. A repetition is flagged when that remainder exceeds 0.3 s and 20% of the busy time. Flagged: 0 of 240 repetitions. Largest remainder: 1.38 s, 7% of the busy time of that repetition. The CPUs were also checked to be idle before every harness invocation.
- CPU time: `/proc/<pid>/stat` of the registry process, resolution 0.01 s per repetition. Access logging disabled, `OTEL_TRACES_EXPORTER=none`.
- Host: NVIDIA DGX GB200 Compute Tray, Neoverse-V2, 2 sockets with 72 cores each, aarch64, Linux 6.14.0-1015-nvidia-64k, page size 64 KiB, Ubuntu 24.04.3 LTS.
- Build: go1.26.10 linux/arm64, `go build -mod=vendor -trimpath ./cmd/registry`; main `910dd4f2` (tree `cf3fa2a7`), bypass `0eb9d576` (tree `f7cc5450`). Source and Go version of every binary verified.
- Registry storage: ext4 on `nvme0n1p3` (SAMSUNG MZ1L21T9HCLS-00A07, not a rotating disk), readahead 256 KiB.

## Whole-blob GETs, warm page cache

One repetition is the stated number of GET requests for one whole blob, 10 concurrent. Registry total CPU time per request is the registry total CPU time of a repetition divided by its requests. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

Plain HTTP:

| Blob size | Requests per repetition | main: registry total CPU time per request (mean ± sample SD, µs) | n | bypass: registry total CPU time per request (mean ± sample SD, µs) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 4 MiB | 1000 | 1176 ± 14 | 15 | 433 ± 13 | 15 | -63.2% | yes |
| 32 MiB | 500 | 6981 ± 26 | 15 | 960 ± 20 | 15 | -86.2% | yes |

TLS:

| Blob size | Requests per repetition | main: registry total CPU time per request (mean ± sample SD, µs) | n | bypass: registry total CPU time per request (mean ± sample SD, µs) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 4 MiB | 1000 | 2405 ± 12 | 15 | 2349 ± 19 | 15 | -2.3% | yes |
| 32 MiB | 500 | 17608 ± 66 | 15 | 17429 ± 31 | 15 | -1.0% | yes |

<details>
<summary>Whole-blob GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 4 MiB | main | 15 | 1.176 ± 0.014 | 0.309 ± 0.025 | 0.867 ± 0.026 | 1.190, 1.164, 1.174 |
| Plain HTTP | 4 MiB | bypass | 15 | 0.433 ± 0.013 | 0.214 ± 0.017 | 0.219 ± 0.018 | 0.432, 0.446, 0.422 |
| Plain HTTP | 32 MiB | main | 15 | 3.491 ± 0.013 | 0.392 ± 0.020 | 3.099 ± 0.016 | 3.496, 3.486, 3.490 |
| Plain HTTP | 32 MiB | bypass | 15 | 0.480 ± 0.010 | 0.144 ± 0.012 | 0.336 ± 0.015 | 0.486, 0.482, 0.472 |
| TLS | 4 MiB | main | 15 | 2.405 ± 0.012 | 1.133 ± 0.020 | 1.272 ± 0.027 | 2.402, 2.394, 2.418 |
| TLS | 4 MiB | bypass | 15 | 2.349 ± 0.019 | 1.099 ± 0.026 | 1.249 ± 0.029 | 2.326, 2.356, 2.364 |
| TLS | 32 MiB | main | 15 | 8.804 ± 0.033 | 3.559 ± 0.051 | 5.245 ± 0.045 | 8.834, 8.806, 8.772 |
| TLS | 32 MiB | bypass | 15 | 8.715 ± 0.016 | 3.486 ± 0.082 | 5.229 ± 0.084 | 8.712, 8.720, 8.712 |

</details>

## Range GETs, warm page cache

One repetition is 1000 GET requests, 10 concurrent, each for one range of a 512 MiB blob at a pseudo-random multiple of the range size. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

Plain HTTP:

| Range | Requests per repetition | main: registry total CPU time per repetition (mean ± sample SD, s) | n | bypass: registry total CPU time per repetition (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 32 MiB | 1000 | 8.727 ± 0.029 | 15 | 1.035 ± 0.012 | 15 | -88.1% | yes |
| 1 MiB | 1000 | 0.6047 ± 0.0074 | 15 | 0.319 ± 0.011 | 15 | -47.3% | yes |

TLS:

| Range | Requests per repetition | main: registry total CPU time per repetition (mean ± sample SD, s) | n | bypass: registry total CPU time per repetition (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 32 MiB | 1000 | 19.268 ± 0.033 | 15 | 19.149 ± 0.068 | 15 | -0.6% | yes |
| 1 MiB | 1000 | 0.949 ± 0.011 | 15 | 0.8867 ± 0.0090 | 15 | -6.5% | yes |

<details>
<summary>Range GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 32 MiB range | main | 15 | 8.727 ± 0.029 | 0.833 ± 0.020 | 7.894 ± 0.035 | 8.742, 8.698, 8.742 |
| Plain HTTP | 32 MiB range | bypass | 15 | 1.035 ± 0.012 | 0.346 ± 0.020 | 0.689 ± 0.023 | 1.024, 1.042, 1.040 |
| Plain HTTP | 1 MiB range | main | 15 | 0.6047 ± 0.0074 | 0.291 ± 0.027 | 0.314 ± 0.024 | 0.602, 0.604, 0.608 |
| Plain HTTP | 1 MiB range | bypass | 15 | 0.319 ± 0.011 | 0.211 ± 0.014 | 0.108 ± 0.012 | 0.316, 0.320, 0.320 |
| TLS | 32 MiB range | main | 15 | 19.268 ± 0.033 | 7.132 ± 0.090 | 12.136 ± 0.099 | 19.248, 19.292, 19.264 |
| TLS | 32 MiB range | bypass | 15 | 19.149 ± 0.068 | 6.986 ± 0.049 | 12.163 ± 0.099 | 19.068, 19.184, 19.196 |
| TLS | 1 MiB range | main | 15 | 0.949 ± 0.011 | 0.497 ± 0.019 | 0.451 ± 0.018 | 0.948, 0.952, 0.946 |
| TLS | 1 MiB range | bypass | 15 | 0.8867 ± 0.0090 | 0.459 ± 0.016 | 0.428 ± 0.020 | 0.886, 0.884, 0.890 |

</details>

## Distributions

Checked for every case and arm, registry total CPU time and wall time: the sorted values are split at their largest gap; a bimodal candidate is reported when both sides hold at least three values and the gap is at least four pooled within-side sample SDs and 0.03 s.

No bimodal candidate.

## Run

8 harness invocations, 176 s from the first to the last. Per-repetition values: `data.json`; raw harness result files: `sessions/`; harness logs: `logs/`.
