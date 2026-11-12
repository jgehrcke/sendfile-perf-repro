# fileReader bypass: registry CPU time and wall time against main

Measured 2026-11-12 with `repro/measure-filereader-bypass.py` (command: `--base f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b --bypass 910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9 --buffer-caps-kib  --cases whole-4mib,whole-32mib,range-1mib,range-32mib --out /path/to/sendfile-perf-repro/distribution/repro/pr5052-final-trees-20261112T042246Z/n15-main-vs-5081 --report-name script-report.md`), which drives `repro/run-repro.sh`. Every arm and case: 3 process lifetime(s) of 5 repetitions. All ± values are sample standard deviations over repetitions.

## Arms

- main: upstream main, commit f38cd9c0, tree `0208cb1a`.
- bypass: bypass branch, commit 910dd4f2, tree `cf3fa2a7`.

## Method and environment

- Placement: registry and load client pinned to disjoint CPU sets of NUMA node 0 with `numactl --physcpubind --membind` (`NUMA_PIN=same-socket`): registry CPUs 0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70, client CPUs 1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71.
- Network: registry and client run in a private network namespace whose loopback has no netfilter rules (`LOOPBACK_NET=isolated`); HTTP/1.1 on loopback for both transports.
- Verified, not assumed: for each of the 240 repetitions in 48 process lifetimes the load client recorded the CPU affinity of every thread, the memory policy of every mapping and the network namespace of registry and client; all match the requested placement and the namespace the harness verified (only `lo`, empty nftables ruleset). The script stops otherwise.
- Foreign load: per repetition, the busy time of the pinned CPUs (user, nice, system, irq, softirq from `/proc/stat`) minus registry and client CPU time. A repetition is flagged when that remainder exceeds 0.3 s and 20% of the busy time. Flagged: 0 of 240 repetitions. Largest remainder: 3.03 s, 7% of the busy time of that repetition. The CPUs were also checked to be idle before every harness invocation.
- CPU time: `/proc/<pid>/stat` of the registry process, resolution 0.01 s per repetition. Access logging disabled, `OTEL_TRACES_EXPORTER=none`.
- Host: NVIDIA DGX GB200 Compute Tray, Neoverse-V2, 2 sockets with 72 cores each, aarch64, Linux 6.14.0-1015-nvidia-64k, page size 64 KiB, Ubuntu 24.04.3 LTS.
- Build: go1.26.10 linux/arm64, `go build -mod=vendor -trimpath ./cmd/registry`; main `f38cd9c0` (tree `0208cb1a`), bypass `910dd4f2` (tree `cf3fa2a7`). Source and Go version of every binary verified.
- Registry storage: ext4 on `nvme0n1p3` (SAMSUNG MZ1L21T9HCLS-00A07, not a rotating disk), readahead 256 KiB.

## Whole-blob GETs, warm page cache

One repetition is the stated number of GET requests for one whole blob, 10 concurrent. Registry total CPU time per request is the registry total CPU time of a repetition divided by its requests. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

Plain HTTP:

| Blob size | Requests per repetition | main: registry total CPU time per request (mean ± sample SD, µs) | n | bypass: registry total CPU time per request (mean ± sample SD, µs) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 4 MiB | 1000 | 1983 ± 28 | 15 | 1153 ± 12 | 15 | -41.9% | yes |
| 32 MiB | 500 | 9509 ± 123 | 15 | 6920 ± 65 | 15 | -27.2% | yes |

TLS:

| Blob size | Requests per repetition | main: registry total CPU time per request (mean ± sample SD, µs) | n | bypass: registry total CPU time per request (mean ± sample SD, µs) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 4 MiB | 1000 | 3393 ± 32 | 15 | 2394 ± 12 | 15 | -29.4% | yes |
| 32 MiB | 500 | 20263 ± 79 | 15 | 17700 ± 86 | 15 | -12.6% | yes |

<details>
<summary>Whole-blob GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 4 MiB | main | 15 | 1.983 ± 0.028 | 1.033 ± 0.043 | 0.950 ± 0.030 | 1.984, 1.972, 1.994 |
| Plain HTTP | 4 MiB | bypass | 15 | 1.153 ± 0.012 | 0.318 ± 0.027 | 0.835 ± 0.025 | 1.150, 1.154, 1.154 |
| Plain HTTP | 32 MiB | main | 15 | 4.755 ± 0.062 | 1.451 ± 0.039 | 3.304 ± 0.043 | 4.770, 4.678, 4.816 |
| Plain HTTP | 32 MiB | bypass | 15 | 3.460 ± 0.032 | 0.382 ± 0.021 | 3.078 ± 0.031 | 3.500, 3.436, 3.444 |
| TLS | 4 MiB | main | 15 | 3.393 ± 0.032 | 1.940 ± 0.055 | 1.453 ± 0.046 | 3.406, 3.384, 3.390 |
| TLS | 4 MiB | bypass | 15 | 2.394 ± 0.012 | 1.131 ± 0.034 | 1.263 ± 0.030 | 2.392, 2.386, 2.404 |
| TLS | 32 MiB | main | 15 | 10.131 ± 0.040 | 5.004 ± 0.050 | 5.127 ± 0.062 | 10.090, 10.174, 10.130 |
| TLS | 32 MiB | bypass | 15 | 8.850 ± 0.043 | 3.542 ± 0.076 | 5.308 ± 0.086 | 8.812, 8.836, 8.902 |

</details>

## Range GETs, warm page cache

One repetition is 1000 GET requests, 10 concurrent, each for one range of a 512 MiB blob at a pseudo-random multiple of the range size. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

Plain HTTP:

| Range | Requests per repetition | main: registry total CPU time per repetition (mean ± sample SD, s) | n | bypass: registry total CPU time per repetition (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 32 MiB | 1000 | 10.691 ± 0.056 | 15 | 8.620 ± 0.029 | 15 | -19.4% | yes |
| 1 MiB | 1000 | 1.468 ± 0.033 | 15 | 0.6040 ± 0.0063 | 15 | -58.9% | yes |

TLS:

| Range | Requests per repetition | main: registry total CPU time per repetition (mean ± sample SD, s) | n | bypass: registry total CPU time per repetition (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 32 MiB | 1000 | 21.16 ± 0.11 | 15 | 19.31 ± 0.11 | 15 | -8.7% | yes |
| 1 MiB | 1000 | 1.865 ± 0.016 | 15 | 0.9467 ± 0.0082 | 15 | -49.2% | yes |

<details>
<summary>Range GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 32 MiB range | main | 15 | 10.691 ± 0.056 | 3.121 ± 0.078 | 7.571 ± 0.049 | 10.734, 10.704, 10.636 |
| Plain HTTP | 32 MiB range | bypass | 15 | 8.620 ± 0.029 | 0.832 ± 0.025 | 7.788 ± 0.038 | 8.654, 8.614, 8.592 |
| Plain HTTP | 1 MiB range | main | 15 | 1.468 ± 0.033 | 0.789 ± 0.027 | 0.679 ± 0.024 | 1.470, 1.462, 1.472 |
| Plain HTTP | 1 MiB range | bypass | 15 | 0.6040 ± 0.0063 | 0.280 ± 0.016 | 0.324 ± 0.016 | 0.602, 0.606, 0.604 |
| TLS | 32 MiB range | main | 15 | 21.16 ± 0.11 | 10.06 ± 0.10 | 11.10 ± 0.15 | 21.314, 21.102, 21.072 |
| TLS | 32 MiB range | bypass | 15 | 19.31 ± 0.11 | 7.133 ± 0.074 | 12.18 ± 0.14 | 19.186, 19.430, 19.324 |
| TLS | 1 MiB range | main | 15 | 1.865 ± 0.016 | 1.029 ± 0.034 | 0.836 ± 0.041 | 1.868, 1.864, 1.864 |
| TLS | 1 MiB range | bypass | 15 | 0.9467 ± 0.0082 | 0.499 ± 0.017 | 0.447 ± 0.017 | 0.948, 0.946, 0.946 |

</details>

## Distributions

Checked for every case and arm, registry total CPU time and wall time: the sorted values are split at their largest gap; a bimodal candidate is reported when both sides hold at least three values and the gap is at least four pooled within-side sample SDs and 0.03 s.

- range-32mib-tls, main, registry total CPU time: two groups, 10 values with mean 21.087 s and 5 values with mean 21.314 s, gap 0.150 s; the groups coincide with process lifetimes.

## Run

8 harness invocations, 201 s from the first to the last. Per-repetition values: `data.json`; raw harness result files: `sessions/`; harness logs: `logs/`.
