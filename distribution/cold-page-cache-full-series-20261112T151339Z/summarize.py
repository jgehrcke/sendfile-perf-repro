#!/usr/bin/env python3
"""Tables for the cold page cache comparison: python3 -I -B summarize.py <phase: pilot|full>
Reads <phase>-main-vs-5081/data.json and <phase>-5081-vs-5052/data.json (in the script's arm names the latter has
"main" = #5081 and "bypass" = #5052). Prints Markdown. mean ± sample SD (n-1) over repetitions."""
import json
import statistics as st
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
phase = sys.argv[1]
A = json.load(open(here / f"{phase}-main-vs-5081/data.json"))
B = json.load(open(here / f"{phase}-5081-vs-5052/data.json"))


def reps(data, case, arm):
    out = []
    for inv in data["cases"][case][arm]:
        out += inv["repetitions"]
    return out


def lifetimes(data, case, arm, key):
    return [round(st.mean(r[key] for r in inv["repetitions"]), 3) for inv in data["cases"][case][arm]]


cols = [("main", A, "main"), ("#5081, run with main", A, "bypass"), ("#5081, run with #5052", B, "main"), ("#5052", B, "bypass")]
metrics = [("Wall time per repetition (s)", "wall_time_s"), ("Registry total CPU time per repetition (s)", "registry_cpu_time_total_s"),
           ("Registry user CPU time per repetition (s)", "registry_cpu_time_user_s"), ("Registry kernel CPU time per repetition (s)", "registry_cpu_time_kernel_s")]


def fmt(x):
    m, s = st.mean(x), (st.stdev(x) if len(x) > 1 else float("nan"))
    return f"{m:.3f} ± {s:.3f}" if s >= 0.01 else f"{m:.4f} ± {s:.4f}"


def ch(x, y):
    return f"{(st.mean(x) / st.mean(y) - 1) * 100:+.1f}%"


for case, title in [("cold-c1-http", "Plain HTTP, 8 blobs of 1 GiB, one GET at a time"), ("cold-c8-http", "Plain HTTP, 8 blobs of 1 GiB, 8 GETs at once")]:
    if case not in A["cases"]:
        continue
    n = {c[0]: len(reps(c[1], case, c[2])) for c in cols}
    print(f"\n### {title} ({phase})\n")
    print("| Metric | " + " | ".join(f"{c[0]} (n={n[c[0]]})" for c in cols) + " | #5081 vs main | #5052 vs main | #5052 vs #5081 (same run) |")
    print("| --- | " + " | ".join("---:" for _ in cols) + " | ---: | ---: | ---: |")
    for label, key in metrics:
        vals = {c[0]: [r[key] for r in reps(c[1], case, c[2])] for c in cols}
        print(f"| {label} | " + " | ".join(fmt(vals[c[0]]) for c in cols)
              + f" | {ch(vals['#5081, run with main'], vals['main'])} | {ch(vals['#5052'], vals['main'])} | {ch(vals['#5052'], vals['#5081, run with #5052'])} |")
    print("\nProcess lifetime means of wall time (s): " + "; ".join(f"{c[0]}: {lifetimes(c[1], case, c[2], 'wall_time_s')}" for c in cols))
    print("Process lifetime means of registry total CPU time (s): " + "; ".join(f"{c[0]}: {lifetimes(c[1], case, c[2], 'registry_cpu_time_total_s')}" for c in cols))
    print("All wall times (s): " + "; ".join(f"{c[0]}: {[round(r['wall_time_s'], 3) for r in reps(c[1], case, c[2])]}" for c in cols))
    flagged = sum(1 for c in cols for r in reps(c[1], case, c[2]) if r["foreign_load"])
    ok = all(r["cold_cache_resident_pages_after"] == r["cold_cache_pages"] for c in cols for r in reps(c[1], case, c[2]))
    print(f"Foreign load flagged repetitions: {flagged}. Every repetition: no page of the 8 blob files was resident before and all pages were after (mincore, checked by the harness): {ok}.")
inv = A["invocations"] + B["invocations"]
print("\nPlacement and namespace per invocation (registry CPUs, client CPUs, interfaces, netfilter):",
      sorted({(i["registry_cpus"][:12], i["client_cpus"][:12], i["interfaces"], i["netfilter_rules"]) for i in inv}))
print("placement_verified in every process lifetime:", all(x["placement_verified"] for D in (A, B) for case in D["cases"].values() for arm in case.values() for x in arm))
