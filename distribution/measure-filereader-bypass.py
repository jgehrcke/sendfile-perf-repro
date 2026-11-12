#!/usr/bin/env python3
"""Measure the fileReader bypass against upstream main and against smaller fileReader buffers. One command:

    repro/measure-filereader-bypass.py            full run, n = 3 process lifetimes x 5 repetitions per arm
    repro/measure-filereader-bypass.py --quick    1 lifetime x 2 repetitions, to read the trend first

It drives repro/run-repro.sh (one invocation per case and arm pair), which pins registry and load client to
disjoint CPUs of one NUMA node (NUMA_PIN=same-socket) and runs them in a private network namespace whose
loopback has no netfilter rules (LOOPBACK_NET=isolated). The script does not assume that: it checks the CPU
affinity, memory policy and network namespace that the load client recorded for registry and client in every
repetition, and stops with cause and remedy when anything differs. There is no fallback.

Output: a new directory repro/filereader-bypass-<UTC time>/ with report.md (tables ready to paste), data.json
(every repetition), the harness logs and its raw result files. Nothing existing is overwritten.

Arms: main (--base), bypass (--bypass), and main with only the fileReader buffer cap changed
(--buffer-caps-kib). Cases: whole-blob GETs with a warm page cache, range GETs of a 512 MiB blob, and
whole-blob GETs of 1 GiB blobs with a cold page cache; each over plain HTTP and TLS (HTTP/1.1).
"""
import argparse
import datetime
import difflib
import hashlib
import json
import math
import os
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
HARNESS = HERE / "run-repro.sh"
KIB, MIB, GIB = 1024, 1024 ** 2, 1024 ** 3
BUFFER_FILE = "registry/storage/filereader.go"
BUFFER_LINE = "const fileReaderBufferSize = 4 * 1024 * 1024\n"

# Requests per repetition are chosen so that the registry total CPU time of one repetition is at least about
# 0.5 s for every arm: its resolution is 0.01 s (one clock tick).
CASES = {
    "whole-1kib": dict(group="whole", title="1 KiB", blob_bytes=KIB, requests=20000, concurrency=10,
                       options=["--blob-bytes", str(KIB), "--whole-blob"]),
    "whole-100kib": dict(group="whole", title="100 KiB", blob_bytes=100 * KIB, requests=5000, concurrency=10,
                         options=["--blob-bytes", str(100 * KIB), "--whole-blob"]),
    "whole-4mib": dict(group="whole", title="4 MiB", blob_bytes=4 * MIB, requests=1000, concurrency=10,
                       options=["--blob-bytes", str(4 * MIB), "--whole-blob"]),
    "whole-32mib": dict(group="whole", title="32 MiB", blob_bytes=32 * MIB, requests=500, concurrency=10,
                        options=["--blob-bytes", str(32 * MIB), "--whole-blob"]),
    "range-32mib": dict(group="range", title="32 MiB range of a 512 MiB blob", blob_bytes=32 * MIB, requests=1000,
                        concurrency=10, options=["--chunk-mib", "32"]),
    "range-1mib": dict(group="range", title="1 MiB range of a 512 MiB blob", blob_bytes=MIB, requests=1000,
                       concurrency=10, options=["--chunk-mib", "1"]),
    "cold-c1": dict(group="cold", title="8 blobs of 1 GiB, one at a time", blob_bytes=GIB, requests=8, concurrency=1,
                    blobs=8, options=["--blob-bytes", str(GIB), "--blobs", "8", "--whole-blob", "--cold-cache"]),
    "cold-c8": dict(group="cold", title="8 blobs of 1 GiB, all at once", blob_bytes=GIB, requests=8, concurrency=8,
                    blobs=8, options=["--blob-bytes", str(GIB), "--blobs", "8", "--whole-blob", "--cold-cache"]),
    # Added 2026-11-12: small cold blobs; 128 x 32 MiB = 4 GiB per repetition gives a registry total CPU time well above 0.01 s.
    "cold32-c1": dict(group="cold", title="128 blobs of 32 MiB, one at a time", blob_bytes=32 * MIB, requests=128, concurrency=1,
                      blobs=128, options=["--blob-bytes", str(32 * MIB), "--blobs", "128", "--whole-blob", "--cold-cache"]),
}
# The cap only takes effect for blobs larger than it: the 1 KiB and 100 KiB cases are left out.
DEFAULT_BUFFER_CASES = "whole-4mib,whole-32mib,range-32mib,range-1mib,cold-c1,cold-c8"
TRANSPORT_TITLE = {"http": "Plain HTTP", "tls": "TLS"}
# Variables that would change what the harness measures; they are set here and never inherited.
HARNESS_VARIABLES = ("NUMA_PIN LOOPBACK_NET REGISTRY_CPU_LIST CLIENT_CPU_LIST REGISTRY_NUMA_NODE CLIENT_NUMA_NODE LAYER_SIZE_MB "
                     "REGISTRY_PORT PATCH_FILE REGISTRY_TLS REGISTRY_REF REGISTRY_REPO_URL WORK_DIR BLOB_BYTES BLOB_COUNT WHOLE_BLOB "
                     "COLD_CACHE LIFETIMES VARIANTS REPEATS REQUESTS CONCURRENCY CHUNK_SIZE_MIB SWEEP GOMAXPROCS GODEBUG GOFLAGS "
                     "GOEXPERIMENT GO_BUILD_FLAGS GO_BIN RUN_REPRO_HOST_NETNS REPRO_COLD_FILES REPRO_WHOLE_BLOB REPRO_PINNED_CPUS").split()


def log(message):
    print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {message}", flush=True)


def die(operation, reason, remedy=None):
    """Stop with what the script was doing, what failed, and what to do about it."""
    print(f"ERROR: error {operation}: {reason}" + (f"\n       remedy: {remedy}" if remedy else ""), flush=True)
    sys.exit(1)


def run_text(*command, cwd=None, env=None):
    return subprocess.run(command, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError as error:
        return f"unreadable ({error.strerror})"


# ---------------------------------------------------------------------------------------------- measurement
class Measurement:
    def __init__(self, args):
        self.args = args
        self.repo = Path(args.repo).resolve()
        self.work = Path(args.work_dir).resolve()
        self.store = self.work / "arm-binaries"
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.out = Path(args.out).resolve() if args.out else HERE / f"filereader-bypass-{stamp}{'-quick' if args.quick else ''}"
        self.lifetimes = args.lifetimes or (1 if args.quick else 3)
        self.repetitions = args.repetitions or (2 if args.quick else 5)
        self.cases = [c for c in args.cases.split(",") if c]
        self.transports = [t for t in args.transports.split(",") if t]
        self.buffer_cases = [c for c in args.buffer_cases.split(",") if c]
        self.caps = [int(c) for c in args.buffer_caps_kib.split(",") if c]
        for name in self.cases + self.buffer_cases:
            if name not in CASES:
                die("reading the command line", f"unknown case {name}", "choose from " + ", ".join(CASES))
        for name in self.transports:
            if name not in TRANSPORT_TITLE:
                die("reading the command line", f"unknown transport {name}", "choose from http, tls")
        self.data = {"cases": {}, "invocations": [], "builds": {}}

    # ------------------------------------------------------------------ preparation
    def prepare(self):
        for tool in ("git", "curl", "openssl", "numactl", "unshare", "ip", "nft", "findmnt", "lscpu", self.args.go):
            if not shutil.which(tool):
                die("checking required commands", f"{tool} not found", f"install {tool}; the harness needs it to pin, isolate or verify")
        for name in HARNESS_VARIABLES:
            if name in os.environ:
                die("checking the environment", f"{name} is set", f"unset {name}; this script sets the harness variables itself")
        self.work.mkdir(parents=True, exist_ok=True)
        self.store.mkdir(exist_ok=True)
        self.out.mkdir(parents=True)          # fails if it exists: results are never overwritten
        for name in ("logs", "sessions", "patches"):
            (self.out / name).mkdir()
        self.env = {k: v for k, v in os.environ.items()} | {
            "GOTOOLCHAIN": "go" + self.args.go_version, "GOMODCACHE": str(Path(self.args.go_mod_cache).resolve()),
            "GO_BIN": self.args.go, "GO_BUILD_FLAGS": "-mod=vendor -trimpath",
            "REGISTRY_REPO_URL": str(self.repo), "WORK_DIR": str(self.work),
            "NUMA_PIN": "same-socket", "LOOPBACK_NET": "isolated",
        }
        try:
            go_version = run_text(self.args.go, "version", env=self.env)
        except (subprocess.CalledProcessError, OSError) as error:
            die("getting the Go toolchain", f"{self.args.go} version with GOTOOLCHAIN=go{self.args.go_version}: {getattr(error, 'stderr', error)}",
                "make that toolchain available (network access, or a module cache that holds it: --go-mod-cache)")
        if f"go{self.args.go_version} " not in go_version + " ":
            die("getting the Go toolchain", f"wanted go{self.args.go_version}, got: {go_version}")

        def commit(rev):
            try:
                full = run_text("git", "-C", str(self.repo), "rev-parse", "--verify", rev + "^{commit}")
                return full, run_text("git", "-C", str(self.repo), "rev-parse", full + "^{tree}")
            except subprocess.CalledProcessError as error:
                die("resolving revisions", f"git rev-parse {rev} in {self.repo}: {error.stderr.strip()}",
                    "pass --repo with a clone that holds both revisions, or --base and --bypass")
        self.base, self.base_tree = commit(self.args.base)
        self.env["REGISTRY_REF"] = self.base
        self.arms = {"main": {"title": "main", "what": f"upstream main, commit {self.base[:8]}", "tree": self.base_tree}}
        if self.args.bypass:
            bypass, bypass_tree = commit(self.args.bypass)
            if subprocess.run(["git", "-C", str(self.repo), "merge-base", "--is-ancestor", self.base, bypass]).returncode:
                die("resolving revisions", f"{self.base[:8]} is not an ancestor of {bypass[:8]}", "rebase the bypass branch onto --base")
            patch = self.out / "patches/bypass.patch"
            patch.write_text(run_text("git", "-C", str(self.repo), "diff", "--binary", self.base, bypass) + "\n")
            self.arms["bypass"] = {"title": "bypass", "what": f"bypass branch, commit {bypass[:8]}", "commit": bypass, "tree": bypass_tree, "patch": patch}
        original = run_text("git", "-C", str(self.repo), "show", f"{self.base}:{BUFFER_FILE}") + "\n"
        if self.caps and original.count(BUFFER_LINE) != 1:
            die("writing the buffer cap patches", f"{BUFFER_FILE} at {self.base[:8]} does not contain the line {BUFFER_LINE.strip()!r} exactly once",
                "pass --buffer-caps-kib '' to leave these arms out")
        for cap in self.caps:
            changed = original.replace(BUFFER_LINE, f"const fileReaderBufferSize = {cap} * 1024\n")
            patch = self.out / f"patches/buffer-{cap}kib.patch"
            patch.write_text("".join(difflib.unified_diff(original.splitlines(True), changed.splitlines(True),
                                                          "a/" + BUFFER_FILE, "b/" + BUFFER_FILE)))
            title = f"{cap // 1024} MiB buffer" if cap % 1024 == 0 else f"{cap} KiB buffer"
            self.arms[f"buffer-{cap}kib"] = {"title": title, "what": f"main with the fileReader buffer capped at {cap} KiB instead of 4 MiB", "patch": patch}
        for arm in self.arms.values():
            if "patch" in arm:
                arm["patch_sha256"] = sha256(arm["patch"])
        self.host_namespace = os.readlink("/proc/self/ns/net")
        nodes = sorted((int(p.name[4:]) for p in Path("/sys/devices/system/node").glob("node[0-9]*") if read(p / "cpulist")), key=int)
        self.node = nodes[0]                  # the harness pins to the first NUMA node that has CPUs
        self.node_cpus = self.expand(read(f"/sys/devices/system/node/node{self.node}/cpulist"))
        self.data |= {"command": sys.argv, "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      "quick": self.args.quick, "lifetimes": self.lifetimes, "repetitions_per_lifetime": self.repetitions,
                      "foreign_load_threshold_fraction": self.args.foreign_load_threshold,
                      "arms": {name: {k: str(v) for k, v in arm.items()} for name, arm in self.arms.items()},
                      "environment": self.environment(go_version)}

    @staticmethod
    def expand(cpulist):
        cpus = []
        for part in cpulist.split(","):
            first, _, last = part.partition("-")
            cpus += range(int(first), int(last or first) + 1)
        return cpus

    def environment(self, go_version):
        lscpu = {item["field"].rstrip(":"): item["data"] for item in json.loads(run_text("lscpu", "--json"))["lscpu"]}
        device = os.stat(self.work).st_dev
        number = f"{os.major(device)}:{os.minor(device)}"
        block = Path(f"/sys/dev/block/{number}").resolve()
        disk = block if (block / "queue").exists() else block.parent
        source, fstype, options = (run_text("findmnt", "-n", "-T", str(self.work), "-o", "SOURCE,FSTYPE,OPTIONS").split() + ["", "", ""])[:3]
        return {
            "kernel": platform.release(), "architecture": platform.machine(), "page_size_bytes": os.sysconf("SC_PAGE_SIZE"),
            "clock_ticks_per_second": os.sysconf("SC_CLK_TCK"),
            "cpu_model": lscpu.get("Model name"), "sockets": lscpu.get("Socket(s)"), "cores_per_socket": lscpu.get("Core(s) per socket"),
            "threads_per_core": lscpu.get("Thread(s) per core"), "logical_cpus": os.cpu_count(),
            "system": " ".join(read(f"/sys/devices/virtual/dmi/id/{n}") for n in ("sys_vendor", "product_name")),
            "os": dict(line.split("=", 1) for line in read("/etc/os-release").replace('"', "").splitlines() if "=" in line).get("PRETTY_NAME"),
            "transparent_hugepage": read("/sys/kernel/mm/transparent_hugepage/enabled"),
            "numa_node_used": self.node, "numa_node_cpus": read(f"/sys/devices/system/node/node{self.node}/cpulist"),
            "go_version": go_version, "go_build_flags": self.env["GO_BUILD_FLAGS"],
            "base_commit": self.base, "base_tree": self.base_tree,
            "bypass_commit": self.arms.get("bypass", {}).get("commit"), "bypass_tree": self.arms.get("bypass", {}).get("tree"),
            "harness_sha256": sha256(HARNESS), "script_sha256": sha256(__file__),
            "repository_commit_of_harness": subprocess.run(["git", "-C", str(ROOT), "log", "-1", "--format=%H", "--", "repro/run-repro.sh"],
                                                           capture_output=True, text=True).stdout.strip() or None,
            "host_network_namespace": self.host_namespace,
            "registry_storage": {
                "directory": str(self.work / "registry-storage"), "filesystem": fstype, "mount_source": source, "mount_options": options,
                "block_device": disk.name, "partition": block.name, "model": read(disk / "device/model"),
                "rotational": read(disk / "queue/rotational"),
                "read_ahead_kb": read(disk / "queue/read_ahead_kb"),
            },
        }

    # ------------------------------------------------------------------ idle check and binaries
    def cpu_times(self):
        busy = total = 0
        wanted = {f"cpu{c}" for c in self.node_cpus}
        for line in Path("/proc/stat").read_text().splitlines():
            fields = line.split()
            if fields[0] in wanted:
                values = list(map(int, fields[1:9]))
                total += sum(values)
                busy += sum(values) - values[3] - values[4]
        return busy, total

    def wait_until_idle(self, label):
        """The benchmark CPUs must be idle before an invocation starts. Poll for at most 60 s, then stop."""
        deadline = time.time() + 60
        while True:
            busy0, total0 = self.cpu_times()
            time.sleep(0.5)
            busy1, total1 = self.cpu_times()
            percent = 100 * (busy1 - busy0) / max(1, total1 - total0)
            if percent < 2:
                return percent
            log(f"{label}: NUMA node {self.node} is {percent:.1f}% busy before the start; waiting for it to be idle")
            if time.time() > deadline:
                die("checking that the benchmark CPUs are idle", f"NUMA node {self.node} is still {percent:.1f}% busy (0.5 s window) after 60 s",
                    "stop the other workload on these CPUs and run again")

    def worktree_tree(self, src):
        index = self.work / f"verify-index-{os.getpid()}"
        index.unlink(missing_ok=True)
        env = os.environ | {"GIT_INDEX_FILE": str(index)}
        for command in (["read-tree", "HEAD"], ["add", "-A", "."]):
            subprocess.run(["git", "-C", str(src), *command], env=env, check=True)
        tree = run_text("git", "-C", str(src), "write-tree", env=env)
        index.unlink()
        return tree

    def stored(self, arm):
        key = hashlib.sha256(f"{self.base} {self.arms[arm]['patch_sha256']} {self.args.go_version}".encode()).hexdigest()[:16]
        return self.store / f"{arm}-{key}"

    def place_binary(self, arm):
        """The harness has one slot for the patched binary; put this arm's stored binary there, or make it build."""
        slot, key = self.work / "bin/registry-patched", self.work / "bin/patched.key"
        if (self.stored(arm) / "registry-patched").exists():
            (self.work / "bin").mkdir(exist_ok=True)
            shutil.copy2(self.stored(arm) / "registry-patched", slot)
            shutil.copy2(self.stored(arm) / "patched.key", key)
        else:
            key.unlink(missing_ok=True)

    def account_binary(self, variant, arm, text):
        """Verify what the harness built (source and Go version) and remember it; verify what it reused."""
        binary = self.work / "bin" / f"registry-{variant}"
        record_path = (self.stored(arm) if variant == "patched" else self.store) / ("build.json" if variant == "patched" else f"main-{self.base[:16]}.json")
        if f"building {variant} registry" in text:
            src = self.work / "build-src" / variant
            record = {"arm": arm, "source_head": run_text("git", "-C", str(src), "rev-parse", "HEAD"),
                      "source_changes": run_text("git", "-C", str(src), "diff", "--numstat", "HEAD"),
                      "source_tree": self.worktree_tree(src), "binary_sha256": sha256(binary),
                      "binary_go_version": run_text(self.args.go, "version", str(binary), env=self.env).split(": ")[-1]}
            expected_tree = self.arms[arm].get("tree")
            ok = record["source_head"] == self.base and record["binary_go_version"] == "go" + self.args.go_version
            ok = ok and (record["source_tree"] == expected_tree if expected_tree else record["source_changes"] == f"1\t1\t{BUFFER_FILE}")
            if not ok:
                die(f"verifying the build of arm {arm}", "source or Go version differ from what was requested: " + json.dumps(record),
                    f"inspect {src}")
            if variant == "patched":
                self.stored(arm).mkdir(exist_ok=True)
                shutil.copy2(binary, self.stored(arm) / "registry-patched")
                shutil.copy2(self.work / "bin/patched.key", self.stored(arm) / "patched.key")
            record_path.write_text(json.dumps(record, indent=1) + "\n")
            log(f"built {arm}: source verified, {record['binary_go_version']}, sha256 {record['binary_sha256'][:12]}")
        elif f"keeping cached {variant} registry build" in text:
            if not record_path.exists():
                die(f"verifying the binary of arm {arm}", f"the harness reused {binary} but there is no build record {record_path}",
                    f"remove {self.work / 'bin'} so that it is rebuilt and verified")
            record = json.loads(record_path.read_text())
            if record["binary_sha256"] != sha256(binary):
                die(f"verifying the binary of arm {arm}", f"{binary} differs from its build record {record_path}",
                    f"remove {self.work / 'bin'} and {self.store}")
        else:
            die(f"verifying the binary of arm {arm}", f"the harness log states neither a build nor a reuse of the {variant} binary")
        self.data["builds"][arm] = record

    # ------------------------------------------------------------------ one harness invocation
    def invoke(self, case, transport, variants, arm):
        spec = CASES[case]
        label = f"{case}-{transport}--{'main+' if variants == 'both' else ''}{arm}"
        patch_arm = arm if arm != "main" else next(a for a in self.arms if a != "main")
        command = ["sh", str(HARNESS), *spec["options"], "--requests", str(spec["requests"]), "--concurrency", str(spec["concurrency"]),
                   "--repeats", str(self.repetitions), "--lifetimes", str(self.lifetimes), "--variants", variants]
        env = self.env | {"REGISTRY_TLS": "1" if transport == "tls" else "0", "PATCH_FILE": str(self.arms[patch_arm]["patch"])}
        self.place_binary(patch_arm)
        idle = self.wait_until_idle(label)
        names = {"unpatched": "main", "patched": patch_arm}
        log(f"starting {label}: {self.lifetimes} lifetime(s) x {self.repetitions} repetition(s), {spec['requests']} requests per repetition, "
            f"concurrency {spec['concurrency']}")
        log_path = self.out / "logs" / (label + ".log")
        started, lifetime = time.time(), 1
        with log_path.open("x") as output, log_path.open() as tail:
            process = subprocess.Popen(command, env=env, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            line, last_line, last_progress, exited = "", "", time.time(), False
            try:
                while True:
                    chunk = tail.readline()
                    if chunk:
                        line += chunk
                        if not line.endswith("\n"):
                            continue
                        last_line, last_progress = line, time.time()
                        m = re.match(r"==> process lifetime (\d+) of", line)
                        if m:
                            lifetime = int(m.group(1))
                        m = re.match(r"(unpatched|patched)-r(\d+): .* wall=([\d.]+)s registry_cpu_total=([\d.]+)s", line)
                        if m:
                            log(f"  {case}-{transport} {names[m.group(1)]}: lifetime {lifetime}/{self.lifetimes}, repetition {m.group(2)}/{self.repetitions}: "
                                f"registry total CPU time {m.group(4)} s, wall time {m.group(3)} s")
                        elif re.match(r"==> (building|cloning|uploading blob)|generating ", line):
                            log("  " + line.strip().removeprefix("==> "))
                        line = ""
                        continue
                    if exited:
                        break
                    if process.poll() is not None:
                        exited = True         # read once more: output written just before the exit
                        continue
                    # A stall is the absence of new log lines. Builds, blob generation and uploads print nothing while they work.
                    limit = 600 if re.search(r"building |generating |uploading blob|cloning |fetching ", last_line) else 60
                    if time.time() - last_progress > limit:
                        os.killpg(process.pid, signal.SIGTERM)
                        die(f"running {label}", f"no new harness output for {limit} s; last line: {last_line.strip()!r}; harness stopped",
                            f"read {log_path}")
                    time.sleep(0.2)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
        text = log_path.read_text()
        if process.returncode:
            print("".join(text.splitlines(True)[-25:]), flush=True)
            die(f"running {label}", f"run-repro.sh exited with code {process.returncode} (its last lines are above)", f"read {log_path}")
        self.account_binary("unpatched", "main", text)
        self.account_binary("patched", patch_arm, text)
        pin = re.search(r"NUMA same-socket pinning active: node (\d+), registry CPUs (\S+), client CPUs (\S+);", text)
        net = re.search(r"==> loopback_net=isolated net_namespace=(\S+) host_net_namespace=(\S+) interfaces=(\S+) netfilter_rules=(\S+)", text)
        if not pin:
            die(f"verifying {label}", "the harness log has no line stating that same-socket pinning is active", f"read {log_path}")
        if not net or net.group(1) == self.host_namespace or net.group(2) != self.host_namespace or net.group(3) != "lo" \
                or net.group(4) != "empty(nft-list-ruleset)":
            die(f"verifying {label}", "the harness did not record a private network namespace with only lo and an empty nftables ruleset: "
                + (net.group(0) if net else "no loopback_net=isolated line"), f"read {log_path}")
        node, registry_cpus, client_cpus = int(pin.group(1)), pin.group(2), pin.group(3)
        if set(self.expand(registry_cpus)) & set(self.expand(client_cpus)) or not set(self.expand(registry_cpus) + self.expand(client_cpus)) <= set(self.node_cpus):
            die(f"verifying {label}", f"registry CPUs {registry_cpus} and client CPUs {client_cpus} are not disjoint sets on NUMA node {self.node}")
        session = Path(re.findall(r"done; session results: (.+)", text)[-1])
        shutil.copytree(session, self.out / "sessions" / label)
        invocation = {"label": label, "case": case, "transport": transport, "variants": variants, "arm": arm, "command": command[2:],
                      "elapsed_s": round(time.time() - started, 1), "node_busy_percent_before": round(idle, 2),
                      "numa_node": node, "registry_cpus": registry_cpus, "client_cpus": client_cpus,
                      "network_namespace": net.group(1), "interfaces": net.group(3), "netfilter_rules": net.group(4)}
        self.data["invocations"].append(invocation)
        expected_registry = {"cpus_allowed": [self.expand(registry_cpus)], "numa_policies": [f"bind:{node}"], "net_namespace": net.group(1)}
        expected_client = {"cpus_allowed": [self.expand(client_cpus)], "numa_policies": [f"bind:{node}"], "net_namespace": net.group(1)}
        for variant in (("unpatched", "patched") if variants == "both" else (variants,)):
            runs = self.data["cases"].setdefault(f"{case}-{transport}", {}).setdefault(names[variant], [])
            for life in range(1, self.lifetimes + 1):
                run = {"invocation": label, "process_lifetime": len(runs) + 1, "repetitions": []}
                for repetition in range(1, self.repetitions + 1):
                    tag = f"-l{life}" if self.lifetimes > 1 else ""
                    name = f"{variant}-default-n{spec['requests']}{tag}-r{repetition}.json"
                    result = json.loads((session / transport / name).read_text())
                    where = f"{label}, {names[variant]}, lifetime {life}, repetition {repetition}"
                    for role, expected in (("registry", expected_registry), ("client", expected_client)):
                        got = {k: result[role + "_placement"][k] for k in expected}
                        got["cpus_allowed"] = [self.expand(cpus) for cpus in got["cpus_allowed"]]
                        if got != expected:
                            die(f"verifying the placement of the {role} in {where}", f"recorded {json.dumps(got)}, expected {json.dumps(expected)}",
                                "results are not accepted; check numactl and the harness log " + str(log_path))
                    whole = spec["group"] != "range"
                    if (result["requests"], result["concurrency"], result["whole_blob"], result["blob_count"], result["transferred_bytes"]) != \
                            (spec["requests"], spec["concurrency"], whole, spec.get("blobs", 1), spec["requests"] * spec["blob_bytes"]):
                        die(f"verifying the workload of {where}", f"the result file {name} does not describe the requested workload")
                    if spec["group"] == "cold" and not (result["cold_cache_pages"] > 0 and result["cold_cache_resident_pages_before"] == 0
                                                        and result["cold_cache_resident_pages_after"] == result["cold_cache_pages"]):
                        die(f"verifying the page cache state of {where}", "the blob files were not absent from the page cache before and fully in it after: "
                            + json.dumps({k: v for k, v in result.items() if k.startswith("cold_cache")}))
                    # CPU time of the pinned CPUs that neither registry nor client account for: other work there.
                    other = result["pinned_cpus_busy_seconds"] - result["registry_cpu_seconds"] - result["client_cpu_seconds"]
                    fraction = other / result["pinned_cpus_busy_seconds"]
                    run["repetitions"].append({
                        "registry_cpu_time_total_s": result["registry_cpu_seconds"], "registry_cpu_time_user_s": result["registry_user_cpu_seconds"],
                        "registry_cpu_time_kernel_s": result["registry_kernel_cpu_seconds"], "wall_time_s": result["wall_seconds"],
                        "client_cpu_time_s": result["client_cpu_seconds"], "pinned_cpus_busy_time_s": result["pinned_cpus_busy_seconds"],
                        "other_cpu_time_s": round(other, 3), "other_cpu_time_fraction": round(fraction, 4),
                        "foreign_load": other > 0.3 and fraction > self.args.foreign_load_threshold,
                        "cold_cache_pages": result["cold_cache_pages"], "cold_cache_resident_pages_after": result["cold_cache_resident_pages_after"],
                        "file": f"sessions/{label}/{transport}/{name}"})
                run["registry_pid"], run["client_pid"] = result["registry_placement"]["pid"], result["client_placement"]["pid"]
                run["placement_verified"] = True      # every repetition above matched, or the script has stopped
                runs.append(run)
        (self.out / "data.json").write_text(json.dumps(self.data, indent=1) + "\n")
        log(f"finished {label} in {invocation['elapsed_s']:.0f} s; placement and network namespace verified for every repetition")

    def run(self):
        self.prepare()
        plan = []
        for case in self.cases:
            for transport in self.transports:
                if "bypass" in self.arms:
                    plan.append((case, transport, "both", "bypass"))
                elif len(self.arms) > 1:
                    plan.append((case, transport, "unpatched", "main"))
                plan += [(case, transport, "patched", arm) for arm in self.arms if arm.startswith("buffer-") and case in self.buffer_cases]
        if not plan:
            die("planning the run", "nothing to measure", "main needs at least one other arm: --bypass or --buffer-caps-kib")
        log(f"{len(plan)} harness invocations; n = {self.lifetimes} x {self.repetitions} = {self.lifetimes * self.repetitions} repetitions per arm and case; "
            f"results in {self.out}")
        started = time.time()
        for number, step in enumerate(plan, 1):
            log(f"invocation {number} of {len(plan)}")
            self.invoke(*step)
        self.data["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.data["measurement_wall_time_s"] = round(time.time() - started)
        (self.out / "data.json").write_text(json.dumps(self.data, indent=1) + "\n")
        return self.out


# ---------------------------------------------------------------------------------------------- report
def pm(values, scale=1.0):
    """mean ± sample SD: the SD rounded to two significant figures, the mean to the same decimal place."""
    values = [v * scale for v in values]
    mean = statistics.mean(values)
    if len(values) < 2:
        return f"{mean:.3g} ± n/a"
    sd = statistics.stdev(values)
    # sd == 0 (identical values): show four significant figures of the mean.
    decimals = max(0, min(6, (1 - math.floor(math.log10(sd))) if sd else (3 - math.floor(math.log10(abs(mean) or 1)))))
    return f"{mean:.{decimals}f} ± {sd:.{decimals}f}"


def change(a, b):
    """Change of the mean from a to b, in percent."""
    return f"{100 * (statistics.mean(b) / statistics.mean(a) - 1):+.1f}%"


def values(runs, metric):
    return [r[metric] for run in runs for r in run["repetitions"]]


def lifetime_means(runs, metric):
    return [statistics.mean(r[metric] for r in run["repetitions"]) for run in runs]


def separated(a_runs, b_runs, metric):
    """Whether every process lifetime mean of one arm lies below every process lifetime mean of the other."""
    a, b = lifetime_means(a_runs, metric), lifetime_means(b_runs, metric)
    if len(a) < 2 or len(b) < 2:
        return "one lifetime, not assessed"
    return "yes" if max(a) < min(b) or max(b) < min(a) else "no"


def two_groups(runs, metric, tick=0.01):
    """Look for two modes: split the sorted values at their largest gap. Report when both sides hold at least three
    values and the gap is at least four pooled within-side sample SDs and three clock ticks."""
    pairs = sorted((r[metric], run["process_lifetime"]) for run in runs for r in run["repetitions"])
    data = [v for v, _ in pairs]
    if len(data) < 6:
        return None
    gap, at = max((data[i + 1] - data[i], i + 1) for i in range(len(data) - 1))
    low, high = data[:at], data[at:]
    if min(len(low), len(high)) < 3:
        return None
    pooled = math.sqrt(((len(low) - 1) * statistics.variance(low) + (len(high) - 1) * statistics.variance(high)) / (len(data) - 2))
    if gap < max(4 * pooled, 3 * tick):
        return None
    by_lifetime = {l for _, l in pairs[:at]}.isdisjoint({l for _, l in pairs[at:]})
    return {"low": low, "high": high, "gap": gap, "follows_process_lifetimes": by_lifetime}


def report(out, name="report.md"):
    data = json.loads((out / "data.json").read_text())
    env, cases, arms = data["environment"], data["cases"], data["arms"]
    storage = env["registry_storage"]
    n_design = f"{data['lifetimes']} process lifetime(s) of {data['repetitions_per_lifetime']} repetitions"
    lines = []
    add = lines.append
    total, user, kernel, wall = "registry_cpu_time_total_s", "registry_cpu_time_user_s", "registry_cpu_time_kernel_s", "wall_time_s"

    def present(group, transport):
        return [(c, cases[f"{c}-{transport}"]) for c in CASES if CASES[c]["group"] == group and f"{c}-{transport}" in cases
                and "main" in cases[f"{c}-{transport}"]]

    add("# fileReader bypass: registry CPU time and wall time against main" + (" (quick run, low n)" if data["quick"] else ""))
    add("")
    add(f"Measured {data['started_utc'][:10]} with `repro/measure-filereader-bypass.py` (command: `{' '.join(data['command'][1:]) or 'no options'}`), "
        f"which drives `repro/run-repro.sh`. Every arm and case: {n_design}"
        f"{'' if not data['quick'] else '; a quick run shows the trend only'}. All ± values are sample standard deviations over repetitions.")
    add("")
    add("## Arms")
    add("")
    for arm in arms.values():
        add(f"- {arm['title']}: {arm['what']}" + (f", tree `{arm['tree'][:8]}`" if "tree" in arm else "") + ".")
    add("")
    add("## Method and environment")
    add("")
    runs_all = [run for case in cases.values() for runs in case.values() for run in runs]
    reps_all = [r for run in runs_all for r in run["repetitions"]]
    flagged = [r for r in reps_all if r["foreign_load"]]
    add(f"- Placement: registry and load client pinned to disjoint CPU sets of NUMA node {env['numa_node_used']} with `numactl --physcpubind --membind` "
        f"(`NUMA_PIN=same-socket`): registry CPUs {data['invocations'][0]['registry_cpus']}, client CPUs {data['invocations'][0]['client_cpus']}.")
    add("- Network: registry and client run in a private network namespace whose loopback has no netfilter rules (`LOOPBACK_NET=isolated`); "
        "HTTP/1.1 on loopback for both transports.")
    add(f"- Verified, not assumed: for each of the {len(reps_all)} repetitions in {len(runs_all)} process lifetimes the load client recorded the CPU affinity of every "
        "thread, the memory policy of every mapping and the network namespace of registry and client; all match the requested placement and the "
        "namespace the harness verified (only `lo`, empty nftables ruleset). The script stops otherwise.")
    worst = max(reps_all, key=lambda r: r["other_cpu_time_s"])
    add(f"- Foreign load: per repetition, the busy time of the pinned CPUs (user, nice, system, irq, softirq from `/proc/stat`) minus registry and client CPU time. "
        f"A repetition is flagged when that remainder exceeds 0.3 s and {100 * data['foreign_load_threshold_fraction']:.0f}% of the busy time. "
        f"Flagged: {len(flagged)} of {len(reps_all)} repetitions"
        + ("" if not flagged else " (" + ", ".join(sorted({r['file'] for r in flagged})) + "; they are included in the tables)")
        + f". Largest remainder: {worst['other_cpu_time_s']:.2f} s, {100 * worst['other_cpu_time_fraction']:.0f}% of the busy time of that repetition. "
        "The CPUs were also checked to be idle before every harness invocation.")
    add(f"- CPU time: `/proc/<pid>/stat` of the registry process, resolution {1 / env['clock_ticks_per_second']:.2f} s per repetition. "
        "Access logging disabled, `OTEL_TRACES_EXPORTER=none`.")
    add(f"- Host: {env['system']}, {env['cpu_model']}, {env['sockets']} sockets with {env['cores_per_socket']} cores each, {env['architecture']}, "
        f"Linux {env['kernel']}, page size {env['page_size_bytes'] // 1024} KiB, {env['os']}.")
    add(f"- Build: {env['go_version'].removeprefix('go version ')}, `go build {env['go_build_flags']} ./cmd/registry`; "
        f"main `{env['base_commit'][:8]}` (tree `{env['base_tree'][:8]}`)"
        + (f", bypass `{env['bypass_commit'][:8]}` (tree `{env['bypass_tree'][:8]}`)" if env.get("bypass_commit") else "") + ". Source and Go version of every binary verified.")
    add(f"- Registry storage: {storage['filesystem']} on `{storage['partition']}` ({storage['model']}, "
        f"{'rotating disk' if storage['rotational'] == '1' else 'not a rotating disk'}), readahead {storage['read_ahead_kb']} KiB.")
    add("")

    for group, heading, intro in (
            ("whole", "Whole-blob GETs, warm page cache", "One repetition is the stated number of GET requests for one whole blob, 10 concurrent. "
             "Registry total CPU time per request is the registry total CPU time of a repetition divided by its requests."),
            ("range", "Range GETs, warm page cache", "One repetition is 1000 GET requests, 10 concurrent, each for one range of a 512 MiB blob at a pseudo-random "
             "multiple of the range size.")):
        if not any(present(group, t) for t in TRANSPORT_TITLE):
            continue
        add(f"## {heading}")
        add("")
        add(intro + " \"Separated\" says whether every process lifetime mean of one arm lies below every process lifetime mean of the other.")
        add("")
        for transport, title in TRANSPORT_TITLE.items():
            rows = present(group, transport)
            if not rows:
                continue
            unit, scale = ("µs", 1e6) if group == "whole" else ("s", 1.0)
            per = "per request" if group == "whole" else "per repetition"
            add(f"{title}:")
            add("")
            add(f"| {'Blob size' if group == 'whole' else 'Range'} | Requests per repetition | main: registry total CPU time {per} (mean ± sample SD, {unit}) | n | "
                f"bypass: registry total CPU time {per} (mean ± sample SD, {unit}) | n | Change of the mean, main to bypass | Separated |")
            add("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
            for case, by_arm in rows:
                if "bypass" not in by_arm:
                    continue
                k = scale / CASES[case]["requests"] if group == "whole" else 1.0
                m, b = values(by_arm["main"], total), values(by_arm["bypass"], total)
                add(f"| {CASES[case]['title'].split(' range')[0]} | {CASES[case]['requests']} | {pm(m, k)} | {len(m)} | {pm(b, k)} | {len(b)} | {change(m, b)} | "
                    f"{separated(by_arm['main'], by_arm['bypass'], total)} |")
            add("")
        add("<details>")
        add(f"<summary>{heading}: user and kernel CPU time, process lifetime means</summary>")
        add("")
        add("Seconds per repetition.")
        add("")
        add("| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Registry user CPU time (mean ± sample SD, s) | "
            "Registry kernel CPU time (mean ± sample SD, s) | Process lifetime means of registry total CPU time (s) |")
        add("| --- | --- | --- | ---: | ---: | ---: | ---: | --- |")
        for transport, title in TRANSPORT_TITLE.items():
            for case, by_arm in present(group, transport):
                for arm in ("main", "bypass"):
                    if arm in by_arm:
                        add(f"| {title} | {CASES[case]['title'].split(' of a')[0]} | {arm} | {len(values(by_arm[arm], total))} | {pm(values(by_arm[arm], total))} | "
                            f"{pm(values(by_arm[arm], user))} | {pm(values(by_arm[arm], kernel))} | {', '.join(f'{v:.3f}' for v in lifetime_means(by_arm[arm], total))} |")
        add("")
        add("</details>")
        add("")

    if any(present("cold", t) for t in TRANSPORT_TITLE):
        add("## Whole-blob GETs, cold page cache")
        add("")
        add("One repetition is 8 GET requests, one for each of 8 distinct blobs of 1 GiB (8 GiB), one at a time or all at once. Before every repetition "
            "each blob file is dropped from the page cache with `posix_fadvise(POSIX_FADV_DONTNEED)`; `mincore()` showed no page of the files in the page cache "
            "before and every page after, in every repetition.")
        add("")
        add(f"Storage: {storage['filesystem']} on {storage['model']} ({'rotating disk' if storage['rotational'] == '1' else 'NVMe solid-state drive' if storage['block_device'].startswith('nvme') else 'not a rotating disk'}), "
            f"readahead {storage['read_ahead_kb']} KiB. A result on this device says nothing about rotating disks or network filesystems.")
        add("")
        add("| Transport | Concurrency | Metric | main (mean ± sample SD, s) | n | bypass (mean ± sample SD, s) | n | Change of the mean, main to bypass | Separated |")
        add("| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |")
        for transport, title in TRANSPORT_TITLE.items():
            for case, by_arm in present("cold", transport):
                if "bypass" not in by_arm:
                    continue
                for metric, label in ((wall, "Wall time per repetition"), (total, "Registry total CPU time per repetition"),
                                      (user, "Registry user CPU time per repetition"), (kernel, "Registry kernel CPU time per repetition")):
                    m, b = values(by_arm["main"], metric), values(by_arm["bypass"], metric)
                    add(f"| {title} | {CASES[case]['concurrency']} | {label} | {pm(m)} | {len(m)} | {pm(b)} | {len(b)} | {change(m, b)} | "
                        f"{separated(by_arm['main'], by_arm['bypass'], metric)} |")
        add("")

    buffer_arms = [a for a in arms if a.startswith("buffer-")]
    covered = [(c, t) for c in CASES for t in TRANSPORT_TITLE if f"{c}-{t}" in cases and any(a in cases[f"{c}-{t}"] for a in buffer_arms)]
    if covered:
        add("## Smaller fileReader buffers against the bypass")
        add("")
        add("The buffer arms are main with only the cap of the `fileReader` read buffer changed (4 MiB on main). Seconds per repetition. "
            "\"Against the bypass\" is the change of the mean from the bypass to the arm; \"separated\" compares process lifetime means as above.")
        add("")
        add("| Transport | Case | Arm | n | Registry total CPU time (mean ± sample SD, s) | Against the bypass | Separated from the bypass | "
            "Registry user CPU time (mean ± sample SD, s) | Registry kernel CPU time (mean ± sample SD, s) | Wall time (mean ± sample SD, s) | "
            "Wall time against the bypass |")
        add("| --- | --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |")
        for case, transport in covered:
            by_arm = cases[f"{case}-{transport}"]
            for arm in ["main"] + buffer_arms + ["bypass"]:
                if arm not in by_arm:
                    continue
                v = values(by_arm[arm], total)
                compare = arm != "bypass" and "bypass" in by_arm
                against = change(values(by_arm["bypass"], total), v) if compare else ""
                sep = separated(by_arm["bypass"], by_arm[arm], total) if compare else ""
                wall_against = change(values(by_arm["bypass"], wall), values(by_arm[arm], wall)) if compare else ""
                kind = {"whole": ", whole blob", "range": "", "cold": ", cold page cache"}[CASES[case]["group"]]
                add(f"| {TRANSPORT_TITLE[transport]} | {CASES[case]['title'].split(' of a')[0]}{kind} | {arms[arm]['title']} | {len(v)} | {pm(v)} | {against} | {sep} | "
                    f"{pm(values(by_arm[arm], user))} | {pm(values(by_arm[arm], kernel))} | {pm(values(by_arm[arm], wall))} | {wall_against} |")
        not_covered = sorted({c for c in CASES if any(f"{c}-{t}" in cases for t in TRANSPORT_TITLE)} - {c for c, _ in covered})
        add("")
        if not_covered:
            add("Buffer arms were not measured for: " + ", ".join(not_covered) + ".")
            add("")

    add("## Distributions")
    add("")
    found = []
    for key, by_arm in cases.items():
        for arm, runs in by_arm.items():
            for metric, label in ((total, "registry total CPU time"), (wall, "wall time")):
                groups = two_groups(runs, metric)
                if groups:
                    found.append(f"- {key}, {arms[arm]['title']}, {label}: two groups, {len(groups['low'])} values with mean {statistics.mean(groups['low']):.3f} s and "
                                 f"{len(groups['high'])} values with mean {statistics.mean(groups['high']):.3f} s, gap {groups['gap']:.3f} s; the groups "
                                 + ("coincide with process lifetimes." if groups["follows_process_lifetimes"] else "do not follow process lifetimes."))
    add("Checked for every case and arm, registry total CPU time and wall time: the sorted values are split at their largest gap; a bimodal candidate is "
        "reported when both sides hold at least three values and the gap is at least four pooled within-side sample SDs and 0.03 s.")
    add("")
    lines.extend(found or ["No bimodal candidate."])
    add("")
    add("## Run")
    add("")
    add(f"{len(data['invocations'])} harness invocations, {data.get('measurement_wall_time_s', 'unfinished')} s from the first to the last. "
        "Per-repetition values: `data.json`; raw harness result files: `sessions/`; harness logs: `logs/`.")
    target = out / name
    with target.open("x") as output:
        output.write("\n".join(lines) + "\n")
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--quick", action="store_true", help="1 process lifetime x 2 repetitions per arm and case")
    parser.add_argument("--repo", default=str(ROOT / "gh-pr/distribution"), help="local clone of distribution/distribution holding both revisions")
    parser.add_argument("--base", default="d14ff2fb72913fd3692932bb4656421e2ba7b6e9", help="upstream main revision (arm main)")
    parser.add_argument("--bypass", default="9ccd294c670d70a49b963d71edd6dbfe877362b1", help="bypass revision; '' to leave the arm out")
    parser.add_argument("--buffer-caps-kib", default="32,256,1024", help="fileReader buffer caps for the buffer arms, in KiB; '' for none")
    parser.add_argument("--cases", default=",".join(CASES), help="cases to measure (default: all): " + ", ".join(CASES))
    parser.add_argument("--buffer-cases", default=DEFAULT_BUFFER_CASES, help="cases in which the buffer arms are measured")
    parser.add_argument("--transports", default="http,tls")
    parser.add_argument("--lifetimes", type=int, help="registry process lifetimes per arm and case (default 3; quick 1)")
    parser.add_argument("--repetitions", type=int, help="repetitions per process lifetime (default 5; quick 2)")
    parser.add_argument("--go-version", default="1.26.10")
    parser.add_argument("--go", default="go", help="go command used to select the toolchain")
    parser.add_argument("--go-mod-cache", default=str(HERE / "work/go-mod-cache"), help="module cache that holds or receives the Go toolchain")
    parser.add_argument("--work-dir", default=str(HERE / "work/filereader-bypass"), help="builds, blobs and registry storage (reused between runs)")
    parser.add_argument("--out", help="result directory (default: repro/filereader-bypass-<UTC time>)")
    parser.add_argument("--foreign-load-threshold", type=float, default=0.2,
                        help="flag a repetition when this fraction of the pinned CPUs' busy time (and more than 0.3 s) is neither registry nor client")
    parser.add_argument("--report-only", metavar="DIR", help="write a report from DIR/data.json instead of measuring")
    parser.add_argument("--report-name", default="report.md")
    args = parser.parse_args()
    if args.report_only:
        print(report(Path(args.report_only).resolve(), args.report_name))
        return
    out = Measurement(args).run()
    target = report(out, args.report_name)
    print(target.read_text())
    log(f"report: {target}")


if __name__ == "__main__":
    main()
