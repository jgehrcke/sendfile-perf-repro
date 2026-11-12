
### Plain HTTP, 8 blobs of 1 GiB, one GET at a time (full)

| Metric | main (n=6) | #5081, run with main (n=6) | #5081, run with #5052 (n=6) | #5052 (n=6) | #5081 vs main | #5052 vs main | #5052 vs #5081 (same run) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wall time per repetition (s) | 3.370 ± 0.060 | 3.396 ± 0.013 | 3.401 ± 0.017 | 1.766 ± 0.105 | +0.8% | -47.6% | -48.1% |
| Registry total CPU time per repetition (s) | 2.770 ± 0.030 | 2.835 ± 0.026 | 2.852 ± 0.025 | 0.785 ± 0.010 | +2.3% | -71.7% | -72.5% |
| Registry user CPU time per repetition (s) | 0.505 ± 0.023 | 0.1383 ± 0.0098 | 0.145 ± 0.014 | 0.0083 ± 0.0041 | -72.6% | -98.3% | -94.3% |
| Registry kernel CPU time per repetition (s) | 2.265 ± 0.029 | 2.697 ± 0.027 | 2.707 ± 0.027 | 0.777 ± 0.010 | +19.1% | -65.7% | -71.3% |

Process lifetime means of wall time (s): main: [3.382, 3.359]; #5081, run with main: [3.405, 3.388]; #5081, run with #5052: [3.398, 3.404]; #5052: [1.751, 1.782]
Process lifetime means of registry total CPU time (s): main: [2.783, 2.757]; #5081, run with main: [2.857, 2.813]; #5081, run with #5052: [2.85, 2.853]; #5052: [0.783, 0.787]
All wall times (s): main: [3.46, 3.355, 3.331, 3.432, 3.327, 3.317]; #5081, run with main: [3.409, 3.4, 3.405, 3.374, 3.389, 3.402]; #5081, run with #5052: [3.389, 3.413, 3.391, 3.429, 3.397, 3.386]; #5052: [1.574, 1.78, 1.898, 1.781, 1.785, 1.78]
Foreign load flagged repetitions: 2. Every repetition: no page of the 8 blob files was resident before and all pages were after (mincore, checked by the harness): True.

### Plain HTTP, 8 blobs of 1 GiB, 8 GETs at once (full)

| Metric | main (n=6) | #5081, run with main (n=6) | #5081, run with #5052 (n=6) | #5052 (n=6) | #5081 vs main | #5052 vs main | #5052 vs #5081 (same run) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wall time per repetition (s) | 2.464 ± 0.252 | 2.5646 ± 0.0010 | 2.5647 ± 0.0006 | 2.5646 ± 0.0003 | +4.1% | +4.1% | -0.0% |
| Registry total CPU time per repetition (s) | 2.803 ± 0.015 | 2.933 ± 0.018 | 2.923 ± 0.015 | 0.7417 ± 0.0075 | +4.6% | -73.5% | -74.6% |
| Registry user CPU time per repetition (s) | 0.557 ± 0.084 | 0.213 ± 0.018 | 0.203 ± 0.021 | 0.0017 ± 0.0041 | -61.7% | -99.7% | -99.2% |
| Registry kernel CPU time per repetition (s) | 2.247 ± 0.076 | 2.720 ± 0.022 | 2.720 ± 0.017 | 0.7400 ± 0.0063 | +21.1% | -67.1% | -72.8% |

Process lifetime means of wall time (s): main: [2.363, 2.566]; #5081, run with main: [2.565, 2.564]; #5081, run with #5052: [2.565, 2.564]; #5052: [2.565, 2.565]
Process lifetime means of registry total CPU time (s): main: [2.8, 2.807]; #5081, run with main: [2.93, 2.937]; #5081, run with #5052: [2.92, 2.927]; #5052: [0.743, 0.74]
All wall times (s): main: [1.95, 2.565, 2.573, 2.566, 2.565, 2.566]; #5081, run with main: [2.566, 2.564, 2.565, 2.565, 2.564, 2.564]; #5081, run with #5052: [2.565, 2.564, 2.565, 2.564, 2.564, 2.565]; #5052: [2.564, 2.565, 2.564, 2.565, 2.565, 2.564]
Foreign load flagged repetitions: 3. Every repetition: no page of the 8 blob files was resident before and all pages were after (mincore, checked by the harness): True.

Placement and namespace per invocation (registry CPUs, client CPUs, interfaces, netfilter): [('0,2,4,6,8,10', '1,3,5,7,9,11', 'lo', 'empty(nft-list-ruleset)')]
placement_verified in every process lifetime: True
