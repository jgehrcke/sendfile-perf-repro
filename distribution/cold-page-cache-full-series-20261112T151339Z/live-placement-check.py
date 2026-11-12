#!/usr/bin/env python3
"""Independent live check of the measured processes while run.sh runs (read-only, from the host).

    python3 -B live-placement-check.py <console log of run.sh> <output json>

It pins itself to the CPUs of NUMA node 1 (the benchmark uses node 0). Every 0.5 s it reads, for every process of
this user whose executable lies in the harness work directory (registry-unpatched, registry-patched) or is named
repro-helper (the load client, started with "go run"): the CPU affinity of every thread
(/proc/<pid>/task/*/status, Cpus_allowed_list), the memory policy of every mapping (/proc/<pid>/numa_maps) and the
network namespace (/proc/<pid>/ns/net). For every network namespace seen for the first time it enters that namespace
(nsenter --user --net --preserve-credentials) and records its interfaces and its nftables ruleset. It stops when the console log has its
exit line. It writes one record per distinct (executable, helper subcommand, affinity, policy, namespace) with the number
of samples. The helper subcommand (first argument of repro-helper: load-repeated and warmup are the load client, the
others are utility steps between measured runs) is recorded since the second version; the n15 phase used
live-placement-check.v1-used-for-n15.py, which did not record it.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

console, target = Path(sys.argv[1]), Path(sys.argv[2])
work = str(Path(__file__).resolve().parent.parent / "work/filereader-bypass") + "/"
host_namespace = os.readlink("/proc/self/ns/net")
seen, namespaces, samples = {}, {}, 0
uid = os.getuid()
node1 = Path("/sys/devices/system/node/node1/cpulist").read_text().strip()
first, _, last = node1.partition("-")
os.sched_setaffinity(0, range(int(first), int(last) + 1))     # node 1 is one contiguous range on this host


def observe(pid):
    base = Path(f"/proc/{pid}")
    exe = os.readlink(base / "exe")
    if not (exe.startswith(work) or os.path.basename(exe) == "repro-helper"):
        return
    affinity = set()
    for task in (base / "task").iterdir():
        for line in (task / "status").read_text().splitlines():
            if line.startswith("Cpus_allowed_list:"):
                affinity.add(line.split()[1])
    policies = sorted({line.split()[1] for line in (base / "numa_maps").read_text().splitlines() if line})
    namespace = os.readlink(base / "ns/net")
    if namespace not in namespaces:
        inside = ["nsenter", "--user", "--net", "--preserve-credentials", "-t", str(pid)]
        links = subprocess.run(inside + ["ip", "-o", "link", "show"], capture_output=True, text=True)
        rules = subprocess.run(inside + ["nft", "list", "ruleset"], capture_output=True, text=True)
        namespaces[namespace] = {"first_seen_pid": pid, "interfaces": [l.split(": ")[1] for l in links.stdout.splitlines()],
                                 "ip_link_exit": links.returncode, "ip_link_stderr": links.stderr.strip(),
                                 "nft_list_ruleset_stdout": rules.stdout, "nft_list_ruleset_exit": rules.returncode,
                                 "nft_list_ruleset_stderr": rules.stderr.strip(), "is_host_namespace": namespace == host_namespace}
    helper = exe.startswith(work) is False
    subcommand = ((base / "cmdline").read_bytes().split(b"\0") + [b"", b""])[1].decode() if helper else ""
    key = (os.path.basename(exe) if helper else exe[len(work):], subcommand, tuple(sorted(affinity)), tuple(policies), namespace)
    record = seen.setdefault(key, {"executable": key[0], "helper_subcommand": key[1], "cpus_allowed_of_threads": list(key[2]), "numa_policies": list(key[3]),
                                   "network_namespace": namespace, "samples": 0, "pids": []})
    record["samples"] += 1
    if pid not in record["pids"]:
        record["pids"].append(pid)


while True:
    for entry in os.scandir("/proc"):
        if entry.name.isdigit():
            try:
                if entry.stat().st_uid == uid:
                    observe(int(entry.name))
            except (OSError, IndexError):
                pass                      # the process ended between the listing and the read
    samples += 1
    done = console.exists() and "\nexit=" in console.read_text()
    if done or samples % 20 == 0:
        target.write_text(json.dumps({"host_network_namespace": host_namespace, "sampling_passes": samples, "interval_s": 0.5, "checker_cpus_allowed": node1,
                                      "work_directory": work, "processes": list(seen.values()), "network_namespaces": namespaces},
                                     indent=1) + "\n")
    if done:
        break
    time.sleep(0.5)
