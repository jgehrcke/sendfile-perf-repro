#!/usr/bin/env python3
"""Tables for one phase: python3 -I -B summarize.py <phase name, e.g. p1-http-1gib> <case key, e.g. cold-c1-http> "<title>"
Reads <phase>-main-vs-5081/data.json and <phase>-5081-vs-5052/data.json (in the script's arm names the latter has
"main" = #5081 and "bypass" = #5052). Markdown to stdout. mean ± sample SD (n-1) over repetitions; changes from unrounded means."""
import json
import statistics as st
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
phase, case, title = sys.argv[1], sys.argv[2], sys.argv[3]
A = json.load(open(here / f"{phase}-main-vs-5081/data.json"))
B = json.load(open(here / f"{phase}-5081-vs-5052/data.json"))
cols = [("main", A, "main"), ("#5081 (run with main)", A, "bypass"), ("#5081 (run with #5052)", B, "main"), ("#5052", B, "bypass")]
metrics = [("Wall time per repetition (s)", "wall_time_s"), ("Registry total CPU time per repetition (s)", "registry_cpu_time_total_s"),
           ("Registry user CPU time per repetition (s)", "registry_cpu_time_user_s"), ("Registry kernel CPU time per repetition (s)", "registry_cpu_time_kernel_s")]


def lives(data, arm):
    return data["cases"][case][arm]


def reps(data, arm):
    return [r for inv in lives(data, arm) for r in inv["repetitions"]]


def fmt(x):
    m, s = st.mean(x), st.stdev(x)
    return f"{m:.3f} ± {s:.3f}" if s >= 0.01 else f"{m:.4f} ± {s:.4f}"


def ch(x, y):
    return f"{(st.mean(x) / st.mean(y) - 1) * 100:+.1f}%"


print(f"### {title} ({phase})\n")
n = {c[0]: len(reps(c[1], c[2])) for c in cols}
print("| Metric | " + " | ".join(f"{c[0]} (n={n[c[0]]})" for c in cols) + " | #5081 vs main | #5052 vs main | #5052 vs #5081 (same run) |")
print("| --- | " + " | ".join("---:" for _ in cols) + " | ---: | ---: | ---: |")
for label, key in metrics:
    v = {c[0]: [r[key] for r in reps(c[1], c[2])] for c in cols}
    print(f"| {label} | " + " | ".join(fmt(v[c[0]]) for c in cols)
          + f" | {ch(v['#5081 (run with main)'], v['main'])} | {ch(v['#5052'], v['main'])} | {ch(v['#5052'], v['#5081 (run with #5052)'])} |")
print()
for name, data, arm in cols:
    lw = [round(st.mean(r["wall_time_s"] for r in inv["repetitions"]), 3) for inv in lives(data, arm)]
    lc = [round(st.mean(r["registry_cpu_time_total_s"] for r in inv["repetitions"]), 3) for inv in lives(data, arm)]
    print(f"- {name}: wall time, process lifetime means in order (s): {lw}; registry total CPU time: {lc}")
print("\n#5052, every repetition (lifetime.repetition: wall time s, registry total CPU time s, foreign load flag):")
print("  " + "; ".join(f"{i + 1}.{j + 1}: {r['wall_time_s']:.3f}, {r['registry_cpu_time_total_s']:.2f}, {'F' if r['foreign_load'] else '-'}"
                       for i, inv in enumerate(lives(B, 'bypass')) for j, r in enumerate(inv["repetitions"])))
allr = [r for c in cols for r in reps(c[1], c[2])]
print(f"\nForeign load flagged repetitions: {sum(r['foreign_load'] for r in allr)} of {len(allr)}. Cold state (harness, mincore): no page resident before, "
      f"all pages resident after, in every repetition: {all(r['cold_cache_resident_pages_after'] == r['cold_cache_pages'] for r in allr)}.")
inv = A["invocations"] + B["invocations"]
print("Placement per invocation (registry CPUs, client CPUs, interfaces, netfilter):",
      sorted({(i["registry_cpus"][:12], i["client_cpus"][:12], i["interfaces"], i["netfilter_rules"]) for i in inv}),
      "; placement_verified in every process lifetime:", all(x["placement_verified"] for D in (A, B) for arm in D["cases"][case].values() for x in arm))
