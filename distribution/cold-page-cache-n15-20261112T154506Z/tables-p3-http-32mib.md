### Plain HTTP, 128 blobs of 32 MiB, one GET at a time (p3-http-32mib)

| Metric | main (n=12) | #5081 (run with main) (n=12) | #5081 (run with #5052) (n=12) | #5052 (n=12) | #5081 vs main | #5052 vs main | #5052 vs #5081 (same run) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wall time per repetition (s) | 1.761 ± 0.047 | 1.752 ± 0.015 | 1.770 ± 0.040 | 1.022 ± 0.123 | -0.5% | -41.9% | -42.3% |
| Registry total CPU time per repetition (s) | 1.593 ± 0.019 | 1.491 ± 0.021 | 1.495 ± 0.020 | 0.427 ± 0.015 | -6.4% | -73.2% | -71.4% |
| Registry user CPU time per repetition (s) | 0.414 ± 0.026 | 0.1117 ± 0.0072 | 0.109 ± 0.012 | 0.037 ± 0.014 | -73.0% | -90.9% | -65.6% |
| Registry kernel CPU time per repetition (s) | 1.178 ± 0.033 | 1.379 ± 0.019 | 1.386 ± 0.021 | 0.3900 ± 0.0085 | +17.0% | -66.9% | -71.9% |

- main: wall time, process lifetime means in order (s): [1.754, 1.749, 1.775, 1.766]; registry total CPU time: [1.583, 1.58, 1.603, 1.603]
- #5081 (run with main): wall time, process lifetime means in order (s): [1.749, 1.737, 1.762, 1.759]; registry total CPU time: [1.477, 1.483, 1.507, 1.497]
- #5081 (run with #5052): wall time, process lifetime means in order (s): [1.814, 1.757, 1.747, 1.763]; registry total CPU time: [1.513, 1.493, 1.47, 1.503]
- #5052: wall time, process lifetime means in order (s): [0.92, 1.136, 1.013, 1.019]; registry total CPU time: [0.437, 0.42, 0.423, 0.43]

#5052, every repetition (lifetime.repetition: wall time s, registry total CPU time s, foreign load flag):
  1.1: 0.889, 0.45, -; 1.2: 0.992, 0.44, -; 1.3: 0.880, 0.42, -; 2.1: 1.056, 0.43, -; 2.2: 1.221, 0.43, -; 2.3: 1.132, 0.40, -; 3.1: 0.883, 0.44, -; 3.2: 1.156, 0.43, -; 3.3: 1.000, 0.40, -; 4.1: 1.013, 0.44, -; 4.2: 0.884, 0.43, F; 4.3: 1.161, 0.42, -

Foreign load flagged repetitions: 3 of 48. Cold state (harness, mincore): no page resident before, all pages resident after, in every repetition: True.
Placement per invocation (registry CPUs, client CPUs, interfaces, netfilter): [('0,2,4,6,8,10', '1,3,5,7,9,11', 'lo', 'empty(nft-list-ruleset)')] ; placement_verified in every process lifetime: True
