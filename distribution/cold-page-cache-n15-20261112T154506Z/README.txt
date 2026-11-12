Cold page cache at n=15: main, #5081, #5052; one GET at a time; 2026-11-12

Follow-up of repro/cold-page-cache-full-series-20261112T151339Z (n=6, kept unchanged). Same method, harness and revisions.
Report: review/cold-page-cache-full-series-20261112/report-n15.md. Tables: tables-*.md.

Revisions: main f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b, #5081 910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9,
  #5052 0eb9d5768544e74a8410d282d83146f326148de1 (built by the harness from the commits, source tree verified; gh-pr worktrees untouched).
Cold page cache and metrics: as in the n=6 README (fsync + posix_fadvise(DONTNEED) repeated until mincore shows 0 resident pages,
  harness stops otherwise; all pages resident after each repetition; registry total CPU time from /proc/<pid>/stat, 0.01 s; wall
  time = client waits for the complete bodies of the repetition's GETs). Placement NUMA_PIN=same-socket, LOOPBACK_NET=isolated.
Design: run.sh <phase> <cases> <transports> <lifetimes> <repetitions>: two comparisons of the unmodified
  measure-filereader-bypass.py that share #5081 (5081-vs-5052: script arm "main" = #5081, "bypass" = #5052; then main-vs-5081).
  Arms alternate per registry process lifetime. Commands (driver.sh runs the first two in sequence; the third was started by hand):
    sh run.sh p1-http-1gib      cold-c1    http 5 3   priority 1: plain HTTP, 8 blobs of 1 GiB, n=15 per arm   15:46:10 to 15:56:11 UTC
    sh run.sh p2-tls-1gib       cold-c1    tls  5 3   priority 2: TLS, same workload, n=15 per arm             15:56:12 to 16:02:18 UTC
    sh run.sh p3-http-32mib     cold32-c1  http 4 3   priority 3: plain HTTP, 128 blobs of 32 MiB (4 GiB) per repetition, one at a time, n=12 per arm
  summarize.py <phase> <case key> "<title>" > tables-<phase>.md
Changes to the harness: measure-filereader-bypass.py got one case, cold32-c1 (128 blobs of 32 MiB, one at a time, cold); dated
  backup repro/measure-filereader-bypass.py.bak-*-before-cold32. Nothing else; run-repro.sh as in the n=6 directory (retry of the cache drop).
Directories:
  aborted-start-port-in-use: the first start; the seeding registry of p1 failed with "address already in use" inside the private
    network namespace, the driver went on with p2 by mistake and I stopped it; cause of the port clash not found (no process was
    running before the start). Not used.
  p3-pilot-http-32mib-*: a pilot of p3 (1 lifetime x 2 repetitions) that I stopped during its first drop waits to save time. Not used.
Drop waits ("needed N drop attempts" in logs/*.log): plain HTTP #5052 repetitions wait for pages to become droppable as before;
  TLS: none in 60 repetitions per comparison (grep -c needed = 0).
Console logs got a last line "exit=..." (by the driver, or by hand for the stopped pilot) so that live-placement-check.py finishes.
Placement and namespace verified, per repetition by the script and live from the host (live-placement-check.p*.json): registry CPUs
  0,2,...,70, client CPUs 1,3,...,71, memory policy bind:0, private namespace with lo only and an empty nft ruleset.
