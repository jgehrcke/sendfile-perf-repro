### TLS, 8 blobs of 1 GiB, one GET at a time (p2-tls-1gib)

| Metric | main (n=15) | #5081 (run with main) (n=15) | #5081 (run with #5052) (n=15) | #5052 (n=15) | #5081 vs main | #5052 vs main | #5052 vs #5081 (same run) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wall time per repetition (s) | 5.937 ± 0.057 | 5.597 ± 0.070 | 5.598 ± 0.049 | 5.516 ± 0.064 | -5.7% | -7.1% | -1.5% |
| Registry total CPU time per repetition (s) | 5.278 ± 0.044 | 5.595 ± 0.050 | 5.607 ± 0.050 | 5.521 ± 0.069 | +6.0% | +4.6% | -1.5% |
| Registry user CPU time per repetition (s) | 2.121 ± 0.050 | 1.751 ± 0.041 | 1.760 ± 0.038 | 1.709 ± 0.042 | -17.5% | -19.4% | -2.9% |
| Registry kernel CPU time per repetition (s) | 3.157 ± 0.051 | 3.844 ± 0.060 | 3.847 ± 0.069 | 3.812 ± 0.102 | +21.8% | +20.8% | -0.9% |

- main: wall time, process lifetime means in order (s): [5.938, 5.975, 5.934, 5.898, 5.938]; registry total CPU time: [5.267, 5.327, 5.27, 5.243, 5.283]
- #5081 (run with main): wall time, process lifetime means in order (s): [5.699, 5.543, 5.565, 5.628, 5.551]; registry total CPU time: [5.663, 5.547, 5.573, 5.633, 5.557]
- #5081 (run with #5052): wall time, process lifetime means in order (s): [5.639, 5.544, 5.588, 5.662, 5.557]; registry total CPU time: [5.65, 5.553, 5.597, 5.67, 5.563]
- #5052: wall time, process lifetime means in order (s): [5.452, 5.588, 5.449, 5.532, 5.561]; registry total CPU time: [5.45, 5.603, 5.453, 5.537, 5.563]

#5052, every repetition (lifetime.repetition: wall time s, registry total CPU time s, foreign load flag):
  1.1: 5.468, 5.47, -; 1.2: 5.448, 5.45, -; 1.3: 5.439, 5.43, -; 2.1: 5.599, 5.62, -; 2.2: 5.576, 5.58, -; 2.3: 5.588, 5.61, -; 3.1: 5.470, 5.48, -; 3.2: 5.400, 5.40, -; 3.3: 5.477, 5.48, -; 4.1: 5.513, 5.52, -; 4.2: 5.535, 5.53, -; 4.3: 5.547, 5.56, -; 5.1: 5.617, 5.62, -; 5.2: 5.519, 5.52, -; 5.3: 5.547, 5.55, -

Foreign load flagged repetitions: 1 of 60. Cold state (harness, mincore): no page resident before, all pages resident after, in every repetition: True.
Placement per invocation (registry CPUs, client CPUs, interfaces, netfilter): [('0,2,4,6,8,10', '1,3,5,7,9,11', 'lo', 'empty(nft-list-ruleset)')] ; placement_verified in every process lifetime: True
