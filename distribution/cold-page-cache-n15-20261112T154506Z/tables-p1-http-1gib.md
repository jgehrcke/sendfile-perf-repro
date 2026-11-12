### Plain HTTP, 8 blobs of 1 GiB, one GET at a time (p1-http-1gib)

| Metric | main (n=15) | #5081 (run with main) (n=15) | #5081 (run with #5052) (n=15) | #5052 (n=15) | #5081 vs main | #5052 vs main | #5052 vs #5081 (same run) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wall time per repetition (s) | 3.352 ± 0.073 | 3.383 ± 0.015 | 3.406 ± 0.021 | 1.720 ± 0.128 | +0.9% | -48.7% | -49.5% |
| Registry total CPU time per repetition (s) | 2.750 ± 0.040 | 2.821 ± 0.021 | 2.875 ± 0.033 | 0.781 ± 0.013 | +2.6% | -71.6% | -72.8% |
| Registry user CPU time per repetition (s) | 0.485 ± 0.028 | 0.142 ± 0.012 | 0.163 ± 0.018 | 0.0060 ± 0.0051 | -70.7% | -98.8% | -96.3% |
| Registry kernel CPU time per repetition (s) | 2.265 ± 0.033 | 2.679 ± 0.019 | 2.712 ± 0.042 | 0.775 ± 0.013 | +18.3% | -65.8% | -71.4% |

- main: wall time, process lifetime means in order (s): [3.383, 3.41, 3.335, 3.299, 3.334]; registry total CPU time: [2.787, 2.767, 2.74, 2.693, 2.763]
- #5081 (run with main): wall time, process lifetime means in order (s): [3.38, 3.375, 3.378, 3.376, 3.406]; registry total CPU time: [2.82, 2.81, 2.813, 2.81, 2.853]
- #5081 (run with #5052): wall time, process lifetime means in order (s): [3.381, 3.421, 3.399, 3.4, 3.428]; registry total CPU time: [2.827, 2.89, 2.86, 2.887, 2.91]
- #5052: wall time, process lifetime means in order (s): [1.729, 1.704, 1.771, 1.699, 1.695]; registry total CPU time: [0.79, 0.773, 0.773, 0.787, 0.78]

#5052, every repetition (lifetime.repetition: wall time s, registry total CPU time s, foreign load flag):
  1.1: 1.577, 0.80, -; 1.2: 1.723, 0.78, -; 1.3: 1.887, 0.79, F; 2.1: 1.577, 0.78, -; 2.2: 1.649, 0.78, -; 2.3: 1.886, 0.76, -; 3.1: 1.810, 0.79, -; 3.2: 1.785, 0.76, -; 3.3: 1.717, 0.77, -; 4.1: 1.574, 0.79, F; 4.2: 1.740, 0.79, -; 4.3: 1.782, 0.78, -; 5.1: 1.576, 0.80, -; 5.2: 1.936, 0.78, -; 5.3: 1.574, 0.76, -

Foreign load flagged repetitions: 4 of 60. Cold state (harness, mincore): no page resident before, all pages resident after, in every repetition: True.
Placement per invocation (registry CPUs, client CPUs, interfaces, netfilter): [('0,2,4,6,8,10', '1,3,5,7,9,11', 'lo', 'empty(nft-list-ruleset)')] ; placement_verified in every process lifetime: True
