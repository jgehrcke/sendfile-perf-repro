#!/usr/bin/env python3
"""Tables for this directory from the data.json files that repro/measure-filereader-bypass.py wrote.

    python3 -B summarize.py pilot|n15|tls-lifetimes            prints Markdown; writes nothing

Metric: registry total CPU time per GET in ms = registry total CPU time of one repetition (user plus system,
/proc/<pid>/stat of the registry process) divided by the GET requests of that repetition. Each cell is the
mean ± sample SD over the repetitions of one arm; n is the number of repetitions.

Arm names: in <phase>-5081-vs-5052 the script's arm "main" is #5081 and its arm "bypass" is #5052;
in <phase>-main-vs-5081 "main" is upstream main and "bypass" is #5081.
"""
import importlib.util
import json
import statistics
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("measure", here.parent / "measure-filereader-bypass.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)          # CASES, pm (mean ± sample SD), two_groups (bimodality check)

phase = sys.argv[1]
TOTAL, USER, KERNEL = "registry_cpu_time_total_s", "registry_cpu_time_user_s", "registry_cpu_time_kernel_s"
pairs = {"5081-vs-5052": {"main": "#5081 (with #5052)", "bypass": "#5052"},
         "main-vs-5081": {"main": "main", "bypass": "#5081 (with main)"}}
COLUMNS = ["main", "#5081 (with main)", "#5081 (with #5052)", "#5052"]
# Table in the commit message of #5081 (review/filereader-bypass-pr-20261111/commit-message.txt), ms per GET, n=15.
COMMIT_MESSAGE = {("http", "whole-4mib"): ((1.994, 0.026), (1.160, 0.009), "-41.8%"), ("http", "whole-32mib"): ((9.423, 0.061), (6.851, 0.021), "-27.3%"),
                  ("tls", "whole-4mib"): ((3.401, 0.027), (2.404, 0.018), "-29.3%"), ("tls", "whole-32mib"): ((20.159, 0.063), (17.528, 0.113), "-13.0%")}

arms, datas = {}, {}                      # arms[(transport, case)][column] = runs
for pair, names in pairs.items():
    path = here / f"{phase}-{pair}" / "data.json"
    if not path.exists():
        print(f"(missing: {path.name} of {pair})")
        continue
    datas[pair] = data = json.loads(path.read_text())
    for key, by_arm in data["cases"].items():
        case, transport = key.rsplit("-", 1)
        for arm, runs in by_arm.items():
            arms.setdefault((transport, case), {})[names[arm]] = runs


def per_get_ms(runs, case, metric=TOTAL):
    return [1000 * r[metric] / measure.CASES[case]["requests"] for run in runs for r in run["repetitions"]]


def cell(by, column, case, metric=TOTAL):
    if column not in by:
        return "not measured", None
    v = per_get_ms(by[column], case, metric)
    return f"{measure.pm(v)}", len(v)


n_all = {len(per_get_ms(runs, case)) for (_, case), by in arms.items() for runs in by.values()}
n_text = f"n={n_all.pop()}" if len(n_all) == 1 else "n differs, see cells"
for group, heading in (("whole", "Whole-blob GET"), ("range", "Range GET (ranges of a 512 MiB blob)")):
    print(f"## {heading}: registry total CPU time per GET, ms (mean ± sample SD, {n_text} per cell)\n")
    print("| Transport | " + ("Blob" if group == "whole" else "Range") + " | " + " | ".join(COLUMNS) + " | Change of the mean, #5081 (with #5052) to #5052 |")
    print("| --- | --- | " + " | ".join("---:" for _ in COLUMNS) + " | ---: |")
    for transport in ("http", "tls"):
        for case, c in measure.CASES.items():
            by = arms.get((transport, case))
            if c["group"] != group or not by:
                continue
            cells = [cell(by, column, case)[0] for column in COLUMNS]
            change = "n/a"
            if "#5052" in by and "#5081 (with #5052)" in by:
                a, b = per_get_ms(by["#5081 (with #5052)"], case), per_get_ms(by["#5052"], case)
                change = f"{100 * (statistics.mean(b) / statistics.mean(a) - 1):+.1f}%"
            print(f"| {measure.TRANSPORT_TITLE[transport]} | {c['title'].split(' range')[0]} | " + " | ".join(cells) + f" | {change} |")
    print()

print(f"## User and kernel CPU time per GET, ms (mean ± sample SD over repetitions, {n_text}); process lifetime means of the total\n")
print("| Transport | Case | Arm | n | Total | User | Kernel | Process lifetimes | Sample SD of the process lifetime means of the total | "
      "Process lifetime means of the total, in order of measurement |")
print("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
for (transport, case), by in sorted(arms.items(), key=lambda item: (item[0][0], list(measure.CASES).index(item[0][1]))):
    for column in COLUMNS:
        if column in by:
            k = 1000 / measure.CASES[case]["requests"]
            lifetime = [k * statistics.mean(r[TOTAL] for r in run['repetitions']) for run in by[column]]
            means = ", ".join(f"{v:.3f}" for v in lifetime)
            spread = f"{statistics.stdev(lifetime):.3f}" if len(lifetime) > 1 else "n/a"
            print(f"| {measure.TRANSPORT_TITLE[transport]} | {case} | {column} | {cell(by, column, case)[1]} | {cell(by, column, case)[0]} | "
                  f"{cell(by, column, case, USER)[0]} | {cell(by, column, case, KERNEL)[0]} | {len(lifetime)} | {spread} | {means} |")
print()

print("## Against the table in the commit message of #5081 (whole-blob GET, ms per GET, mean ± sample SD, n=15 each)\n")
print("The commit message values are from repro/filereader-bypass-20261111T222404Z (main d14ff2fb, bypass 9ccd294c).\n")
print("| Transport | Blob | Commit message, Before (main d14ff2fb) | Here, main f38cd9c0 | Commit message, Now | Here, #5081 (with main) | Here, #5081 (with #5052) | "
      "Commit message, change | Here, change of the mean, main to #5081 (with main) |")
print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for (transport, case), (before, now, stated) in COMMIT_MESSAGE.items():
    by = arms.get((transport, case), {})
    if "main" not in by:
        continue
    here = 100 * (statistics.mean(per_get_ms(by["#5081 (with main)"], case)) / statistics.mean(per_get_ms(by["main"], case)) - 1)
    print(f"| {measure.TRANSPORT_TITLE[transport]} | {measure.CASES[case]['title']} | {before[0]:.3f} ± {before[1]:.3f} | {cell(by, 'main', case)[0]} | "
          f"{now[0]:.3f} ± {now[1]:.3f} | {cell(by, '#5081 (with main)', case)[0]} | {cell(by, '#5081 (with #5052)', case)[0]} | {stated} | {here:+.1f}% |")
print()

print("## Distributions (two_groups of measure-filereader-bypass.py on registry total CPU time per repetition, "
      "and the same split on the process lifetime means when there are at least 6)\n")
found = False
for (transport, case), by in arms.items():
    for column, runs in by.items():
        groups = measure.two_groups(runs, TOTAL)
        if groups:
            found = True
            k = 1000 / measure.CASES[case]["requests"]
            print(f"- bimodal candidate: {transport} {case}, {column}: {len(groups['low'])} values with mean {k * statistics.mean(groups['low']):.3f} ms and "
                  f"{len(groups['high'])} values with mean {k * statistics.mean(groups['high']):.3f} ms per GET; "
                  + ("follows process lifetimes" if groups["follows_process_lifetimes"] else "does not follow process lifetimes"))
    for column, runs in by.items():        # the same split at the largest gap, on process lifetime means
        k = 1000 / measure.CASES[case]["requests"]
        lifetime = sorted(k * statistics.mean(r[TOTAL] for r in run["repetitions"]) for run in runs)
        if len(lifetime) < 6:
            continue
        gap, at = max((lifetime[i + 1] - lifetime[i], i + 1) for i in range(len(lifetime) - 1))
        low, high = lifetime[:at], lifetime[at:]
        sides = [statistics.stdev(side) for side in (low, high) if len(side) > 1]
        if gap >= 4 * max(sides):
            found = True
            print(f"- process lifetime means, {transport} {case}, {column}: largest gap {gap:.3f} ms between {len(low)} lifetimes "
                  f"({low[0]:.3f} to {low[-1]:.3f} ms) and {len(high)} lifetimes ({high[0]:.3f} to {high[-1]:.3f} ms); "
                  f"the gap is at least four times the sample SD on either side")
if not found:
    print("No bimodal candidate.")
print()

print("## Verification records\n")
for pair, data in datas.items():
    env = data["environment"]
    runs = [run for case in data["cases"].values() for arm in case.values() for run in arm]
    reps = [r for run in runs for r in run["repetitions"]]
    inv = data["invocations"]
    print(f"- {phase}-{pair}: {len(inv)} harness invocations, {len(runs)} process lifetimes, {len(reps)} repetitions, "
          f"placement verified for all: {all(run['placement_verified'] for run in runs)}; NUMA node {sorted({i['numa_node'] for i in inv})}; "
          f"registry CPUs {sorted({i['registry_cpus'] for i in inv})}; client CPUs {sorted({i['client_cpus'] for i in inv})}; "
          f"network namespaces {len({i['network_namespace'] for i in inv})} distinct, none the host's ({env['host_network_namespace']}): "
          f"{all(i['network_namespace'] != env['host_network_namespace'] for i in inv)}; interfaces {sorted({i['interfaces'] for i in inv})}; "
          f"netfilter rules {sorted({i['netfilter_rules'] for i in inv})}; foreign load flagged in {sum(r['foreign_load'] for r in reps)} repetitions, "
          f"largest other CPU time {max(r['other_cpu_time_s'] for r in reps):.2f} s; node busy before start at most "
          f"{max(i['node_busy_percent_before'] for i in inv):.2f}%; {env['go_version']}; base {env['base_commit'][:8]} tree {env['base_tree'][:8]}, "
          f"bypass argument {env['bypass_commit'][:8]} tree {env['bypass_tree'][:8]}; measurement wall time {data.get('measurement_wall_time_s', 'unfinished')} s")
    for arm, build in data["builds"].items():
        print(f"  - binary of script arm {arm}: source head {build['source_head'][:8]}, source tree {build['source_tree'][:8]}, {build['binary_go_version']}, "
              f"sha256 {build['binary_sha256'][:16]}")
