## Whole-blob GET: registry total CPU time per GET, ms (mean ± sample SD, n=15 per cell)

| Transport | Blob | main | #5081 (with main) | #5081 (with #5052) | #5052 | Change of the mean, #5081 (with #5052) to #5052 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Plain HTTP | 4 MiB | 1.983 ± 0.028 | 1.153 ± 0.012 | 1.176 ± 0.014 | 0.433 ± 0.013 | -63.2% |
| Plain HTTP | 32 MiB | 9.51 ± 0.12 | 6.920 ± 0.065 | 6.981 ± 0.026 | 0.960 ± 0.020 | -86.2% |
| TLS | 4 MiB | 3.393 ± 0.032 | 2.394 ± 0.012 | 2.405 ± 0.012 | 2.349 ± 0.019 | -2.3% |
| TLS | 32 MiB | 20.263 ± 0.079 | 17.700 ± 0.086 | 17.608 ± 0.066 | 17.429 ± 0.031 | -1.0% |

## Range GET (ranges of a 512 MiB blob): registry total CPU time per GET, ms (mean ± sample SD, n=15 per cell)

| Transport | Range | main | #5081 (with main) | #5081 (with #5052) | #5052 | Change of the mean, #5081 (with #5052) to #5052 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Plain HTTP | 32 MiB | 10.691 ± 0.056 | 8.620 ± 0.029 | 8.727 ± 0.029 | 1.035 ± 0.012 | -88.1% |
| Plain HTTP | 1 MiB | 1.468 ± 0.033 | 0.6040 ± 0.0063 | 0.6047 ± 0.0074 | 0.319 ± 0.011 | -47.3% |
| TLS | 32 MiB | 21.16 ± 0.11 | 19.31 ± 0.11 | 19.268 ± 0.033 | 19.149 ± 0.068 | -0.6% |
| TLS | 1 MiB | 1.865 ± 0.016 | 0.9467 ± 0.0082 | 0.949 ± 0.011 | 0.8867 ± 0.0090 | -6.5% |

## User and kernel CPU time per GET, ms (mean ± sample SD over repetitions, n=15); process lifetime means of the total

| Transport | Case | Arm | n | Total | User | Kernel | Process lifetimes | Sample SD of the process lifetime means of the total | Process lifetime means of the total, in order of measurement |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Plain HTTP | whole-4mib | main | 15 | 1.983 ± 0.028 | 1.033 ± 0.043 | 0.950 ± 0.030 | 3 | 0.011 | 1.984, 1.972, 1.994 |
| Plain HTTP | whole-4mib | #5081 (with main) | 15 | 1.153 ± 0.012 | 0.318 ± 0.027 | 0.835 ± 0.025 | 3 | 0.002 | 1.150, 1.154, 1.154 |
| Plain HTTP | whole-4mib | #5081 (with #5052) | 15 | 1.176 ± 0.014 | 0.309 ± 0.025 | 0.867 ± 0.026 | 3 | 0.013 | 1.190, 1.164, 1.174 |
| Plain HTTP | whole-4mib | #5052 | 15 | 0.433 ± 0.013 | 0.214 ± 0.017 | 0.219 ± 0.018 | 3 | 0.012 | 0.432, 0.446, 0.422 |
| Plain HTTP | whole-32mib | main | 15 | 9.51 ± 0.12 | 2.901 ± 0.078 | 6.608 ± 0.086 | 3 | 0.141 | 9.540, 9.356, 9.632 |
| Plain HTTP | whole-32mib | #5081 (with main) | 15 | 6.920 ± 0.065 | 0.764 ± 0.042 | 6.156 ± 0.061 | 3 | 0.070 | 7.000, 6.872, 6.888 |
| Plain HTTP | whole-32mib | #5081 (with #5052) | 15 | 6.981 ± 0.026 | 0.784 ± 0.041 | 6.197 ± 0.032 | 3 | 0.010 | 6.992, 6.972, 6.980 |
| Plain HTTP | whole-32mib | #5052 | 15 | 0.960 ± 0.020 | 0.288 ± 0.024 | 0.672 ± 0.029 | 3 | 0.014 | 0.972, 0.964, 0.944 |
| Plain HTTP | range-32mib | main | 15 | 10.691 ± 0.056 | 3.121 ± 0.078 | 7.571 ± 0.049 | 3 | 0.050 | 10.734, 10.704, 10.636 |
| Plain HTTP | range-32mib | #5081 (with main) | 15 | 8.620 ± 0.029 | 0.832 ± 0.025 | 7.788 ± 0.038 | 3 | 0.031 | 8.654, 8.614, 8.592 |
| Plain HTTP | range-32mib | #5081 (with #5052) | 15 | 8.727 ± 0.029 | 0.833 ± 0.020 | 7.894 ± 0.035 | 3 | 0.025 | 8.742, 8.698, 8.742 |
| Plain HTTP | range-32mib | #5052 | 15 | 1.035 ± 0.012 | 0.346 ± 0.020 | 0.689 ± 0.023 | 3 | 0.010 | 1.024, 1.042, 1.040 |
| Plain HTTP | range-1mib | main | 15 | 1.468 ± 0.033 | 0.789 ± 0.027 | 0.679 ± 0.024 | 3 | 0.005 | 1.470, 1.462, 1.472 |
| Plain HTTP | range-1mib | #5081 (with main) | 15 | 0.6040 ± 0.0063 | 0.280 ± 0.016 | 0.324 ± 0.016 | 3 | 0.002 | 0.602, 0.606, 0.604 |
| Plain HTTP | range-1mib | #5081 (with #5052) | 15 | 0.6047 ± 0.0074 | 0.291 ± 0.027 | 0.314 ± 0.024 | 3 | 0.003 | 0.602, 0.604, 0.608 |
| Plain HTTP | range-1mib | #5052 | 15 | 0.319 ± 0.011 | 0.211 ± 0.014 | 0.108 ± 0.012 | 3 | 0.002 | 0.316, 0.320, 0.320 |
| TLS | whole-4mib | main | 15 | 3.393 ± 0.032 | 1.940 ± 0.055 | 1.453 ± 0.046 | 3 | 0.011 | 3.406, 3.384, 3.390 |
| TLS | whole-4mib | #5081 (with main) | 15 | 2.394 ± 0.012 | 1.131 ± 0.034 | 1.263 ± 0.030 | 3 | 0.009 | 2.392, 2.386, 2.404 |
| TLS | whole-4mib | #5081 (with #5052) | 15 | 2.405 ± 0.012 | 1.133 ± 0.020 | 1.272 ± 0.027 | 3 | 0.012 | 2.402, 2.394, 2.418 |
| TLS | whole-4mib | #5052 | 15 | 2.349 ± 0.019 | 1.099 ± 0.026 | 1.249 ± 0.029 | 3 | 0.020 | 2.326, 2.356, 2.364 |
| TLS | whole-32mib | main | 15 | 20.263 ± 0.079 | 10.008 ± 0.099 | 10.25 ± 0.12 | 3 | 0.084 | 20.180, 20.348, 20.260 |
| TLS | whole-32mib | #5081 (with main) | 15 | 17.700 ± 0.086 | 7.08 ± 0.15 | 10.62 ± 0.17 | 3 | 0.093 | 17.624, 17.672, 17.804 |
| TLS | whole-32mib | #5081 (with #5052) | 15 | 17.608 ± 0.066 | 7.12 ± 0.10 | 10.489 ± 0.090 | 3 | 0.062 | 17.668, 17.612, 17.544 |
| TLS | whole-32mib | #5052 | 15 | 17.429 ± 0.031 | 6.97 ± 0.16 | 10.46 ± 0.17 | 3 | 0.009 | 17.424, 17.440, 17.424 |
| TLS | range-32mib | main | 15 | 21.16 ± 0.11 | 10.06 ± 0.10 | 11.10 ± 0.15 | 3 | 0.132 | 21.314, 21.102, 21.072 |
| TLS | range-32mib | #5081 (with main) | 15 | 19.31 ± 0.11 | 7.133 ± 0.074 | 12.18 ± 0.14 | 3 | 0.122 | 19.186, 19.430, 19.324 |
| TLS | range-32mib | #5081 (with #5052) | 15 | 19.268 ± 0.033 | 7.132 ± 0.090 | 12.136 ± 0.099 | 3 | 0.022 | 19.248, 19.292, 19.264 |
| TLS | range-32mib | #5052 | 15 | 19.149 ± 0.068 | 6.986 ± 0.049 | 12.163 ± 0.099 | 3 | 0.071 | 19.068, 19.184, 19.196 |
| TLS | range-1mib | main | 15 | 1.865 ± 0.016 | 1.029 ± 0.034 | 0.836 ± 0.041 | 3 | 0.002 | 1.868, 1.864, 1.864 |
| TLS | range-1mib | #5081 (with main) | 15 | 0.9467 ± 0.0082 | 0.499 ± 0.017 | 0.447 ± 0.017 | 3 | 0.001 | 0.948, 0.946, 0.946 |
| TLS | range-1mib | #5081 (with #5052) | 15 | 0.949 ± 0.011 | 0.497 ± 0.019 | 0.451 ± 0.018 | 3 | 0.003 | 0.948, 0.952, 0.946 |
| TLS | range-1mib | #5052 | 15 | 0.8867 ± 0.0090 | 0.459 ± 0.016 | 0.428 ± 0.020 | 3 | 0.003 | 0.886, 0.884, 0.890 |

## Against the table in the commit message of #5081 (whole-blob GET, ms per GET, mean ± sample SD, n=15 each)

The commit message values are from repro/filereader-bypass-20261111T222404Z (main d14ff2fb, bypass 9ccd294c).

| Transport | Blob | Commit message, Before (main d14ff2fb) | Here, main f38cd9c0 | Commit message, Now | Here, #5081 (with main) | Here, #5081 (with #5052) | Commit message, change | Here, change of the mean, main to #5081 (with main) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Plain HTTP | 4 MiB | 1.994 ± 0.026 | 1.983 ± 0.028 | 1.160 ± 0.009 | 1.153 ± 0.012 | 1.176 ± 0.014 | -41.8% | -41.9% |
| Plain HTTP | 32 MiB | 9.423 ± 0.061 | 9.51 ± 0.12 | 6.851 ± 0.021 | 6.920 ± 0.065 | 6.981 ± 0.026 | -27.3% | -27.2% |
| TLS | 4 MiB | 3.401 ± 0.027 | 3.393 ± 0.032 | 2.404 ± 0.018 | 2.394 ± 0.012 | 2.405 ± 0.012 | -29.3% | -29.4% |
| TLS | 32 MiB | 20.159 ± 0.063 | 20.263 ± 0.079 | 17.528 ± 0.113 | 17.700 ± 0.086 | 17.608 ± 0.066 | -13.0% | -12.6% |

## Distributions (two_groups of measure-filereader-bypass.py on registry total CPU time per repetition, and the same split on the process lifetime means when there are at least 6)

- bimodal candidate: tls range-32mib, main: 10 values with mean 21.087 ms and 5 values with mean 21.314 ms per GET; follows process lifetimes

## Verification records

- n15-5081-vs-5052: 8 harness invocations, 48 process lifetimes, 240 repetitions, placement verified for all: True; NUMA node [0]; registry CPUs ['0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70']; client CPUs ['1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71']; network namespaces 3 distinct, none the host's (net:[4026531840]): True; interfaces ['lo']; netfilter rules ['empty(nft-list-ruleset)']; foreign load flagged in 0 repetitions, largest other CPU time 1.38 s; node busy before start at most 0.89%; go version go1.26.10 linux/arm64; base 910dd4f2 tree cf3fa2a7, bypass argument 0eb9d576 tree f7cc5450; measurement wall time 176 s
  - binary of script arm main: source head 910dd4f2, source tree cf3fa2a7, go1.26.10, sha256 388736837f723b5b
  - binary of script arm bypass: source head 910dd4f2, source tree f7cc5450, go1.26.10, sha256 15891e789d343cb0
- n15-main-vs-5081: 8 harness invocations, 48 process lifetimes, 240 repetitions, placement verified for all: True; NUMA node [0]; registry CPUs ['0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70']; client CPUs ['1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71']; network namespaces 2 distinct, none the host's (net:[4026531840]): True; interfaces ['lo']; netfilter rules ['empty(nft-list-ruleset)']; foreign load flagged in 0 repetitions, largest other CPU time 3.03 s; node busy before start at most 0.78%; go version go1.26.10 linux/arm64; base f38cd9c0 tree 0208cb1a, bypass argument 910dd4f2 tree cf3fa2a7; measurement wall time 201 s
  - binary of script arm main: source head f38cd9c0, source tree 0208cb1a, go1.26.10, sha256 d26e39808482759c
  - binary of script arm bypass: source head f38cd9c0, source tree cf3fa2a7, go1.26.10, sha256 91ac0cfa9327044d
