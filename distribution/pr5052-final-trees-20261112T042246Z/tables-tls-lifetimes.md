(missing: data.json of main-vs-5081)
## Whole-blob GET: registry total CPU time per GET, ms (mean ± sample SD, n=36 per cell)

| Transport | Blob | main | #5081 (with main) | #5081 (with #5052) | #5052 | Change of the mean, #5081 (with #5052) to #5052 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| TLS | 4 MiB | not measured | not measured | 2.407 ± 0.020 | 2.346 ± 0.037 | -2.6% |
| TLS | 32 MiB | not measured | not measured | 17.69 ± 0.14 | 17.487 ± 0.092 | -1.2% |

## Range GET (ranges of a 512 MiB blob): registry total CPU time per GET, ms (mean ± sample SD, n=36 per cell)

| Transport | Range | main | #5081 (with main) | #5081 (with #5052) | #5052 | Change of the mean, #5081 (with #5052) to #5052 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| TLS | 32 MiB | not measured | not measured | 19.16 ± 0.12 | 19.06 ± 0.11 | -0.5% |
| TLS | 1 MiB | not measured | not measured | 0.947 ± 0.011 | 0.8861 ± 0.0093 | -6.4% |

## User and kernel CPU time per GET, ms (mean ± sample SD over repetitions, n=36); process lifetime means of the total

| Transport | Case | Arm | n | Total | User | Kernel | Process lifetimes | Sample SD of the process lifetime means of the total | Process lifetime means of the total, in order of measurement |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| TLS | whole-4mib | #5081 (with #5052) | 36 | 2.407 ± 0.020 | 1.131 ± 0.025 | 1.276 ± 0.028 | 12 | 0.018 | 2.397, 2.460, 2.410, 2.403, 2.407, 2.393, 2.410, 2.397, 2.390, 2.403, 2.417, 2.400 |
| TLS | whole-4mib | #5052 | 36 | 2.346 ± 0.037 | 1.077 ± 0.025 | 1.269 ± 0.044 | 12 | 0.037 | 2.323, 2.330, 2.423, 2.340, 2.340, 2.327, 2.340, 2.317, 2.333, 2.340, 2.313, 2.423 |
| TLS | whole-32mib | #5081 (with #5052) | 36 | 17.69 ± 0.14 | 7.09 ± 0.14 | 10.61 ± 0.21 | 12 | 0.140 | 17.693, 17.567, 17.560, 17.647, 17.740, 18.007, 17.807, 17.553, 17.640, 17.860, 17.573, 17.673 |
| TLS | whole-32mib | #5052 | 36 | 17.487 ± 0.092 | 6.89 ± 0.13 | 10.59 ± 0.16 | 12 | 0.087 | 17.567, 17.533, 17.393, 17.593, 17.487, 17.487, 17.533, 17.513, 17.440, 17.593, 17.373, 17.327 |
| TLS | range-32mib | #5081 (with #5052) | 36 | 19.16 ± 0.12 | 7.114 ± 0.062 | 12.04 ± 0.14 | 12 | 0.118 | 19.187, 19.463, 19.167, 19.183, 19.123, 19.110, 19.073, 19.053, 19.220, 19.207, 18.993, 19.100 |
| TLS | range-32mib | #5052 | 36 | 19.06 ± 0.11 | 6.976 ± 0.061 | 12.08 ± 0.12 | 12 | 0.105 | 19.020, 18.967, 18.983, 19.120, 18.997, 19.203, 19.007, 19.287, 19.157, 19.020, 18.960, 19.013 |
| TLS | range-1mib | #5081 (with #5052) | 36 | 0.947 ± 0.011 | 0.501 ± 0.019 | 0.446 ± 0.018 | 12 | 0.008 | 0.943, 0.943, 0.970, 0.947, 0.943, 0.943, 0.940, 0.947, 0.947, 0.947, 0.950, 0.943 |
| TLS | range-1mib | #5052 | 36 | 0.8861 ± 0.0093 | 0.458 ± 0.018 | 0.429 ± 0.017 | 12 | 0.006 | 0.883, 0.883, 0.887, 0.887, 0.883, 0.887, 0.887, 0.883, 0.903, 0.887, 0.883, 0.880 |

## Against the table in the commit message of #5081 (whole-blob GET, ms per GET, mean ± sample SD, n=15 each)

The commit message values are from repro/filereader-bypass-20261111T222404Z (main d14ff2fb, bypass 9ccd294c).

| Transport | Blob | Commit message, Before (main d14ff2fb) | Here, main f38cd9c0 | Commit message, Now | Here, #5081 (with main) | Here, #5081 (with #5052) | Commit message, change | Here, change of the mean, main to #5081 (with main) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |

## Distributions (two_groups of measure-filereader-bypass.py on registry total CPU time per repetition, and the same split on the process lifetime means when there are at least 6)

- bimodal candidate: tls whole-4mib, #5052: 30 values with mean 2.330 ms and 6 values with mean 2.423 ms per GET; follows process lifetimes
- process lifetime means, tls whole-4mib, #5081 (with #5052): largest gap 0.043 ms between 11 lifetimes (2.390 to 2.417 ms) and 1 lifetimes (2.460 to 2.460 ms); the gap is at least four times the sample SD on either side
- process lifetime means, tls whole-4mib, #5052: largest gap 0.083 ms between 10 lifetimes (2.313 to 2.340 ms) and 2 lifetimes (2.423 to 2.423 ms); the gap is at least four times the sample SD on either side
- process lifetime means, tls range-1mib, #5081 (with #5052): largest gap 0.020 ms between 11 lifetimes (0.940 to 0.950 ms) and 1 lifetimes (0.970 to 0.970 ms); the gap is at least four times the sample SD on either side
- process lifetime means, tls range-1mib, #5052: largest gap 0.017 ms between 11 lifetimes (0.880 to 0.887 ms) and 1 lifetimes (0.903 to 0.903 ms); the gap is at least four times the sample SD on either side

## Verification records

- tls-lifetimes-5081-vs-5052: 4 harness invocations, 96 process lifetimes, 288 repetitions, placement verified for all: True; NUMA node [0]; registry CPUs ['0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70']; client CPUs ['1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71']; network namespaces 4 distinct, none the host's (net:[4026531840]): True; interfaces ['lo']; netfilter rules ['empty(nft-list-ruleset)']; foreign load flagged in 0 repetitions, largest other CPU time 3.00 s; node busy before start at most 0.25%; go version go1.26.10 linux/arm64; base 910dd4f2 tree cf3fa2a7, bypass argument 0eb9d576 tree f7cc5450; measurement wall time 302 s
  - binary of script arm main: source head 910dd4f2, source tree cf3fa2a7, go1.26.10, sha256 388736837f723b5b
  - binary of script arm bypass: source head 910dd4f2, source tree f7cc5450, go1.26.10, sha256 15891e789d343cb0
