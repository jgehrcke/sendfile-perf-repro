Cold page cache: main, #5081 and #5052 (whole series), plain HTTP, 2026-11-12

Question (the author of #5081 and #5052): does the whole series (#5052, with sendfile(2)) lose against main when the
blob files are not in the page cache? Earlier cold measurements covered main and the bypass (#5081) only.
Report: review/cold-page-cache-full-series-20261112/report.md. Tables: tables-full.md (main result), tables-pilot.md (n=2).

Revisions (distribution/distribution; every binary built by the harness from the commit, source tree verified)
  main    f38cd9c02bf0c9a50d8a03adf7b57e2b3c92141b
  #5081   910dd4f20eacbe12c3a2eeec952f9a8b732bd6b9  fileReader bypass
  #5052   0eb9d5768544e74a8410d282d83146f326148de1  bypass plus sendfile(2) via ReadFrom forwarding
  The two gh-pr worktrees were not touched (the harness clones gh-pr/distribution, same object store).

Workload: cases cold-c1 and cold-c8 of repro/measure-filereader-bypass.py, plain HTTP/1.1 only (no TLS: time).
  One repetition = 8 whole-blob GETs, one for each of 8 distinct blobs of 1 GiB (8 GiB), cold-c1 one at a time,
  cold-c8 all 8 at once. Access logging disabled. Filesystem driver on ext4 / NVMe (SAMSUNG MZ1L21T9HCLS-00A07), readahead 256 KiB.
Cold page cache: before every repetition the load client calls fsync + posix_fadvise(POSIX_FADV_DONTNEED) on each blob file
  and mincore() must show 0 resident pages (otherwise the run stops); after the repetition mincore() must show all pages
  resident (the blobs were read). No root, no change to the host.
Metrics: registry total CPU time per repetition (user + kernel, /proc/<pid>/stat, 0.01 s resolution) and wall time per
  repetition (the client's wait for the complete bodies of the 8 GETs).
Design: the script compares two revisions, so the three are two comparisons that share #5081 (as in
  repro/pr5052-final-trees-20261112T042246Z): 5081-vs-5052 (script arm "main" = #5081, "bypass" = #5052) and
  main-vs-5081. Arms alternate per registry process lifetime. full: 2 process lifetimes x 3 repetitions = n=6 per arm and case.
  pilot: 1 lifetime x 2 repetitions = n=2.

Change of the harness during this work (repro/run-repro.sh; dated backup repro/run-repro.sh.bak-20261112T151435Z-before-cold-drop-retry)
  dropFromPageCache now repeats posix_fadvise + mincore until no page of the file is resident (one fsync before; poll every 10 ms,
  message every 10 s, fail after 180 s). Before, it failed at the first attempt. Reason, observed three times (directories
  aborted-*): after a repetition served with sendfile(2) (#5052), 19 to 34 pages of some 1 GiB files stay resident after
  posix_fadvise for seconds up to about a minute (waits recorded in the logs, "needed N drop attempts, T ms"), also after
  the registry and client processes of that repetition have exited. The same files were droppable at once after reads by
  read() (main, #5081) and in standalone tests with sendfile(2) over TCP loopback (not reproduced). The cause was not
  identified. The check that no page is resident before the measured requests is unchanged and strict; the waiting happens before
  the timed part of a repetition and is not part of any measured value. The consequence for the effort: a repetition of the
  #5052 arm takes about 1.5 minutes instead of 4 seconds, which is why n=6 and not n=15.
  Other change: none. measure-filereader-bypass.py and its watchdog (60 s without output) are unchanged.

Commands (cwd = project root)
  sh repro/cold-page-cache-full-series-20261112T151339Z/run.sh pilot > console/pilot.log        15:20:46 to 15:25:13 UTC
  COLD_LIFETIMES=2 COLD_REPETITIONS=3 sh repro/cold-page-cache-full-series-20261112T151339Z/run.sh full > console/full.log
  python3 -I -B summarize.py pilot > tables-pilot.md ; python3 -I -B summarize.py full > tables-full.md
  live-placement-check.py <console log> <json>: independent live check from the host (affinity of every thread, memory policy,
  network namespace, interfaces and nft ruleset inside each namespace), started with each phase.
Directories aborted-first-pilot-drop-failed, aborted-second-pilot-5s-retry, aborted-third-pilot-60s-watchdog: runs that
  stopped on the cold-state check or the watchdog (kept, not used). The first shows 1.579 s wall time for the first
  #5052 repetition, the same as the later runs.

Records and checks
  The console logs of pilot and full got a last line "exit=0" appended by hand so that live-placement-check.py (which waits for
  it) wrote its final record; nothing else in them was edited.
  Placement and environment, verified: per repetition by the script from the load client's records (CPU affinity of every
  thread, memory policy of every mapping, network namespace; placement_verified true in every process lifetime), and live from
  the host every 0.5 s (live-placement-check.full.json, 1388 sampling passes): registry on CPUs 0,2,...,70 and load client
  (repro-helper load-repeated) on CPUs 1,3,...,71, every sample with memory policy bind:0; two private network namespaces, each
  with interface lo only and an empty nft ruleset, not the host's net:[4026531840]. No other harness process was running before the start.
  Foreign load on the pinned CPUs flagged in 5 of 48 full repetitions (2 in cold-c1, 3 in cold-c8); included in the tables.
  Host: NVIDIA DGX GB200 Compute Tray, aarch64, Linux 6.14.0-1015-nvidia-64k, 64 KiB pages; Go 1.26.10; harness commit 4c78773 plus
  the uncommitted drop-retry change above (sha256 in every data.json).
  Time: pilot 4.5 min, full 15:25:19 to 15:36:38 UTC (11.3 min), plus three aborted starts (about 5 min) while diagnosing.
