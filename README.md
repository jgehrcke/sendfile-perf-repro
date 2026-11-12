# sendfile-perf-repro

I am making container registries serve blobs with `sendfile(2)`. Here are the benchmark harnesses and the raw results behind the numbers I quote in my pull requests.

- `distribution/`: [distribution/distribution](https://github.com/distribution/distribution), pull requests #5081 and #5052.
