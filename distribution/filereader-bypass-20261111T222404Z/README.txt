fileReader bypass against main and against smaller fileReader buffer caps
Measured 2026-11-11, 22:24:04 to 22:52:21 UTC (1697 s, 52 harness invocations).

Command: repro/measure-filereader-bypass.py (no options). Script and harness at commit 4c78773 of this
repository (data.json: environment.script_sha256, environment.harness_sha256).
report.md is the generated report. data.json holds every repetition. sessions/ holds the harness result
files, logs/ the harness logs, patches/ the patch of every arm.

Pilot before this run: repro/filereader-bypass-20261111T221808Z-quick (--quick, n=2 per arm, made with the
script before it was committed; trend only, not for claims).

Notes from reading the data, not part of the generated report:

1. Flagged repetitions. 7 of 1020 repetitions exceed the foreign load rule (more than 0.3 s and more than 20%
   of the busy time of the pinned CPUs is neither registry nor client CPU time). All 7 are in cold page cache
   cases; none of the 720 warm repetitions is flagged. What consumed that CPU time was not identified (other
   processes or kernel threads working for the reads). The idle host showed 0.07 to 0.55 busy CPU-seconds per
   second on NUMA node 0 right after the run (25 windows of 1 s). The flagged values, against the unflagged
   repetitions of the same arm (mean ± sample SD):
     cold-c1-http, 1 MiB buffer: wall time 2.591 s and 2.622 s, against 2.602 ± 0.017 s (n=13)
     cold-c1-tls, 32 KiB buffer: wall time 5.571 s, against 5.497 ± 0.065 s (n=14)
     cold-c1-tls, 256 KiB buffer: wall time 5.311 s, against 5.280 ± 0.030 s (n=14)
     cold-c8-http, 256 KiB buffer: registry total CPU time 2.97 s and 2.99 s, against 2.923 ± 0.018 s (n=13)
     cold-c8-http, main: wall time 1.917 s, against 2.566 ± 0.002 s (n=14); see note 2
   They are included in the tables of report.md.

2. cold-c8-http, main, first repetition of the first process lifetime: wall time 1.917 s, the other 14
   repetitions 2.56 to 2.57 s. The pilot shows the same for the same repetition (1.916 s). In both runs the
   case before it read the blobs slowly (cold-c1-tls). mincore() showed no page of the blob files in the page
   cache before that repetition. The cause was not investigated.

3. Wall time at concurrency 8 with a cold page cache is 2.564 to 2.570 s (means) for every arm and both
   transports, with sample SDs of 0.001 to 0.012 s. That is 3.12 GiB/s. A limit of the storage device is the
   likely reason; this was not verified.

4. The pilot (n=2) showed 3.950 s wall time for the bypass in cold-c1-http against 3.390 s for main. At n=15
   the values are 3.372 ± 0.021 s (bypass) and 3.327 ± 0.044 s (main). The pilot invocation was the first
   after the blobs had been generated and uploaded.

5. Distributions: one bimodal candidate, whole-4mib-tls with the 256 KiB buffer: one process lifetime of five
   repetitions has a mean of registry total CPU time of 2.758 s, the other two 2.687 s.
