# distribution: registry CPU time per blob GET

Harness and raw results behind the numbers in [distribution/distribution #5081](https://github.com/distribution/distribution/pull/5081) and [#5052](https://github.com/distribution/distribution/pull/5052). I publish them so that others can check.

Fair warning: the harness is about 3,400 lines of shell with a Go client embedded. Not pretty, but it is exactly what produced the numbers, so I publish it as is.

## Get the three revisions

The wrappers expect main `f38cd9c0`, #5081 `910dd4f2` and #5052 `0eb9d576` in `upstream/`:

    git clone https://github.com/distribution/distribution upstream
    git -C upstream fetch origin pull/5081/head:pr-5081 pull/5052/head:pr-5052

## Run

Warm page cache, n=15 per revision, about 7 minutes (`pilot`: n=2, 2 minutes):

    sh warm/run.sh n15
    python3 -B warm/summarize.py n15

Cold page cache, 1 GiB blobs, plain HTTP, n=15, about 10 minutes (with `1 2`: n=2):

    sh cold/run.sh http-1gib cold-c1 http 5 3
    python3 -B cold/summarize.py http-1gib cold-c1-http "Plain HTTP, 1 GiB blobs"

The first run also builds registries and generates blobs.

## Machine

- At least two NUMA nodes. The method uses one, but the script insists.
- No root: unprivileged user namespaces, `numactl`, `nft`, `go`, ...
- Both are checked, with a clear error. Not checked up front: SMT siblings, memory (cold: 8 GiB of page cache), disk (about 18 GiB).
- I used 2 sockets x 72 cores, no SMT: registry on CPUs 0, 2, ..., 70, client on 1, 3, ..., 71 of NUMA node 0, memory bound to it.

## Published numbers

- #5052, warm: `pr5052-final-trees-20261112T042246Z/tables-n15.md`
- #5052, cold: `cold-page-cache-n15-20261112T154506Z/tables-p1-http-1gib.md`, `tables-p2-tls-1gib.md`
- #5081: `filereader-bypass-20261111T222404Z/report.md`

## Method

- Registry and client pinned to disjoint CPUs of one NUMA node.
- Private network namespace without netfilter rules.
- Registry total CPU time from `/proc/<pid>/stat`.

Limits: one machine, linux/arm64, 64 KiB pages, local NVMe drive.

<details>
<summary>Provenance of the result directories</summary>

Each `data.json` records the sha256 of `run-repro.sh` and of `measure-filereader-bypass.py`:

- `cold-page-cache-n15-20261112T154506Z`: `e15b3cb4832e`, `ae95335dc468`. These are the files here.
- `cold-page-cache-full-series-20261112T151339Z` (earlier cold run, n=6): `e15b3cb4832e`, `49d99dae2afc`.
- `pr5052-final-trees-20261112T042246Z` and `filereader-bypass-20261111T222404Z`: `1c0519662952`, `49d99dae2afc`.

The earlier versions differ only in the cold cases.

The result directories are copies from my working tree. I replaced its path with `/path/to/sendfile-perf-repro/distribution` and removed one remark about my setup from six comment lines. I removed the 82 `sessions/*/measured.patch` files: each was byte-identical to a file in `patches/` of the same run. The notes and wrappers in there still name a `repro/` level and files that are not here.

</details>
