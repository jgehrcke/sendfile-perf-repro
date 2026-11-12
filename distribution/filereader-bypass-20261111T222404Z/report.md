# fileReader bypass: registry CPU time and wall time against main

Measured 2026-11-11 with `repro/measure-filereader-bypass.py` (command: `no options`), which drives `repro/run-repro.sh`. Every arm and case: 3 process lifetime(s) of 5 repetitions. All ± values are sample standard deviations over repetitions.

## Arms

- main: upstream main, commit d14ff2fb, tree `74b77b34`.
- bypass: bypass branch, commit 9ccd294c, tree `03705608`.
- 32 KiB buffer: main with the fileReader buffer capped at 32 KiB instead of 4 MiB.
- 256 KiB buffer: main with the fileReader buffer capped at 256 KiB instead of 4 MiB.
- 1 MiB buffer: main with the fileReader buffer capped at 1024 KiB instead of 4 MiB.

## Method and environment

- Placement: registry and load client pinned to disjoint CPU sets of NUMA node 0 with `numactl --physcpubind --membind` (`NUMA_PIN=same-socket`): registry CPUs 0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70, client CPUs 1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71.
- Network: registry and client run in a private network namespace whose loopback has no netfilter rules (`LOOPBACK_NET=isolated`); HTTP/1.1 on loopback for both transports.
- Verified, not assumed: for each of the 1020 repetitions in 204 process lifetimes the load client recorded the CPU affinity of every thread, the memory policy of every mapping and the network namespace of registry and client; all match the requested placement and the namespace the harness verified (only `lo`, empty nftables ruleset). The script stops otherwise.
- Foreign load: per repetition, the busy time of the pinned CPUs (user, nice, system, irq, softirq from `/proc/stat`) minus registry and client CPU time. A repetition is flagged when that remainder exceeds 0.3 s and 20% of the busy time. Flagged: 7 of 1020 repetitions (sessions/cold-c1-http--buffer-1024kib/http/patched-default-n8-l1-r3.json, sessions/cold-c1-http--buffer-1024kib/http/patched-default-n8-l1-r5.json, sessions/cold-c1-tls--buffer-256kib/tls/patched-default-n8-l1-r1.json, sessions/cold-c1-tls--buffer-32kib/tls/patched-default-n8-l3-r5.json, sessions/cold-c8-http--buffer-256kib/http/patched-default-n8-l1-r1.json, sessions/cold-c8-http--buffer-256kib/http/patched-default-n8-l1-r4.json, sessions/cold-c8-http--main+bypass/http/unpatched-default-n8-l1-r1.json; they are included in the tables). Largest remainder: 5.25 s, 55% of the busy time of that repetition. The CPUs were also checked to be idle before every harness invocation.
- CPU time: `/proc/<pid>/stat` of the registry process, resolution 0.01 s per repetition. Access logging disabled, `OTEL_TRACES_EXPORTER=none`.
- Host: NVIDIA DGX GB200 Compute Tray, Neoverse-V2, 2 sockets with 72 cores each, aarch64, Linux 6.14.0-1015-nvidia-64k, page size 64 KiB, Ubuntu 24.04.3 LTS.
- Build: go1.26.10 linux/arm64, `go build -mod=vendor -trimpath ./cmd/registry`; main `d14ff2fb` (tree `74b77b34`), bypass `9ccd294c` (tree `03705608`). Source and Go version of every binary verified.
- Registry storage: ext4 on `nvme0n1p3` (SAMSUNG MZ1L21T9HCLS-00A07, not a rotating disk), readahead 256 KiB.

## Whole-blob GETs, warm page cache

One repetition is the stated number of GET requests for one whole blob, 10 concurrent. Registry total CPU time per request is the registry total CPU time of a repetition divided by its requests. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

Plain HTTP:

| Blob size | Requests per repetition | main: registry total CPU time per request (mean ± sample SD, µs) | n | bypass: registry total CPU time per request (mean ± sample SD, µs) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 KiB | 20000 | 225.1 ± 1.8 | 15 | 222.5 ± 1.4 | 15 | -1.2% | yes |
| 100 KiB | 5000 | 381.5 ± 4.2 | 15 | 309.6 ± 2.2 | 15 | -18.8% | yes |
| 4 MiB | 1000 | 1994 ± 26 | 15 | 1160.0 ± 9.3 | 15 | -41.8% | yes |
| 32 MiB | 500 | 9423 ± 61 | 15 | 6851 ± 21 | 15 | -27.3% | yes |

TLS:

| Blob size | Requests per repetition | main: registry total CPU time per request (mean ± sample SD, µs) | n | bypass: registry total CPU time per request (mean ± sample SD, µs) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 KiB | 20000 | 236.2 ± 2.7 | 15 | 236.3 ± 2.6 | 15 | +0.1% | no |
| 100 KiB | 5000 | 443.5 ± 3.6 | 15 | 375.5 ± 4.1 | 15 | -15.3% | yes |
| 4 MiB | 1000 | 3401 ± 27 | 15 | 2404 ± 18 | 15 | -29.3% | yes |
| 32 MiB | 500 | 20159 ± 63 | 15 | 17528 ± 113 | 15 | -13.0% | yes |

<details>
<summary>Whole-blob GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 1 KiB | main | 15 | 4.503 ± 0.037 | 3.646 ± 0.049 | 0.857 ± 0.044 | 4.486, 4.536, 4.486 |
| Plain HTTP | 1 KiB | bypass | 15 | 4.450 ± 0.028 | 3.634 ± 0.038 | 0.816 ± 0.033 | 4.450, 4.460, 4.440 |
| Plain HTTP | 100 KiB | main | 15 | 1.907 ± 0.021 | 1.445 ± 0.037 | 0.462 ± 0.034 | 1.918, 1.916, 1.888 |
| Plain HTTP | 100 KiB | bypass | 15 | 1.548 ± 0.011 | 1.130 ± 0.019 | 0.418 ± 0.015 | 1.544, 1.548, 1.552 |
| Plain HTTP | 4 MiB | main | 15 | 1.994 ± 0.026 | 1.031 ± 0.042 | 0.963 ± 0.034 | 1.994, 2.000, 1.988 |
| Plain HTTP | 4 MiB | bypass | 15 | 1.1600 ± 0.0093 | 0.307 ± 0.023 | 0.853 ± 0.023 | 1.162, 1.160, 1.158 |
| Plain HTTP | 32 MiB | main | 15 | 4.711 ± 0.030 | 1.449 ± 0.049 | 3.263 ± 0.045 | 4.696, 4.690, 4.748 |
| Plain HTTP | 32 MiB | bypass | 15 | 3.425 ± 0.011 | 0.381 ± 0.023 | 3.044 ± 0.026 | 3.420, 3.432, 3.424 |
| TLS | 1 KiB | main | 15 | 4.723 ± 0.054 | 3.855 ± 0.047 | 0.869 ± 0.028 | 4.700, 4.770, 4.700 |
| TLS | 1 KiB | bypass | 15 | 4.726 ± 0.052 | 3.866 ± 0.064 | 0.860 ± 0.032 | 4.756, 4.716, 4.706 |
| TLS | 100 KiB | main | 15 | 2.217 ± 0.018 | 1.669 ± 0.033 | 0.549 ± 0.028 | 2.228, 2.204, 2.220 |
| TLS | 100 KiB | bypass | 15 | 1.877 ± 0.021 | 1.387 ± 0.028 | 0.490 ± 0.027 | 1.856, 1.884, 1.892 |
| TLS | 4 MiB | main | 15 | 3.401 ± 0.027 | 1.969 ± 0.040 | 1.431 ± 0.040 | 3.398, 3.398, 3.406 |
| TLS | 4 MiB | bypass | 15 | 2.404 ± 0.018 | 1.125 ± 0.024 | 1.279 ± 0.026 | 2.422, 2.392, 2.398 |
| TLS | 32 MiB | main | 15 | 10.079 ± 0.032 | 4.994 ± 0.060 | 5.085 ± 0.074 | 10.054, 10.110, 10.074 |
| TLS | 32 MiB | bypass | 15 | 8.764 ± 0.057 | 3.501 ± 0.093 | 5.26 ± 0.10 | 8.708, 8.832, 8.752 |

</details>

## Range GETs, warm page cache

One repetition is 1000 GET requests, 10 concurrent, each for one range of a 512 MiB blob at a pseudo-random multiple of the range size. "Separated" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.

Plain HTTP:

| Range | Requests per repetition | main: registry total CPU time per repetition (mean ± sample SD, s) | n | bypass: registry total CPU time per repetition (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 32 MiB | 1000 | 10.657 ± 0.089 | 15 | 8.609 ± 0.017 | 15 | -19.2% | yes |
| 1 MiB | 1000 | 1.470 ± 0.037 | 15 | 0.6140 ± 0.0091 | 15 | -58.2% | yes |

TLS:

| Range | Requests per repetition | main: registry total CPU time per repetition (mean ± sample SD, s) | n | bypass: registry total CPU time per repetition (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 32 MiB | 1000 | 21.025 ± 0.096 | 15 | 19.051 ± 0.059 | 15 | -9.4% | yes |
| 1 MiB | 1000 | 1.869 ± 0.023 | 15 | 0.9453 ± 0.0074 | 15 | -49.4% | yes |

<details>
<summary>Range GETs, warm page cache: user and kernel CPU time, process lifetime means</summary>

Seconds per repetition.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 32 MiB range | main | 15 | 10.657 ± 0.089 | 3.107 ± 0.081 | 7.551 ± 0.056 | 10.762, 10.580, 10.630 |
| Plain HTTP | 32 MiB range | bypass | 15 | 8.609 ± 0.017 | 0.829 ± 0.034 | 7.780 ± 0.040 | 8.616, 8.602, 8.608 |
| Plain HTTP | 1 MiB range | main | 15 | 1.470 ± 0.037 | 0.771 ± 0.032 | 0.699 ± 0.030 | 1.466, 1.464, 1.480 |
| Plain HTTP | 1 MiB range | bypass | 15 | 0.6140 ± 0.0091 | 0.285 ± 0.024 | 0.329 ± 0.024 | 0.618, 0.610, 0.614 |
| TLS | 32 MiB range | main | 15 | 21.025 ± 0.096 | 9.96 ± 0.11 | 11.062 ± 0.095 | 20.962, 21.150, 20.962 |
| TLS | 32 MiB range | bypass | 15 | 19.051 ± 0.059 | 7.053 ± 0.071 | 11.998 ± 0.083 | 19.006, 19.032, 19.114 |
| TLS | 1 MiB range | main | 15 | 1.869 ± 0.023 | 1.045 ± 0.027 | 0.824 ± 0.031 | 1.872, 1.882, 1.852 |
| TLS | 1 MiB range | bypass | 15 | 0.9453 ± 0.0074 | 0.502 ± 0.024 | 0.443 ± 0.024 | 0.944, 0.946, 0.946 |

</details>

## Whole-blob GETs, cold page cache

One repetition is 8 GET requests, one for each of 8 distinct blobs of 1 GiB (8 GiB), one at a time or all at once. Before every repetition each blob file is dropped from the page cache with `posix_fadvise(POSIX_FADV_DONTNEED)`; `mincore()` showed no page of the files in the page cache before and every page after, in every repetition.

Storage: ext4 on SAMSUNG MZ1L21T9HCLS-00A07 (NVMe solid-state drive), readahead 256 KiB. A result on this device says nothing about rotating disks or network filesystems.

| Transport | Concurrency | Metric | main (mean ± sample SD, s) | n | bypass (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | 1 | Wall time per repetition | 3.327 ± 0.044 | 15 | 3.372 ± 0.021 | 15 | +1.4% | yes |
| Plain HTTP | 1 | Registry total CPU time per repetition | 2.736 ± 0.033 | 15 | 2.793 ± 0.032 | 15 | +2.1% | yes |
| Plain HTTP | 1 | Registry user CPU time per repetition | 0.491 ± 0.020 | 15 | 0.1500 ± 0.0093 | 15 | -69.5% | yes |
| Plain HTTP | 1 | Registry kernel CPU time per repetition | 2.245 ± 0.026 | 15 | 2.643 ± 0.032 | 15 | +17.7% | yes |
| Plain HTTP | 8 | Wall time per repetition | 2.52 ± 0.17 | 15 | 2.56416 ± 0.00066 | 15 | +1.6% | no |
| Plain HTTP | 8 | Registry total CPU time per repetition | 2.797 ± 0.030 | 15 | 2.879 ± 0.018 | 15 | +3.0% | yes |
| Plain HTTP | 8 | Registry user CPU time per repetition | 0.51 ± 0.10 | 15 | 0.202 ± 0.011 | 15 | -60.2% | yes |
| Plain HTTP | 8 | Registry kernel CPU time per repetition | 2.289 ± 0.099 | 15 | 2.677 ± 0.019 | 15 | +16.9% | yes |
| TLS | 1 | Wall time per repetition | 5.959 ± 0.046 | 15 | 5.544 ± 0.052 | 15 | -7.0% | yes |
| TLS | 1 | Registry total CPU time per repetition | 5.303 ± 0.038 | 15 | 5.553 ± 0.053 | 15 | +4.7% | yes |
| TLS | 1 | Registry user CPU time per repetition | 2.117 ± 0.045 | 15 | 1.727 ± 0.036 | 15 | -18.4% | yes |
| TLS | 1 | Registry kernel CPU time per repetition | 3.185 ± 0.030 | 15 | 3.826 ± 0.060 | 15 | +20.1% | yes |
| TLS | 8 | Wall time per repetition | 2.5684 ± 0.0037 | 15 | 2.5664 ± 0.0037 | 15 | -0.1% | yes |
| TLS | 8 | Registry total CPU time per repetition | 5.143 ± 0.031 | 15 | 5.491 ± 0.028 | 15 | +6.8% | yes |
| TLS | 8 | Registry user CPU time per repetition | 2.189 ± 0.044 | 15 | 1.793 ± 0.031 | 15 | -18.1% | yes |
| TLS | 8 | Registry kernel CPU time per repetition | 2.954 ± 0.034 | 15 | 3.697 ± 0.049 | 15 | +25.2% | yes |

## Smaller fileReader buffers against the bypass

The buffer arms are main with only the cap of the `fileReader` read buffer changed (4 MiB on main). Seconds per repetition. "Against the bypass" is the change of the mean from the bypass to the arm; "separated" compares process lifetime means as above.

| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Against the bypass | Separated from the bypass | Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Wall time (mean ± sample SD, s) | Wall time against the bypass |
| --- | --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| Plain HTTP | 4 MiB, whole blob | main | 15 | 1.994 ± 0.026 | +71.9% | yes | 1.031 ± 0.042 | 0.963 ± 0.034 | 0.1909 ± 0.0015 | +66.9% |
| Plain HTTP | 4 MiB, whole blob | 32 KiB buffer | 15 | 1.210 ± 0.010 | +4.3% | yes | 0.346 ± 0.024 | 0.864 ± 0.022 | 0.11993 ± 0.00081 | +4.9% |
| Plain HTTP | 4 MiB, whole blob | 256 KiB buffer | 15 | 1.437 ± 0.013 | +23.9% | yes | 0.564 ± 0.027 | 0.873 ± 0.019 | 0.1409 ± 0.0014 | +23.2% |
| Plain HTTP | 4 MiB, whole blob | 1 MiB buffer | 15 | 1.676 ± 0.018 | +44.5% | yes | 0.758 ± 0.027 | 0.918 ± 0.021 | 0.1631 ± 0.0024 | +42.6% |
| Plain HTTP | 4 MiB, whole blob | bypass | 15 | 1.1600 ± 0.0093 |  |  | 0.307 ± 0.023 | 0.853 ± 0.023 | 0.1144 ± 0.0011 |  |
| TLS | 4 MiB, whole blob | main | 15 | 3.401 ± 0.027 | +41.5% | yes | 1.969 ± 0.040 | 1.431 ± 0.040 | 0.3399 ± 0.0020 | +35.9% |
| TLS | 4 MiB, whole blob | 32 KiB buffer | 15 | 2.447 ± 0.015 | +1.8% | yes | 1.165 ± 0.030 | 1.282 ± 0.027 | 0.2544 ± 0.0015 | +1.7% |
| TLS | 4 MiB, whole blob | 256 KiB buffer | 15 | 2.711 ± 0.037 | +12.8% | yes | 1.402 ± 0.029 | 1.309 ± 0.042 | 0.2787 ± 0.0033 | +11.4% |
| TLS | 4 MiB, whole blob | 1 MiB buffer | 15 | 3.057 ± 0.015 | +27.1% | yes | 1.703 ± 0.039 | 1.353 ± 0.032 | 0.3092 ± 0.0013 | +23.6% |
| TLS | 4 MiB, whole blob | bypass | 15 | 2.404 ± 0.018 |  |  | 1.125 ± 0.024 | 1.279 ± 0.026 | 0.2501 ± 0.0012 |  |
| Plain HTTP | 32 MiB, whole blob | main | 15 | 4.711 ± 0.030 | +37.5% | yes | 1.449 ± 0.049 | 3.263 ± 0.045 | 0.4720 ± 0.0027 | +37.1% |
| Plain HTTP | 32 MiB, whole blob | 32 KiB buffer | 15 | 3.493 ± 0.018 | +2.0% | yes | 0.419 ± 0.030 | 3.073 ± 0.026 | 0.3512 ± 0.0026 | +2.0% |
| Plain HTTP | 32 MiB, whole blob | 256 KiB buffer | 15 | 3.759 ± 0.014 | +9.8% | yes | 0.769 ± 0.022 | 2.991 ± 0.021 | 0.3775 ± 0.0020 | +9.6% |
| Plain HTTP | 32 MiB, whole blob | 1 MiB buffer | 15 | 4.495 ± 0.031 | +31.2% | yes | 1.235 ± 0.024 | 3.261 ± 0.037 | 0.4531 ± 0.0028 | +31.6% |
| Plain HTTP | 32 MiB, whole blob | bypass | 15 | 3.425 ± 0.011 |  |  | 0.381 ± 0.023 | 3.044 ± 0.026 | 0.3443 ± 0.0014 |  |
| TLS | 32 MiB, whole blob | main | 15 | 10.079 ± 0.032 | +15.0% | yes | 4.994 ± 0.060 | 5.085 ± 0.074 | 1.0131 ± 0.0044 | +14.6% |
| TLS | 32 MiB, whole blob | 32 KiB buffer | 15 | 8.89 ± 0.12 | +1.4% | no | 3.517 ± 0.054 | 5.37 ± 0.15 | 0.898 ± 0.016 | +1.6% |
| TLS | 32 MiB, whole blob | 256 KiB buffer | 15 | 8.800 ± 0.050 | +0.4% | no | 3.950 ± 0.090 | 4.850 ± 0.095 | 0.8909 ± 0.0079 | +0.8% |
| TLS | 32 MiB, whole blob | 1 MiB buffer | 15 | 9.661 ± 0.040 | +10.2% | yes | 4.648 ± 0.062 | 5.013 ± 0.072 | 0.9754 ± 0.0056 | +10.3% |
| TLS | 32 MiB, whole blob | bypass | 15 | 8.764 ± 0.057 |  |  | 3.501 ± 0.093 | 5.26 ± 0.10 | 0.8840 ± 0.0073 |  |
| Plain HTTP | 32 MiB range | main | 15 | 10.657 ± 0.089 | +23.8% | yes | 3.107 ± 0.081 | 7.551 ± 0.056 | 1.0499 ± 0.0084 | +22.1% |
| Plain HTTP | 32 MiB range | 32 KiB buffer | 15 | 8.58 ± 0.16 | -0.3% | no | 0.899 ± 0.032 | 7.68 ± 0.14 | 0.857 ± 0.016 | -0.3% |
| Plain HTTP | 32 MiB range | 256 KiB buffer | 15 | 9.471 ± 0.021 | +10.0% | yes | 1.643 ± 0.043 | 7.827 ± 0.033 | 0.9425 ± 0.0022 | +9.6% |
| Plain HTTP | 32 MiB range | 1 MiB buffer | 15 | 10.45 ± 0.14 | +21.4% | yes | 2.707 ± 0.061 | 7.74 ± 0.12 | 1.036 ± 0.013 | +20.5% |
| Plain HTTP | 32 MiB range | bypass | 15 | 8.609 ± 0.017 |  |  | 0.829 ± 0.034 | 7.780 ± 0.040 | 0.8599 ± 0.0016 |  |
| TLS | 32 MiB range | main | 15 | 21.025 ± 0.096 | +10.4% | yes | 9.96 ± 0.11 | 11.062 ± 0.095 | 2.1004 ± 0.0099 | +10.0% |
| TLS | 32 MiB range | 32 KiB buffer | 15 | 19.187 ± 0.057 | +0.7% | yes | 7.167 ± 0.055 | 12.019 ± 0.086 | 1.9261 ± 0.0053 | +0.9% |
| TLS | 32 MiB range | 256 KiB buffer | 15 | 19.143 ± 0.052 | +0.5% | no | 7.980 ± 0.081 | 11.163 ± 0.097 | 1.9180 ± 0.0054 | +0.4% |
| TLS | 32 MiB range | 1 MiB buffer | 15 | 20.526 ± 0.094 | +7.7% | yes | 9.35 ± 0.10 | 11.173 ± 0.091 | 2.0580 ± 0.0069 | +7.8% |
| TLS | 32 MiB range | bypass | 15 | 19.051 ± 0.059 |  |  | 7.053 ± 0.071 | 11.998 ± 0.083 | 1.9095 ± 0.0074 |  |
| Plain HTTP | 1 MiB range | main | 15 | 1.470 ± 0.037 | +139.4% | yes | 0.771 ± 0.032 | 0.699 ± 0.030 | 0.1399 ± 0.0038 | +116.0% |
| Plain HTTP | 1 MiB range | 32 KiB buffer | 15 | 0.6427 ± 0.0080 | +4.7% | yes | 0.317 ± 0.018 | 0.325 ± 0.017 | 0.0662 ± 0.0014 | +2.2% |
| Plain HTTP | 1 MiB range | 256 KiB buffer | 15 | 0.781 ± 0.010 | +27.1% | yes | 0.432 ± 0.017 | 0.349 ± 0.016 | 0.0783 ± 0.0011 | +20.8% |
| Plain HTTP | 1 MiB range | 1 MiB buffer | 15 | 1.074 ± 0.034 | +74.9% | yes | 0.691 ± 0.036 | 0.383 ± 0.022 | 0.1196 ± 0.0046 | +84.6% |
| Plain HTTP | 1 MiB range | bypass | 15 | 0.6140 ± 0.0091 |  |  | 0.285 ± 0.024 | 0.329 ± 0.024 | 0.0648 ± 0.0019 |  |
| TLS | 1 MiB range | main | 15 | 1.869 ± 0.023 | +97.7% | yes | 1.045 ± 0.027 | 0.824 ± 0.031 | 0.1814 ± 0.0024 | +57.9% |
| TLS | 1 MiB range | 32 KiB buffer | 15 | 1.005 ± 0.013 | +6.3% | yes | 0.547 ± 0.016 | 0.457 ± 0.018 | 0.1187 ± 0.0014 | +3.4% |
| TLS | 1 MiB range | 256 KiB buffer | 15 | 1.163 ± 0.011 | +23.0% | yes | 0.689 ± 0.021 | 0.473 ± 0.018 | 0.1279 ± 0.0015 | +11.3% |
| TLS | 1 MiB range | 1 MiB buffer | 15 | 1.361 ± 0.021 | +44.0% | yes | 0.863 ± 0.029 | 0.499 ± 0.028 | 0.1451 ± 0.0031 | +26.3% |
| TLS | 1 MiB range | bypass | 15 | 0.9453 ± 0.0074 |  |  | 0.502 ± 0.024 | 0.443 ± 0.024 | 0.1149 ± 0.0011 |  |
| Plain HTTP | 8 blobs of 1 GiB, one at a time, cold page cache | main | 15 | 2.736 ± 0.033 | -2.0% | yes | 0.491 ± 0.020 | 2.245 ± 0.026 | 3.327 ± 0.044 | -1.3% |
| Plain HTTP | 8 blobs of 1 GiB, one at a time, cold page cache | 32 KiB buffer | 15 | 2.841 ± 0.033 | +1.7% | no | 0.153 ± 0.015 | 2.689 ± 0.039 | 3.395 ± 0.016 | +0.7% |
| Plain HTTP | 8 blobs of 1 GiB, one at a time, cold page cache | 256 KiB buffer | 15 | 2.927 ± 0.021 | +4.8% | yes | 0.293 ± 0.022 | 2.634 ± 0.027 | 3.443 ± 0.022 | +2.1% |
| Plain HTTP | 8 blobs of 1 GiB, one at a time, cold page cache | 1 MiB buffer | 15 | 2.624 ± 0.018 | -6.0% | yes | 0.327 ± 0.018 | 2.297 ± 0.027 | 2.603 ± 0.017 | -22.8% |
| Plain HTTP | 8 blobs of 1 GiB, one at a time, cold page cache | bypass | 15 | 2.793 ± 0.032 |  |  | 0.1500 ± 0.0093 | 2.643 ± 0.032 | 3.372 ± 0.021 |  |
| TLS | 8 blobs of 1 GiB, one at a time, cold page cache | main | 15 | 5.303 ± 0.038 | -4.5% | yes | 2.117 ± 0.045 | 3.185 ± 0.030 | 5.959 ± 0.046 | +7.5% |
| TLS | 8 blobs of 1 GiB, one at a time, cold page cache | 32 KiB buffer | 15 | 5.509 ± 0.066 | -0.8% | no | 1.739 ± 0.043 | 3.771 ± 0.072 | 5.502 ± 0.065 | -0.8% |
| TLS | 8 blobs of 1 GiB, one at a time, cold page cache | 256 KiB buffer | 15 | 5.284 ± 0.028 | -4.8% | yes | 1.902 ± 0.029 | 3.382 ± 0.042 | 5.282 ± 0.030 | -4.7% |
| TLS | 8 blobs of 1 GiB, one at a time, cold page cache | 1 MiB buffer | 15 | 5.185 ± 0.075 | -6.6% | yes | 1.971 ± 0.027 | 3.214 ± 0.071 | 5.159 ± 0.074 | -7.0% |
| TLS | 8 blobs of 1 GiB, one at a time, cold page cache | bypass | 15 | 5.553 ± 0.053 |  |  | 1.727 ± 0.036 | 3.826 ± 0.060 | 5.544 ± 0.052 |  |
| Plain HTTP | 8 blobs of 1 GiB, all at once, cold page cache | main | 15 | 2.797 ± 0.030 | -2.9% | yes | 0.51 ± 0.10 | 2.289 ± 0.099 | 2.52 ± 0.17 | -1.6% |
| Plain HTTP | 8 blobs of 1 GiB, all at once, cold page cache | 32 KiB buffer | 15 | 2.887 ± 0.025 | +0.3% | no | 0.2060 ± 0.0083 | 2.681 ± 0.024 | 2.5649 ± 0.0020 | +0.0% |
| Plain HTTP | 8 blobs of 1 GiB, all at once, cold page cache | 256 KiB buffer | 15 | 2.931 ± 0.027 | +1.8% | yes | 0.334 ± 0.015 | 2.597 ± 0.026 | 2.56422 ± 0.00087 | +0.0% |
| Plain HTTP | 8 blobs of 1 GiB, all at once, cold page cache | 1 MiB buffer | 15 | 2.659 ± 0.015 | -7.6% | yes | 0.372 ± 0.028 | 2.287 ± 0.021 | 2.56464 ± 0.00074 | +0.0% |
| Plain HTTP | 8 blobs of 1 GiB, all at once, cold page cache | bypass | 15 | 2.879 ± 0.018 |  |  | 0.202 ± 0.011 | 2.677 ± 0.019 | 2.56416 ± 0.00066 |  |
| TLS | 8 blobs of 1 GiB, all at once, cold page cache | main | 15 | 5.143 ± 0.031 | -6.3% | yes | 2.189 ± 0.044 | 2.954 ± 0.034 | 2.5684 ± 0.0037 | +0.1% |
| TLS | 8 blobs of 1 GiB, all at once, cold page cache | 32 KiB buffer | 15 | 5.475 ± 0.022 | -0.3% | no | 1.807 ± 0.031 | 3.669 ± 0.035 | 2.570 ± 0.012 | +0.1% |
| TLS | 8 blobs of 1 GiB, all at once, cold page cache | 256 KiB buffer | 15 | 5.004 ± 0.041 | -8.9% | yes | 1.980 ± 0.030 | 3.024 ± 0.034 | 2.5685 ± 0.0069 | +0.1% |
| TLS | 8 blobs of 1 GiB, all at once, cold page cache | 1 MiB buffer | 15 | 4.858 ± 0.030 | -11.5% | yes | 2.049 ± 0.040 | 2.809 ± 0.038 | 2.570 ± 0.010 | +0.1% |
| TLS | 8 blobs of 1 GiB, all at once, cold page cache | bypass | 15 | 5.491 ± 0.028 |  |  | 1.793 ± 0.031 | 3.697 ± 0.049 | 2.5664 ± 0.0037 |  |

Buffer arms were not measured for: whole-100kib, whole-1kib.

## Distributions

Checked for every case and arm, registry total CPU time and wall time: the sorted values are split at their largest gap; a bimodal candidate is reported when both sides hold at least three values and the gap is at least four pooled within-side sample SDs and 0.03 s.

- whole-4mib-tls, 256 KiB buffer, registry total CPU time: two groups, 10 values with mean 2.687 s and 5 values with mean 2.758 s, gap 0.050 s; the groups coincide with process lifetimes.

## Run

52 harness invocations, 1697 s from the first to the last. Per-repetition values: `data.json`; raw harness result files: `sessions/`; harness logs: `logs/`.
