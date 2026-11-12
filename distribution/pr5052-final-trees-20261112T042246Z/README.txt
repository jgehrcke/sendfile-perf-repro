Registry total CPU time per GET on the final trees of #5081 and #5052, and on upstream main, 2026-11-12

Purpose: numbers from the final commits for the description of pull request #5052.
Results: tables-n15.md (the requested run), tables-tls-lifetimes.md (addition, TLS only), tables-pilot.md (n=2, trend only).

Revisions (distribution/distribution; every binary built by the harness from the commit, source tree verified)
  main    f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b  tree 0208cb1a  upstream main
  #5081   910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9  tree cf3fa2a7  fileReader bypass, branch jp/filereader-bypass
  #5052   0eb9d5768544e74a8410d282d83146f326148de1  tree f7cc5450  bypass plus sendfile, branch jp/linux-sendfile-submit
  The two gh-pr worktrees were not touched: the harness clones gh-pr/distribution (same object store) into its work directory.

Metric: registry total CPU time per GET in ms = registry total CPU time of one repetition (user plus system, from
/proc/<pid>/stat of the registry process, resolution 0.01 s per repetition) divided by the GET requests of the repetition.
Warm page cache, filesystem driver, HTTP/1.1, 10 concurrent requests.

Workloads, each over plain HTTP and TLS (cases of repro/measure-filereader-bypass.py)
  whole-4mib    1000 GETs of one 4 MiB blob per repetition
  whole-32mib    500 GETs of one 32 MiB blob per repetition
  range-1mib    1000 GETs of 1 MiB ranges of a 512 MiB blob per repetition
  range-32mib   1000 GETs of 32 MiB ranges of a 512 MiB blob per repetition
  The range cases are the workloads of repro/netns-four-arms-20261111T193908Z (--chunk-mib 1 and 32, 1000 requests, concurrency 10).

Design
  Harness: the active repro/run-repro.sh, driven by the unmodified repro/measure-filereader-bypass.py. No new harness.
  The script compares two revisions, so the three revisions are two comparisons that share #5081:
    5081-vs-5052   --base #5081, --bypass #5052   (measured first)
    main-vs-5081   --base main,  --bypass #5081
  #5081 is therefore measured twice, once in each comparison; the tables show both ("with main", "with #5052").
  The two #5081 binaries have the same source tree and differ in the embedded VCS stamp only (go version -m:
  vcs.revision 910dd4f2 with vcs.modified=false, and vcs.revision f38cd9c0 with vcs.modified=true).
  Arm names: in every *-5081-vs-5052 directory the script's arm "main" is #5081 and its arm "bypass" is #5052. The
  report the script wrote there is named script-report.arm-main-is-5081.arm-bypass-is-5052.md for that reason.
  Within one harness invocation the two arms alternate per registry process lifetime (main, bypass, main, bypass, ...).
  n15: 3 process lifetimes x 5 repetitions = 15 repetitions per arm and workload.
  tls-lifetimes: 12 process lifetimes x 3 repetitions = 36 repetitions per arm and workload, TLS, #5081 against #5052.

Commands, in order (cwd = project root)
  sh repro/pr5052-final-trees-20261112T042246Z/run.sh pilot  > console/pilot.log          04:22:51 to 04:24:41 UTC
  sh repro/pr5052-final-trees-20261112T042246Z/run.sh n15    > console/n15.log            first start 04:25:25, stopped by me after
      about 25 s (see "Aborted start"); second start 04:26:22 to 04:32:39 UTC: this is the n15 result
  sh repro/pr5052-final-trees-20261112T042246Z/run-tls-lifetimes.sh > console/tls-lifetimes.log   04:33:46 to 04:38:49 UTC
  python3 -B live-placement-check.py <console log> <output json>   started together with n15 and tls-lifetimes
  python3 -B summarize.py n15 > tables-n15.md ; the same for tls-lifetimes and pilot
  The exact python commands are in run.sh and run-tls-lifetimes.sh; every data.json records its command line.

Placement and environment, as verified
  NUMA_PIN=same-socket: registry on CPUs 0,2,...,70, load client on CPUs 1,3,...,71, both with memory policy bind:0
  (NUMA node 0). LOOPBACK_NET=isolated: private network namespace per harness invocation.
  1. Per repetition, by the script, from the load client's records of registry and client: CPU affinity of every
     thread, memory policy of every mapping, network namespace. All 32 + 32 (pilot), 240 + 240 (n15) and 288
     (tls-lifetimes) repetitions matched; the script stops otherwise. Per invocation the harness recorded the namespace
     (not the host's net:[4026531840]), interfaces "lo" only, and an empty nft ruleset. Summary lines: end of each tables-*.md.
  2. Independently, live from the host (live-placement-check*.json): every 0.5 s the affinity of every thread, the
     policy of every mapping and the namespace of every registry and load client process; for each namespace
     "ip -o link show" and "nft list ruleset" run inside it. n15: 739 sampling passes; tls-lifetimes: 593. Every registry
     sample: CPUs 0,2,...,70, bind:0. Every load client sample (repro-helper load-repeated): CPUs 1,3,...,71, bind:0. Every
     namespace: only lo, empty ruleset, not the host's. Unpinned repro-helper processes were seen (7 samples in n15, 3 in
     tls-lifetimes): in tls-lifetimes they are the utility subcommands port-free and image, which run between measured
     runs; the n15 checker (live-placement-check.v1-used-for-n15.py) did not record the subcommand.
     The checker pins itself to NUMA node 1 (CPUs 72-143).
  Foreign load on the pinned CPUs: flagged in 0 repetitions; node 0 at most 0.89% busy before any n15 invocation.
  Host: NVIDIA DGX GB200 Compute Tray, Neoverse-V2, 2 sockets x 72 cores, aarch64, Linux 6.14.0-1015-nvidia-64k, 64 KiB
  pages, Ubuntu 24.04.3 LTS. Go 1.26.10, go build -mod=vendor -trimpath. Registry storage: ext4 on NVMe.
  Harness commit 4c787734 (repro/run-repro.sh), sha256 in data.json.

Findings (values: tables-n15.md, tables-tls-lifetimes.md)
  - #5081 to #5052, plain HTTP: -63.2% (4 MiB blob), -86.2% (32 MiB blob), -47.3% (1 MiB range), -88.1% (32 MiB range).
  - #5081 to #5052, TLS: -2.3% (4 MiB blob), -1.0% (32 MiB blob), -6.5% (1 MiB range), -0.6% (32 MiB range) at n=15;
    -2.6%, -1.2%, -6.4%, -0.5% at n=36 over 12 process lifetimes. At n=36 (mean ± sample SD, ms, #5081 then #5052):
      1 MiB range   0.947 ± 0.011, 0.8861 ± 0.0093   difference 0.061: larger than both SDs, lifetime mean ranges apart
      4 MiB blob    2.407 ± 0.020, 2.346 ± 0.037     difference 0.061: larger than both SDs; the two high lifetimes of
                                                     #5052 (2.423) lie inside the range of #5081
      32 MiB blob   17.69 ± 0.14, 17.487 ± 0.092     difference 0.21: larger than both SDs; lifetime mean ranges overlap
                                                     (17.55 to 18.01 against 17.33 to 17.59)
      32 MiB range  19.16 ± 0.12, 19.06 ± 0.11       difference 0.10: smaller than both SDs, not a difference
    Over TLS the registry user CPU time is lower with #5052 in all four workloads; the kernel CPU time is the same.
  - The #5081 table of its commit message reproduces: changes from main of -41.9%, -27.2%, -29.4%, -12.6% here against
    -41.8%, -27.3%, -29.3%, -13.0% there. Absolute values of the 32 MiB cells are 0.5% to 1.9% higher here.
  - Process lifetimes: the registry total CPU time per GET is stable within one registry process lifetime and differs
    between lifetimes of the same binary by more than the repetitions within a lifetime. The difference is in kernel
    CPU time and tracks wall time; user CPU time does not follow. For the 4 MiB blob over TLS the lifetime means are
    bimodal: #5052 has 10 lifetimes at 2.313 to 2.340 ms and 2 at 2.423 ms; #5081 has 11 at 2.390 to 2.417 ms and 1 at
    2.460 ms. For the 1 MiB range over TLS one lifetime of 12 is high in each arm. The cause is not identified.
    Consequence: with 3 process lifetimes (n15) the sample SD over the 15 repetitions understates the uncertainty of a
    mean; differences of about 1% between two arms are not established by n15 alone.
  - The pilot (one process lifetime per arm) showed #5052 above #5081 for the 32 MiB range over TLS (19.770 against
    19.415 ms, n=2 each); the n=15 and n=36 runs do not (19.149 against 19.268 ms; 19.06 against 19.16 ms).

Aborted start (aborted-first-n15-start/)
  The first n15 start ran with a live checker that was not pinned and could have run on the benchmark CPUs. I stopped
  it after one finished invocation, pinned the checker to NUMA node 1 and started again. Its partial output is kept and not used.

Files
  run.sh, run-tls-lifetimes.sh     the commands
  summarize.py                     tables from the data.json files (reuses pm and two_groups of the script)
  tables-*.md                      tables, distribution checks, verification summary
  <phase>-<comparison>/            output of measure-filereader-bypass.py: data.json (every repetition), logs/ (harness
                                   logs), sessions/ (raw harness result files), patches/, the script's own report
  live-placement-check*.py, *.json independent placement and namespace check
  console/                         console output per phase
