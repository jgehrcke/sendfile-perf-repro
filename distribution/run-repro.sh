#!/bin/sh
set -eu

# Local repro for distribution registry range GET sendfile behavior.
#
# Assumed tools: sh, git, curl, and a Go toolchain. Go is required because this
# script builds github.com/distribution/distribution locally. No container
# runtime, Docker CLI, package manager, or load-testing tool is used.

log() {
	printf '%s\n' "==> $*"
}

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

utc_timestamp() {
	date -u '+%Y%m%dT%H%M%SZ'
}

safe_rm_rf() {
	case "$1" in
		"$WORK_DIR"/*) rm -rf "$1" ;;
		*) die "refusing to remove path outside WORK_DIR: $1" ;;
	esac
}

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

Options:
  -x, --concurrency N      concurrent in-flight GET range responses (default: 10)
  -n, --requests N         timed GET range requests: auto or positive integer (default: auto)
  -c, --chunk-mib N        chunk size C in MiB (default: 32)
      --repeats N          repeat each comparison N times (default: 6)
      --sweep              run a small parameter sweep instead of one comparison
      --auto-target-seconds N
                          target measured seconds for auto N (default: 1.0)
      --numa-pin MODE      required CPU/memory pinning (default: same-socket)
      --loopback-net MODE  network of the measured processes (default: isolated)
      --blob-bytes N       serve raw blobs of N bytes instead of the image layer of LAYER_SIZE_MB
      --blobs N            number of distinct blobs with --blob-bytes; request i gets blob i mod N (default: 1)
      --whole-blob         GET whole blobs without a Range header instead of chunk-sized ranges
      --cold-cache         before every repetition drop each blob file from the page cache
                          (posix_fadvise, no root) and fail if pages stay resident; no warmup requests
      --lifetimes N        registry process lifetimes per variant, alternating between variants (default: 1)
      --variants WHICH     registry builds to measure: both (default), unpatched or patched
  -h, --help               show this help

NUMA pinning modes:
  same-socket              pin registry/client to disjoint CPU sets on one node; fail if pinning cannot be established
  cross-socket             pin registry and client to different NUMA nodes; require at least two nodes
  Pinning is mandatory for all measurements, including HTTP, TLS, and diagnostics.

Loopback network modes:
  isolated                 registry and load client run in a private network namespace whose loopback has no
                           netfilter rules; fail if it cannot be established and verified. Needs no root and
                           changes nothing on the host (unshare --user --map-root-user --net).
  host                     use the host's loopback. Netfilter rules there add per-packet CPU time that depends
                           on the host's configuration; only for showing that effect.

Environment:
  PATCH_FILE, REGISTRY_REF, REGISTRY_REPO_URL, REGISTRY_PORT, REGISTRY_PORT_RANGE_START,
  REGISTRY_PORT_RANGE_END, WORK_DIR, GO_BIN, GO_BUILD_FLAGS
  REPEATS, SWEEP_CHUNK_MIBS, SWEEP_CONCURRENCIES, SWEEP_REQUESTS,
  SWEEP_AUTO_TARGET_SECONDS,
  AUTO_N_TARGET_SECONDS
  NUMA_PIN, LOOPBACK_NET, REGISTRY_NUMA_NODE, CLIENT_NUMA_NODE,
  REGISTRY_CPU_LIST, CLIENT_CPU_LIST
  BLOB_BYTES, BLOB_COUNT, WHOLE_BLOB, COLD_CACHE, LIFETIMES, VARIANTS
  With --lifetimes above 1 or a single variant, the results are the JSON files of the session;
  the textual comparison at the end is skipped.
  Sweep grid is configured with SWEEP_CHUNK_MIBS, SWEEP_CONCURRENCIES,
  SWEEP_REQUESTS, and SWEEP_AUTO_TARGET_SECONDS.
  SWEEP_REQUESTS default: auto; SWEEP_AUTO_TARGET_SECONDS default:
  AUTO_N_TARGET_SECONDS.
  GOTOOLCHAIN defaults to go1.27.1 (latest stable release checked 2026-10-06).
  REGISTRY_TLS: both (default), 0 (HTTP only), or 1 (TLS only).
  Both transports use HTTP/1.1, with separate result directories.
  Default port range when REGISTRY_PORT is unset: 55300-55399
EOF
}

is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) [ "$1" -gt 0 ] ;;
	esac
}

is_numa_node_id() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

is_positive_number() {
	case "$1" in
		''|*[!0123456789.]*|*.*.*) return 1 ;;
	esac
	case "$1" in
		*.*)
			num_int=${1%%.*}
			num_frac=${1#*.}
			case "$num_int" in ''|*[!0123456789]*) return 1 ;; esac
			case "$num_frac" in ''|*[!0123456789]*) return 1 ;; esac
			if is_positive_int "$num_int"; then
				return 0
			fi
			case "$num_frac" in *[123456789]*) return 0 ;; esac
			return 1
			;;
		*) is_positive_int "$1" ;;
	esac
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH_FILE=${PATCH_FILE:-"$SCRIPT_DIR/../distribution-sendfile-range-upstreamable.patch"}
WORK_DIR=${WORK_DIR:-"$SCRIPT_DIR/work"}
WORK_DIR=$(mkdir -p "$WORK_DIR" && CDPATH= cd -- "$WORK_DIR" && pwd)

REGISTRY_REPO_URL=${REGISTRY_REPO_URL:-https://github.com/distribution/distribution.git}
REGISTRY_REF=${REGISTRY_REF:-main}
REGISTRY_BUILD_PKG=${REGISTRY_BUILD_PKG:-./cmd/registry}
GO_BIN=${GO_BIN:-go}
GO_BUILD_FLAGS=${GO_BUILD_FLAGS:--trimpath}
GOTOOLCHAIN=${GOTOOLCHAIN:-go1.27.1}
# Keep downloaded toolchains/dependencies inside the benchmark workspace.
GOMODCACHE=${GOMODCACHE:-"$WORK_DIR/go-mod-cache"}
export GOTOOLCHAIN GOMODCACHE
# Compare HTTP/1.1 in both arms; preserve other caller-supplied Go settings.
case ",${GODEBUG:-}," in
	*,http2client=0,*) ;;
	*) GODEBUG="${GODEBUG:+$GODEBUG,}http2client=0" ;;
esac
export GODEBUG

REGISTRY_HOST=${REGISTRY_HOST:-127.0.0.1}
REGISTRY_TLS=${REGISTRY_TLS:-both}
case "$REGISTRY_TLS" in
	both) TRANSPORTS="http tls" ;;
	0) TRANSPORTS="http" ;;
	1) TRANSPORTS="tls" ;;
	*) die "REGISTRY_TLS must be both, 0, or 1" ;;
esac
REGISTRY_BASE_URL=
REGISTRY_PORT=${REGISTRY_PORT:-}
REGISTRY_PORT_RANGE_START=${REGISTRY_PORT_RANGE_START:-55300}
REGISTRY_PORT_RANGE_END=${REGISTRY_PORT_RANGE_END:-55399}
IMAGE_REPO=${IMAGE_REPO:-repro/sendfile-range}

LAYER_SIZE_MB=${LAYER_SIZE_MB:-512}
CHUNK_SIZE_MIB=${CHUNK_SIZE_MIB:-32}
RANGE_SIZE_BYTES=
REQUESTS=${REQUESTS:-auto}
CONCURRENCY=${CONCURRENCY:-10}
REPEATS=${REPEATS:-6}
SWEEP=${SWEEP:-0}
SWEEP_CHUNK_MIBS=${SWEEP_CHUNK_MIBS:-"1 4 16 64"}
SWEEP_CONCURRENCIES=${SWEEP_CONCURRENCIES:-"$CONCURRENCY"}
SWEEP_REQUESTS=${SWEEP_REQUESTS:-auto}
AUTO_N_TARGET_SECONDS=${AUTO_N_TARGET_SECONDS:-1.0}
SWEEP_AUTO_TARGET_SECONDS=${SWEEP_AUTO_TARGET_SECONDS:-}
NUMA_PIN=${NUMA_PIN:-same-socket}
LOOPBACK_NET=${LOOPBACK_NET:-isolated}
BLOB_BYTES=${BLOB_BYTES:-}
BLOB_COUNT=${BLOB_COUNT:-1}
WHOLE_BLOB=${WHOLE_BLOB:-0}
COLD_CACHE=${COLD_CACHE:-0}
LIFETIMES=${LIFETIMES:-1}
VARIANTS=${VARIANTS:-both}
REGISTRY_NUMA_NODE=${REGISTRY_NUMA_NODE:-}
CLIENT_NUMA_NODE=${CLIENT_NUMA_NODE:-}
REGISTRY_CPU_LIST=${REGISTRY_CPU_LIST:-}
CLIENT_CPU_LIST=${CLIENT_CPU_LIST:-}
NUMA_ACTIVE=0
NUMA_CPUSET_ACTIVE=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		-x|--concurrency)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			CONCURRENCY=$2
			shift 2
			;;
		--concurrency=*)
			CONCURRENCY=${1#*=}
			shift
			;;
		-n|--requests)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			REQUESTS=$2
			shift 2
			;;
		--requests=*)
			REQUESTS=${1#*=}
			shift
			;;
		-c|--chunk-mib)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			CHUNK_SIZE_MIB=$2
			shift 2
			;;
		--chunk-mib=*)
			CHUNK_SIZE_MIB=${1#*=}
			shift
			;;
		--repeats)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			REPEATS=$2
			shift 2
			;;
		--repeats=*)
			REPEATS=${1#*=}
			shift
			;;
		--sweep)
			SWEEP=1
			shift
			;;
		--auto-target-seconds)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			AUTO_N_TARGET_SECONDS=$2
			shift 2
			;;
		--auto-target-seconds=*)
			AUTO_N_TARGET_SECONDS=${1#*=}
			shift
			;;
		--numa-pin)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			NUMA_PIN=$2
			shift 2
			;;
		--numa-pin=*)
			NUMA_PIN=${1#*=}
			shift
			;;
		--loopback-net)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			LOOPBACK_NET=$2
			shift 2
			;;
		--loopback-net=*)
			LOOPBACK_NET=${1#*=}
			shift
			;;
		--blob-bytes)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			BLOB_BYTES=$2
			shift 2
			;;
		--blobs)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			BLOB_COUNT=$2
			shift 2
			;;
		--whole-blob)
			WHOLE_BLOB=1
			shift
			;;
		--cold-cache)
			COLD_CACHE=1
			shift
			;;
		--lifetimes)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			LIFETIMES=$2
			shift 2
			;;
		--variants)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			VARIANTS=$2
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

if [ -z "$SWEEP_AUTO_TARGET_SECONDS" ]; then
	SWEEP_AUTO_TARGET_SECONDS=$AUTO_N_TARGET_SECONDS
fi

is_positive_int "$CONCURRENCY" || die "concurrency must be a positive integer: $CONCURRENCY"
case "$REQUESTS" in
	auto) ;;
	*) is_positive_int "$REQUESTS" || die "requests must be auto or a positive integer: $REQUESTS" ;;
esac
is_positive_int "$REPEATS" || die "repeats must be a positive integer: $REPEATS"
case "$SWEEP_REQUESTS" in
	auto) ;;
	*) is_positive_int "$SWEEP_REQUESTS" || die "SWEEP_REQUESTS must be auto or a positive integer: $SWEEP_REQUESTS" ;;
esac
is_positive_number "$AUTO_N_TARGET_SECONDS" || die "AUTO_N_TARGET_SECONDS must be a positive number: $AUTO_N_TARGET_SECONDS"
sweep_auto_target_count=0
for sweep_auto_target_seconds in $SWEEP_AUTO_TARGET_SECONDS; do
	is_positive_number "$sweep_auto_target_seconds" || die "invalid SWEEP_AUTO_TARGET_SECONDS entry: $sweep_auto_target_seconds"
	sweep_auto_target_count=$((sweep_auto_target_count + 1))
done
[ "$sweep_auto_target_count" -gt 0 ] || die "SWEEP_AUTO_TARGET_SECONDS must contain at least one positive number"
export AUTO_N_TARGET_SECONDS
case "$NUMA_PIN" in
	same-socket|cross-socket) ;;
	*) die "measurements require CPU/memory pinning with disjoint client/server CPU sets; NUMA_PIN must be same-socket or cross-socket: $NUMA_PIN" ;;
esac
case "$LOOPBACK_NET" in
	isolated|host) ;;
	*) die "LOOPBACK_NET must be isolated (loopback without netfilter rules) or host: $LOOPBACK_NET" ;;
esac
is_positive_int "$LIFETIMES" || die "lifetimes must be a positive integer: $LIFETIMES"
is_positive_int "$BLOB_COUNT" || die "blobs must be a positive integer: $BLOB_COUNT"
if [ -n "$BLOB_BYTES" ]; then
	is_positive_int "$BLOB_BYTES" || die "blob bytes must be a positive integer: $BLOB_BYTES"
else
	[ "$BLOB_COUNT" = 1 ] || die "--blobs requires --blob-bytes"
fi
case "$WHOLE_BLOB$COLD_CACHE" in
	00|01|10|11) ;;
	*) die "WHOLE_BLOB and COLD_CACHE must be 0 or 1: $WHOLE_BLOB, $COLD_CACHE" ;;
esac
case "$VARIANTS" in
	both|unpatched|patched) ;;
	*) die "variants must be both, unpatched or patched: $VARIANTS" ;;
esac
if [ "$REQUESTS" = auto ] && { [ "$VARIANTS" != both ] || [ "$COLD_CACHE" = 1 ]; }; then
	die "a single variant and --cold-cache need a concrete --requests count: auto derives it from the unpatched warmup"
fi
if [ "$SWEEP" = 1 ] && { [ "$LIFETIMES" != 1 ] || [ "$VARIANTS" != both ] || [ "$COLD_CACHE" = 1 ]; }; then
	die "--sweep supports neither --lifetimes, --variants nor --cold-cache"
fi
is_positive_int "$CHUNK_SIZE_MIB" || die "chunk MiB must be a positive integer: $CHUNK_SIZE_MIB"
RANGE_SIZE_BYTES=$((CHUNK_SIZE_MIB * 1024 * 1024))

UPSTREAM_DIR="$WORK_DIR/upstream"
BUILD_SRC_ROOT="$WORK_DIR/build-src"
BIN_DIR="$WORK_DIR/bin"
RUN_DIR="$WORK_DIR/run"
IMAGE_DIR="$WORK_DIR/image"
STORAGE_DIR="$WORK_DIR/registry-storage"
RESULT_DIR="$WORK_DIR/results"
HELPER_GO="$WORK_DIR/repro-helper.go"
IMAGE_VARS="$IMAGE_DIR/image-vars.sh"

need_cmd git
need_cmd curl
need_cmd "$GO_BIN"

[ -f "$PATCH_FILE" ] || die "patch file not found: $PATCH_FILE"
[ "$(uname -s)" = "Linux" ] || die "this perf repro currently requires Linux /proc CPU accounting"

LAYER_SIZE_BYTES=$((LAYER_SIZE_MB * 1024 * 1024))
[ -z "$BLOB_BYTES" ] || LAYER_SIZE_BYTES=$BLOB_BYTES
[ "$WHOLE_BLOB" = 0 ] || RANGE_SIZE_BYTES=$LAYER_SIZE_BYTES
[ "$RANGE_SIZE_BYTES" -le "$LAYER_SIZE_BYTES" ] || die "chunk size C must be <= layer size: C=$RANGE_SIZE_BYTES layer=$LAYER_SIZE_BYTES"
if [ $((LAYER_SIZE_BYTES % RANGE_SIZE_BYTES)) -ne 0 ]; then
	log "chunk size C=$RANGE_SIZE_BYTES does not divide layer size $LAYER_SIZE_BYTES; final partial tail will not be sampled"
fi
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || printf '%s\n' 100)
case "$CLK_TCK" in
	''|*[!0-9]*) CLK_TCK=100 ;;
esac

mkdir -p "$BIN_DIR" "$RUN_DIR" "$IMAGE_DIR" "$STORAGE_DIR" "$RESULT_DIR"

write_helper() {
	cat > "$HELPER_GO" <<'GOEOF'
package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	manifestMediaType = "application/vnd.oci.image.manifest.v1+json"
	configMediaType   = "application/vnd.oci.image.config.v1+json"
	layerMediaType    = "application/vnd.oci.image.layer.v1.tar"
	defaultAutoTargetSeconds = 4.0
)

type descriptor struct {
	MediaType string `json:"mediaType"`
	Size      int64  `json:"size"`
	Digest    string `json:"digest"`
}

type manifest struct {
	SchemaVersion int          `json:"schemaVersion"`
	MediaType     string       `json:"mediaType"`
	Config        descriptor   `json:"config"`
	Layers        []descriptor `json:"layers"`
}

type imageConfig struct {
	Created      string            `json:"created"`
	Architecture string            `json:"architecture"`
	OS           string            `json:"os"`
	Config       map[string]string `json:"config"`
	RootFS       struct {
		Type    string   `json:"type"`
		DiffIDs []string `json:"diff_ids"`
	} `json:"rootfs"`
	History []struct {
		Created   string `json:"created"`
		CreatedBy string `json:"created_by"`
	} `json:"history"`
}

type result struct {
	Name                 string  `json:"name"`
	Requests             int64   `json:"requests"`
	WarmupRequests       int64   `json:"warmup_requests"`
	WarmupSeconds        float64 `json:"warmup_seconds"`
	WarmupRequestSeconds float64 `json:"warmup_request_seconds"`
	WarmupCoveredChunks  int64   `json:"warmup_covered_chunks"`
	WarmupCoveredAll     bool    `json:"warmup_covered_all_chunks"`
	Concurrency          int64   `json:"concurrency"`
	MaxIncomingResponses int64   `json:"max_incoming_responses"`
	RangeBytes           int64   `json:"range_bytes"`
	ChunkCount           int64   `json:"chunk_count"`
	TransferredBytes     int64   `json:"transferred_bytes"`
	WallSeconds          float64 `json:"wall_seconds"`
	RegistryCPUSeconds   float64 `json:"registry_cpu_seconds"`
	RegistryUserCPUSeconds   float64 `json:"registry_user_cpu_seconds"`
	RegistryKernelCPUSeconds float64 `json:"registry_kernel_cpu_seconds"`
	RegistryCPUOneCore   float64 `json:"registry_cpu_one_core_percent"`
	RegistryCPUHost      float64 `json:"registry_cpu_host_percent"`
	ThroughputMiBPerSec  float64 `json:"throughput_mib_per_sec"`
	RegistryCPUPerGiB    float64 `json:"registry_cpu_seconds_per_gib"`
	RegistryCPUTicks     uint64  `json:"registry_cpu_ticks"`
	RegistryUserCPUTicks   uint64  `json:"registry_user_cpu_ticks"`
	RegistryKernelCPUTicks uint64  `json:"registry_kernel_cpu_ticks"`
	HostLogicalCPUs      int     `json:"host_logical_cpus"`
	// Whole-blob GETs (no Range header) and the number of distinct blobs requested.
	WholeBlob bool `json:"whole_blob"`
	BlobCount int  `json:"blob_count"`
	// CPU time of this load client, and user+nice+system+irq+softirq time of the pinned CPUs, during the timed run.
	ClientCPUSeconds      float64 `json:"client_cpu_seconds"`
	PinnedCPUsBusySeconds float64 `json:"pinned_cpus_busy_seconds"`
	// With --cold-cache: pages of the blob files, and how many were in the page cache before and after the timed run.
	ColdCachePages               int64 `json:"cold_cache_pages"`
	ColdCacheResidentPagesBefore int64 `json:"cold_cache_resident_pages_before"`
	ColdCacheResidentPagesAfter  int64 `json:"cold_cache_resident_pages_after"`
	// CPU affinity, memory policy and network namespace of registry and client, read after the timed run.
	RegistryPlacement *placement `json:"registry_placement,omitempty"`
	ClientPlacement   *placement `json:"client_placement,omitempty"`
}

type placement struct {
	PID          int      `json:"pid"`
	Threads      int      `json:"threads"`
	CPUsAllowed  []string `json:"cpus_allowed"`
	NUMAPolicies []string `json:"numa_policies"`
	NetNamespace string   `json:"net_namespace"`
}

type cpuTicks struct {
	User   uint64
	Kernel uint64
}

type seriesStats struct {
	Mean   float64
	Stddev float64
	SEM    float64
	N      int
}

func (c cpuTicks) Total() uint64 {
	return c.User + c.Kernel
}

func usage() error {
	return fmt.Errorf("usage: %s image <image-dir> <target-layer-size-bytes> <vars-path> | blobs <dir> <bytes> <count> <list-path> | choose-port <start> <end> | port-free <port> | cleanup <port> <range-start> <range-end> <allowed-process-name>... | check-cmdline <pid> <expected-config> <allowed-process-name>... | warmup <name> <url> <pid> <payload-bytes> <range-bytes> <requests|auto> <concurrency> <out-json> | load <name> <url> <pid> <clk-tck> <payload-bytes> <range-bytes> <requests> <concurrency> <out-json> | load-repeated <name> <url> <pid> <clk-tck> <payload-bytes> <range-bytes> <requests|auto> <concurrency> <repeats> <out-json>... | result-requests <result-json> | compare <unpatched-json> <patched-json> | repeat-summary <unpatched-json> <patched-json>... | sweep-line <label> <auto-target-seconds> <unpatched-json> <patched-json> | sweep-summary <tsv> | sweep-best <tsv>", os.Args[0])
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) < 2 {
		return usage()
	}
	switch os.Args[1] {
	case "image":
		if len(os.Args) != 5 {
			return usage()
		}
		size, err := strconv.ParseInt(os.Args[3], 10, 64)
		if err != nil || size <= 0 {
			return fmt.Errorf("invalid target layer size: %s", os.Args[3])
		}
		return cmdImage(os.Args[2], size, os.Args[4])
	case "blobs":
		if len(os.Args) != 6 {
			return usage()
		}
		return cmdBlobs(os.Args[2], os.Args[3], os.Args[4], os.Args[5])
	case "choose-port":
		if len(os.Args) != 4 {
			return usage()
		}
		return cmdChoosePort(os.Args[2], os.Args[3])
	case "port-free":
		if len(os.Args) != 3 {
			return usage()
		}
		return cmdPortFree(os.Args[2])
	case "cleanup":
		if len(os.Args) < 6 {
			return usage()
		}
		return cmdCleanup(os.Args[2], os.Args[3], os.Args[4], os.Args[5:])
	case "check-cmdline":
		if len(os.Args) < 5 {
			return usage()
		}
		return cmdCheckCmdline(os.Args[2], os.Args[3], os.Args[4:])
	case "load":
		if len(os.Args) != 11 {
			return usage()
		}
		return cmdLoad(os.Args[2:])
	case "load-repeated":
		if len(os.Args) < 12 {
			return usage()
		}
		return cmdLoadRepeated(os.Args[2:])
	case "warmup":
		if len(os.Args) != 10 {
			return usage()
		}
		return cmdWarmup(os.Args[2:])
	case "result-requests":
		if len(os.Args) != 3 {
			return usage()
		}
		return cmdResultRequests(os.Args[2])
	case "compare":
		if len(os.Args) != 4 {
			return usage()
		}
		return cmdCompare(os.Args[2], os.Args[3])
	case "repeat-summary":
		if len(os.Args) < 4 || len(os.Args[2:])%2 != 0 {
			return usage()
		}
		return cmdRepeatSummary(os.Args[2:])
	case "sweep-line":
		if len(os.Args) != 6 {
			return usage()
		}
		return cmdSweepLine(os.Args[2], os.Args[3], os.Args[4], os.Args[5])
	case "sweep-summary":
		if len(os.Args) != 3 {
			return usage()
		}
		return cmdSweepSummary(os.Args[2])
	case "sweep-best":
		if len(os.Args) != 3 {
			return usage()
		}
		return cmdSweepBest(os.Args[2])
	default:
		return usage()
	}
}

func cmdImage(imageDir string, targetLayerSize int64, varsPath string) error {
	if err := os.MkdirAll(imageDir, 0o755); err != nil {
		return err
	}

	layerPath := filepath.Join(imageDir, "layer.tar")
	layerSizePath := filepath.Join(imageDir, "layer.target-size")
	needLayer := true
	if st, err := os.Stat(layerPath); err == nil && st.Size() == targetLayerSize {
		if b, err := os.ReadFile(layerSizePath); err == nil && strings.TrimSpace(string(b)) == strconv.FormatInt(targetLayerSize, 10) {
			needLayer = false
		}
	}
	if needLayer {
		fmt.Printf("generating OCI tar layer blob with target size %d bytes at %s\n", targetLayerSize, layerPath)
		if err := generateLayer(layerPath, targetLayerSize); err != nil {
			return err
		}
		if err := os.WriteFile(layerSizePath, []byte(strconv.FormatInt(targetLayerSize, 10)+"\n"), 0o644); err != nil {
			return err
		}
	}

	layerDigest, layerSize, err := digestFile(layerPath)
	if err != nil {
		return err
	}

	cfg := imageConfig{
		Created:      "1970-01-01T00:00:00Z",
		Architecture: "amd64",
		OS:           "linux",
		Config:       map[string]string{},
	}
	cfg.RootFS.Type = "layers"
	cfg.RootFS.DiffIDs = []string{layerDigest}
	cfg.History = append(cfg.History, struct {
		Created   string `json:"created"`
		CreatedBy string `json:"created_by"`
	}{
		Created:   "1970-01-01T00:00:00Z",
		CreatedBy: "sendfile range repro",
	})

	configPath := filepath.Join(imageDir, "config.json")
	if err := writeJSON(configPath, cfg); err != nil {
		return err
	}
	configDigest, configSize, err := digestFile(configPath)
	if err != nil {
		return err
	}

	mf := manifest{
		SchemaVersion: 2,
		MediaType:     manifestMediaType,
		Config: descriptor{
			MediaType: configMediaType,
			Size:      configSize,
			Digest:    configDigest,
		},
		Layers: []descriptor{{
			MediaType: layerMediaType,
			Size:      layerSize,
			Digest:    layerDigest,
		}},
	}

	manifestPath := filepath.Join(imageDir, "manifest.json")
	if err := writeJSON(manifestPath, mf); err != nil {
		return err
	}
	manifestDigest, manifestSize, err := digestFile(manifestPath)
	if err != nil {
		return err
	}

	tag := "layer-" + strings.TrimPrefix(layerDigest, "sha256:")[:16]
	vars := ""
	vars += "LAYER_FILE=" + shellQuote(layerPath) + "\n"
	vars += "LAYER_DIGEST=" + shellQuote(layerDigest) + "\n"
	vars += "LAYER_SIZE=" + shellQuote(strconv.FormatInt(layerSize, 10)) + "\n"
	vars += "CONFIG_FILE=" + shellQuote(configPath) + "\n"
	vars += "CONFIG_DIGEST=" + shellQuote(configDigest) + "\n"
	vars += "CONFIG_SIZE=" + shellQuote(strconv.FormatInt(configSize, 10)) + "\n"
	vars += "MANIFEST_FILE=" + shellQuote(manifestPath) + "\n"
	vars += "MANIFEST_DIGEST=" + shellQuote(manifestDigest) + "\n"
	vars += "MANIFEST_SIZE=" + shellQuote(strconv.FormatInt(manifestSize, 10)) + "\n"
	vars += "MANIFEST_MEDIA_TYPE=" + shellQuote(manifestMediaType) + "\n"
	vars += "CONFIG_MEDIA_TYPE=" + shellQuote(configMediaType) + "\n"
	vars += "LAYER_MEDIA_TYPE=" + shellQuote(layerMediaType) + "\n"
	vars += "IMAGE_TAG=" + shellQuote(tag) + "\n"

	tmpVars := varsPath + ".tmp"
	if err := os.WriteFile(tmpVars, []byte(vars), 0o644); err != nil {
		return err
	}
	return os.Rename(tmpVars, varsPath)
}

func generateLayer(path string, targetLayerSize int64) error {
	if targetLayerSize <= 1536 || targetLayerSize%512 != 0 {
		return fmt.Errorf("target tar layer size must be greater than 1536 bytes and divisible by 512: %d", targetLayerSize)
	}
	payloadSize := targetLayerSize - 1536
	tmp := path + ".tmp"
	_ = os.Remove(tmp)

	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	defer func() {
		_ = f.Close()
	}()

	tw := tar.NewWriter(f)
	epoch := time.Unix(0, 0).UTC()
	hdr := &tar.Header{
		Name:       "payload.bin",
		Mode:       0o644,
		Size:       payloadSize,
		ModTime:    epoch,
		AccessTime: epoch,
		ChangeTime: epoch,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		_ = os.Remove(tmp)
		return err
	}

	buf := make([]byte, 1024*1024)
	for i := range buf {
		buf[i] = byte((i * 31) + 17)
	}

	var written int64
	for written < payloadSize {
		n := int64(len(buf))
		if rem := payloadSize - written; rem < n {
			n = rem
		}
		if _, err := tw.Write(buf[:n]); err != nil {
			_ = os.Remove(tmp)
			return err
		}
		written += n
	}

	if err := tw.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	st, err := os.Stat(tmp)
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if st.Size() != targetLayerSize {
		_ = os.Remove(tmp)
		return fmt.Errorf("generated tar layer size %d, want %d", st.Size(), targetLayerSize)
	}
	return os.Rename(tmp, path)
}

func writeJSON(path string, v interface{}) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func digestFile(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()

	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil)), n, nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func parsePort(s string) (uint16, error) {
	port, err := strconv.ParseUint(s, 10, 16)
	if err != nil || port == 0 {
		return 0, fmt.Errorf("invalid port: %s", s)
	}
	return uint16(port), nil
}

func cmdChoosePort(startStr, endStr string) error {
	start, err := parsePort(startStr)
	if err != nil {
		return err
	}
	end, err := parsePort(endStr)
	if err != nil {
		return err
	}
	if start > end {
		return fmt.Errorf("invalid port range: %d > %d", start, end)
	}
	for port := start; port <= end; port++ {
		inodes, err := listenerInodesForPort(port)
		if err != nil {
			return err
		}
		if len(inodes) == 0 {
			fmt.Println(port)
			return nil
		}
		if port == 65535 {
			break
		}
	}
	return fmt.Errorf("no free listening port found in range %d-%d", start, end)
}

func cmdPortFree(portStr string) error {
	port, err := parsePort(portStr)
	if err != nil {
		return err
	}
	inodes, err := listenerInodesForPort(port)
	if err != nil {
		return err
	}
	if len(inodes) != 0 {
		return fmt.Errorf("port %d has a listening socket", port)
	}
	return nil
}

func cmdCleanup(portStr, rangeStartStr, rangeEndStr string, allowedNames []string) error {
	port, err := parsePort(portStr)
	if err != nil {
		return err
	}
	rangeStart, err := parsePort(rangeStartStr)
	if err != nil {
		return err
	}
	rangeEnd, err := parsePort(rangeEndStr)
	if err != nil {
		return err
	}
	if rangeStart > rangeEnd {
		return fmt.Errorf("invalid cleanup port range: %d > %d", rangeStart, rangeEnd)
	}
	if port < rangeStart || port > rangeEnd {
		return fmt.Errorf("refusing cleanup for port %d outside cleanup range %d-%d", port, rangeStart, rangeEnd)
	}
	allowed := map[string]bool{}
	for _, name := range allowedNames {
		allowed[filepath.Base(name)] = true
	}

	inodes, err := listenerInodesForPort(port)
	if err != nil {
		return err
	}
	if len(inodes) == 0 {
		return nil
	}

	entries, err := os.ReadDir("/proc")
	if err != nil {
		return err
	}
	self := os.Getpid()
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 || pid == self {
			continue
		}
		listens, err := processHasSocketInode(pid, inodes)
		if err != nil || !listens {
			continue
		}
		name, ok := allowedProcessName(pid, allowed)
		if !ok {
			continue
		}
		if err := terminateProcess(pid); err != nil {
			return err
		}
		fmt.Printf("stopped stale repro registry pid %d (%s) listening on port %d\n", pid, name, port)
	}
	return nil
}

func cmdCheckCmdline(pidStr, expectedConfig string, allowedNames []string) error {
	pid, err := strconv.Atoi(pidStr)
	if err != nil || pid <= 0 {
		return fmt.Errorf("invalid pid: %s", pidStr)
	}
	allowed := map[string]bool{}
	for _, name := range allowedNames {
		allowed[filepath.Base(name)] = true
	}
	name, ok := allowedProcessName(pid, allowed)
	if !ok {
		return fmt.Errorf("pid %d process name does not match allowed registry names", pid)
	}
	args, err := procArgs(pid)
	if err != nil {
		return err
	}
	hasServe := false
	hasConfig := false
	expectedConfig = filepath.Clean(expectedConfig)
	for _, arg := range args {
		if arg == "serve" {
			hasServe = true
		}
		if filepath.Clean(arg) == expectedConfig {
			hasConfig = true
		}
	}
	if !hasServe || !hasConfig {
		return fmt.Errorf("pid %d (%s) argv does not contain expected 'serve %s': %q", pid, name, expectedConfig, args)
	}
	return nil
}

func listenerInodesForPort(port uint16) (map[string]bool, error) {
	inodes := map[string]bool{}
	for _, path := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		if err := addListenerInodes(path, port, inodes); err != nil && !os.IsNotExist(err) {
			return nil, err
		}
	}
	return inodes, nil
}

func addListenerInodes(path string, port uint16, inodes map[string]bool) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := strings.Split(string(b), "\n")
	for _, line := range lines[1:] {
		fields := strings.Fields(line)
		if len(fields) < 10 || fields[3] != "0A" {
			continue
		}
		local := fields[1]
		idx := strings.LastIndex(local, ":")
		if idx < 0 {
			continue
		}
		p, err := strconv.ParseUint(local[idx+1:], 16, 16)
		if err != nil || uint16(p) != port {
			continue
		}
		inodes[fields[9]] = true
	}
	return nil
}

func procArgs(pid int) ([]string, error) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return nil, err
	}
	b = bytes.TrimRight(b, "\x00")
	if len(b) == 0 {
		return nil, fmt.Errorf("empty cmdline")
	}
	parts := bytes.Split(b, []byte{0})
	args := make([]string, 0, len(parts))
	for _, part := range parts {
		args = append(args, string(part))
	}
	return args, nil
}

func processHasSocketInode(pid int, inodes map[string]bool) (bool, error) {
	fdDir := fmt.Sprintf("/proc/%d/fd", pid)
	entries, err := os.ReadDir(fdDir)
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		target, err := os.Readlink(filepath.Join(fdDir, entry.Name()))
		if err != nil {
			continue
		}
		if strings.HasPrefix(target, "socket:[") && strings.HasSuffix(target, "]") {
			inode := strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]")
			if inodes[inode] {
				return true, nil
			}
		}
	}
	return false, nil
}

func allowedProcessName(pid int, allowed map[string]bool) (string, bool) {
	if args, err := procArgs(pid); err == nil && len(args) > 0 {
		name := filepath.Base(args[0])
		if allowed[name] {
			return name, true
		}
	}
	if target, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid)); err == nil {
		name := filepath.Base(target)
		if allowed[name] {
			return name, true
		}
	}
	if b, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid)); err == nil {
		name := strings.TrimSpace(string(b))
		if allowed[name] {
			return name, true
		}
	}
	return "", false
}

func terminateProcess(pid int) error {
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
		return err
	}
	for i := 0; i < 30; i++ {
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil && err != syscall.ESRCH {
		return err
	}
	return nil
}

func cmdWarmup(args []string) error {
	name := args[0]
	url := args[1]
	pid, err := strconv.Atoi(args[2])
	if err != nil || pid <= 0 {
		return fmt.Errorf("invalid pid: %s", args[2])
	}
	payloadBytes, err := strconv.ParseInt(args[3], 10, 64)
	if err != nil || payloadBytes <= 0 {
		return fmt.Errorf("invalid payload bytes: %s", args[3])
	}
	rangeBytes, err := strconv.ParseInt(args[4], 10, 64)
	if err != nil || rangeBytes <= 0 {
		return fmt.Errorf("invalid range bytes: %s", args[4])
	}
	if rangeBytes > payloadBytes {
		rangeBytes = payloadBytes
	}
	chunkCount := payloadBytes / rangeBytes
	if chunkCount < 1 {
		return fmt.Errorf("payload bytes %d are smaller than range bytes %d", payloadBytes, rangeBytes)
	}
	requestArg := args[5]
	requests := int64(0)
	if requestArg != "auto" {
		var err error
		requests, err = strconv.ParseInt(requestArg, 10, 64)
		if err != nil || requests <= 0 {
			return fmt.Errorf("invalid requests: %s (want auto or positive integer)", requestArg)
		}
	}
	concurrency, err := strconv.ParseInt(args[6], 10, 64)
	if err != nil || concurrency <= 0 {
		return fmt.Errorf("invalid concurrency: %s", args[6])
	}
	warmupRequests := chunkCount
	outPath := args[7]

	client := loadHTTPClient(concurrency)

	if _, err := procCPUTicks(pid); err != nil {
		return fmt.Errorf("registry pid %d is not readable before warmup; registry may have exited: %w", pid, err)
	}

	var warmupSeconds float64
	var warmupRequestSeconds float64
	fmt.Printf("%s: warming page cache and connections with %d range GETs, one per chunk\n", name, warmupRequests)
	warmupStart := time.Now()
	if _, err := runRequests(client, url, payloadBytes, rangeBytes, warmupRequests, concurrency, "sequential"); err != nil {
		return fmt.Errorf("warmup failed: %w", err)
	}
	warmupRequestSeconds = time.Since(warmupStart).Seconds()
	if requests == 0 {
		autoTargetSeconds, err := autoNTargetSeconds()
		if err != nil {
			return err
		}
		requests = dynamicRequestCount(warmupRequests, warmupRequestSeconds, autoTargetSeconds)
		fmt.Printf("%s: selected timed request count N=%d from warmup %.3fs (%d requests), target about %.3fs, rounded up to next 1000\n", name, requests, warmupRequestSeconds, warmupRequests, autoTargetSeconds)
	}
	time.Sleep(300 * time.Millisecond)
	warmupSeconds = time.Since(warmupStart).Seconds()

	r := result{
		Name:                 name,
		Requests:             requests,
		WarmupRequests:       warmupRequests,
		WarmupSeconds:        warmupSeconds,
		WarmupRequestSeconds: warmupRequestSeconds,
		WarmupCoveredChunks:  chunkCount,
		WarmupCoveredAll:     true,
		Concurrency:          concurrency,
		RangeBytes:           rangeBytes,
		ChunkCount:           chunkCount,
		HostLogicalCPUs:      runtime.NumCPU(),
	}
	if err := writeResult(outPath, r); err != nil {
		return err
	}

	fmt.Printf("%s: warmup=%.3fs selected_requests=%d concurrency=%d chunks=%d covered_all=true\n",
		name, r.WarmupSeconds, r.Requests, r.Concurrency, r.WarmupCoveredChunks)
	return nil
}

func cmdLoad(args []string) error {
	name := args[0]
	url := args[1]
	pid, err := strconv.Atoi(args[2])
	if err != nil || pid <= 0 {
		return fmt.Errorf("invalid pid: %s", args[2])
	}
	clkTck, err := strconv.ParseFloat(args[3], 64)
	if err != nil || clkTck <= 0 {
		return fmt.Errorf("invalid clk-tck: %s", args[3])
	}
	payloadBytes, err := strconv.ParseInt(args[4], 10, 64)
	if err != nil || payloadBytes <= 0 {
		return fmt.Errorf("invalid payload bytes: %s", args[4])
	}
	rangeBytes, err := strconv.ParseInt(args[5], 10, 64)
	if err != nil || rangeBytes <= 0 {
		return fmt.Errorf("invalid range bytes: %s", args[5])
	}
	if rangeBytes > payloadBytes {
		rangeBytes = payloadBytes
	}
	chunkCount := payloadBytes / rangeBytes
	if chunkCount < 1 {
		return fmt.Errorf("payload bytes %d are smaller than range bytes %d", payloadBytes, rangeBytes)
	}
	if args[6] == "auto" {
		return fmt.Errorf("timed load requires a concrete request count; run warmup first")
	}
	requests, err := strconv.ParseInt(args[6], 10, 64)
	if err != nil || requests <= 0 {
		return fmt.Errorf("invalid requests: %s (want positive integer)", args[6])
	}
	concurrency, err := strconv.ParseInt(args[7], 10, 64)
	if err != nil || concurrency <= 0 {
		return fmt.Errorf("invalid concurrency: %s", args[7])
	}
	outPath := args[8]

	client := loadHTTPClient(concurrency)
	return runTimedLoad(name, client, url, pid, clkTck, payloadBytes, rangeBytes, requests, concurrency, outPath)
}

func cmdLoadRepeated(args []string) error {
	name := args[0]
	url := args[1]
	pid, err := strconv.Atoi(args[2])
	if err != nil || pid <= 0 {
		return fmt.Errorf("invalid pid: %s", args[2])
	}
	clkTck, err := strconv.ParseFloat(args[3], 64)
	if err != nil || clkTck <= 0 {
		return fmt.Errorf("invalid clk-tck: %s", args[3])
	}
	payloadBytes, err := strconv.ParseInt(args[4], 10, 64)
	if err != nil || payloadBytes <= 0 {
		return fmt.Errorf("invalid payload bytes: %s", args[4])
	}
	rangeBytes, err := strconv.ParseInt(args[5], 10, 64)
	if err != nil || rangeBytes <= 0 {
		return fmt.Errorf("invalid range bytes: %s", args[5])
	}
	if rangeBytes > payloadBytes {
		rangeBytes = payloadBytes
	}
	chunkCount := payloadBytes / rangeBytes
	if chunkCount < 1 {
		return fmt.Errorf("payload bytes %d are smaller than range bytes %d", payloadBytes, rangeBytes)
	}
	requestArg := args[6]
	requests := int64(0)
	if requestArg != "auto" {
		requests, err = strconv.ParseInt(requestArg, 10, 64)
		if err != nil || requests <= 0 {
			return fmt.Errorf("invalid requests: %s (want auto or positive integer)", requestArg)
		}
	}
	concurrency, err := strconv.ParseInt(args[7], 10, 64)
	if err != nil || concurrency <= 0 {
		return fmt.Errorf("invalid concurrency: %s", args[7])
	}
	repeats, err := strconv.Atoi(args[8])
	if err != nil || repeats <= 0 {
		return fmt.Errorf("invalid repeats: %s", args[8])
	}
	outPaths := args[9:]
	if len(outPaths) != repeats {
		return fmt.Errorf("got %d output paths, want repeats=%d", len(outPaths), repeats)
	}

	client := loadHTTPClient(concurrency)
	if _, err := procCPUTicks(pid); err != nil {
		return fmt.Errorf("registry pid %d is not readable before warmup; registry may have exited: %w", pid, err)
	}

	warmupRequests := chunkCount * int64(len(strings.Split(url, ",")))
	if warmupRequests < concurrency {
		warmupRequests = concurrency
	}
	warmupStart := time.Now()
	warmupRequestSeconds := 0.0
	if len(coldCacheFiles()) > 0 {
		if requests == 0 {
			return fmt.Errorf("a cold page cache needs a concrete request count")
		}
		warmupRequests = 0
		fmt.Printf("%s: cold page cache: no warmup requests\n", name)
	} else {
		fmt.Printf("%s: warming page cache and connections with %d GETs: every chunk of every blob, at least one per connection\n", name, warmupRequests)
		if _, err := runRequests(client, url, payloadBytes, rangeBytes, warmupRequests, concurrency, "sequential"); err != nil {
			return fmt.Errorf("warmup failed: %w", err)
		}
		warmupRequestSeconds = time.Since(warmupStart).Seconds()
	}
	if requests == 0 {
		autoTargetSeconds, err := autoNTargetSeconds()
		if err != nil {
			return err
		}
		requests = dynamicRequestCount(warmupRequests, warmupRequestSeconds, autoTargetSeconds)
		fmt.Printf("%s: selected timed request count N=%d from warmup %.3fs (%d requests), target about %.3fs, rounded up to next 1000\n", name, requests, warmupRequestSeconds, warmupRequests, autoTargetSeconds)
	}
	time.Sleep(300 * time.Millisecond)
	warmupSeconds := time.Since(warmupStart).Seconds()
	fmt.Printf("%s: warmup=%.3fs selected_requests=%d concurrency=%d chunks=%d covered_all=true\n",
		name, warmupSeconds, requests, concurrency, chunkCount)

	for i, outPath := range outPaths {
		runName := fmt.Sprintf("%s-r%d", name, i+1)
		fmt.Printf("%s: starting timed repetition %d of %d\n", name, i+1, len(outPaths))
		if err := runTimedLoad(runName, client, url, pid, clkTck, payloadBytes, rangeBytes, requests, concurrency, outPath); err != nil {
			return err
		}
	}
	return nil
}

func runTimedLoad(name string, client *http.Client, url string, pid int, clkTck float64, payloadBytes, rangeBytes, requests, concurrency int64, outPath string) error {
	chunkCount := payloadBytes / rangeBytes
	coldFiles := coldCacheFiles()
	var coldPages, coldResidentAfter int64
	for _, path := range coldFiles {
		pages, err := dropFromPageCache(path)
		if err != nil {
			return err
		}
		coldPages += pages
	}
	busyStart, err := pinnedCPUBusyTicks()
	if err != nil {
		return err
	}
	clientStart, err := selfCPUSeconds()
	if err != nil {
		return err
	}
	startTicks, err := procCPUTicks(pid)
	if err != nil {
		return fmt.Errorf("registry pid %d is not readable before measured run; registry may have exited: %w", pid, err)
	}
	start := time.Now()
	maxIncomingResponses, err := runRequests(client, url, payloadBytes, rangeBytes, requests, concurrency, "random")
	if err != nil {
		return err
	}
	wall := time.Since(start).Seconds()
	endTicks, err := procCPUTicks(pid)
	if err != nil {
		return fmt.Errorf("registry pid %d is not readable after measured run; registry may have exited: %w", pid, err)
	}
	clientEnd, err := selfCPUSeconds()
	if err != nil {
		return err
	}
	busyEnd, err := pinnedCPUBusyTicks()
	if err != nil {
		return err
	}
	for _, path := range coldFiles {
		resident, _, err := residentPages(path)
		if err != nil {
			return fmt.Errorf("reading page cache residency of %s: %w", path, err)
		}
		coldResidentAfter += resident
	}
	registryPlacement, err := readPlacement(pid)
	if err != nil {
		return fmt.Errorf("reading placement of registry pid %d: %w", pid, err)
	}
	clientPlacement, err := readPlacement(os.Getpid())
	if err != nil {
		return fmt.Errorf("reading placement of the load client: %w", err)
	}

	userTicks := endTicks.User - startTicks.User
	kernelTicks := endTicks.Kernel - startTicks.Kernel
	totalTicks := userTicks + kernelTicks
	userCPUSeconds := float64(userTicks) / clkTck
	kernelCPUSeconds := float64(kernelTicks) / clkTck
	totalCPUSeconds := float64(totalTicks) / clkTck
	transferred := requests * rangeBytes
	throughput := (float64(transferred) / (1024 * 1024)) / wall
	oneCorePct := (totalCPUSeconds / wall) * 100
	hostPct := oneCorePct / float64(runtime.NumCPU())
	cpuPerGiB := totalCPUSeconds / (float64(transferred) / (1024 * 1024 * 1024))

	r := result{
		Name:                 name,
		Requests:             requests,
		Concurrency:          concurrency,
		MaxIncomingResponses: maxIncomingResponses,
		RangeBytes:           rangeBytes,
		ChunkCount:           chunkCount,
		TransferredBytes:     transferred,
		WallSeconds:          wall,
		RegistryCPUSeconds:   totalCPUSeconds,
		RegistryUserCPUSeconds:   userCPUSeconds,
		RegistryKernelCPUSeconds: kernelCPUSeconds,
		RegistryCPUOneCore:   oneCorePct,
		RegistryCPUHost:      hostPct,
		ThroughputMiBPerSec:  throughput,
		RegistryCPUPerGiB:    cpuPerGiB,
		RegistryCPUTicks:     totalTicks,
		RegistryUserCPUTicks:   userTicks,
		RegistryKernelCPUTicks: kernelTicks,
		HostLogicalCPUs:      runtime.NumCPU(),
		WholeBlob:             os.Getenv("REPRO_WHOLE_BLOB") == "1",
		BlobCount:             len(strings.Split(url, ",")),
		ClientCPUSeconds:      clientEnd - clientStart,
		PinnedCPUsBusySeconds: float64(busyEnd-busyStart) / clkTck,
		ColdCachePages:               coldPages,
		ColdCacheResidentPagesBefore: 0, // dropFromPageCache fails otherwise
		ColdCacheResidentPagesAfter:  coldResidentAfter,
		RegistryPlacement:     &registryPlacement,
		ClientPlacement:       &clientPlacement,
	}
	if err := writeResult(outPath, r); err != nil {
		return err
	}

	if len(coldFiles) > 0 {
		fmt.Printf("%s: cold page cache: %d blob files, %d pages, resident before=0 after=%d\n", name, len(coldFiles), coldPages, coldResidentAfter)
	}
	fmt.Printf("%s: requests=%d concurrency=%d max_incoming_responses=%d wall=%.3fs registry_cpu_total=%.3fs registry_cpu_user=%.3fs registry_cpu_kernel=%.3fs cpu(one-core)=%.1f%% cpu(host)=%.2f%% throughput=%.1f MiB/s cpu_per_GiB=%.3fs\n",
		name, r.Requests, r.Concurrency, r.MaxIncomingResponses, r.WallSeconds, r.RegistryCPUSeconds, r.RegistryUserCPUSeconds, r.RegistryKernelCPUSeconds, r.RegistryCPUOneCore, r.RegistryCPUHost, r.ThroughputMiBPerSec, r.RegistryCPUPerGiB)
	return nil
}

func loadHTTPClient(concurrency int64) *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:               http.ProxyFromEnvironment,
			DisableCompression:  true,
			MaxIdleConns:        int(concurrency * 2),
			MaxIdleConnsPerHost: int(concurrency * 2),
			MaxConnsPerHost:     int(concurrency),
			IdleConnTimeout:     30 * time.Second,
		},
		Timeout: 120 * time.Second,
	}
}

func writeResult(outPath string, r result) error {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	return os.WriteFile(outPath, b, 0o644)
}

func autoNTargetSeconds() (float64, error) {
	raw := strings.TrimSpace(os.Getenv("AUTO_N_TARGET_SECONDS"))
	if raw == "" {
		return defaultAutoTargetSeconds, nil
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil || v <= 0 {
		return 0, fmt.Errorf("AUTO_N_TARGET_SECONDS must be a positive number of seconds: %q", raw)
	}
	return v, nil
}

func dynamicRequestCount(warmupRequests int64, warmupSeconds, targetSeconds float64) int64 {
	if warmupRequests <= 0 || warmupSeconds <= 0 {
		return 1000
	}
	estimated := int64(math.Ceil((targetSeconds * float64(warmupRequests)) / warmupSeconds))
	rounded := ((estimated + 999) / 1000) * 1000
	if rounded < 1000 {
		return 1000
	}
	return rounded
}

func runRequests(client *http.Client, url string, payloadBytes, rangeBytes, requests, concurrency int64, pattern string) (int64, error) {
	var next uint64
	var activeResponses int64
	var maxIncomingResponses int64
	errCh := make(chan error, 1)
	var wg sync.WaitGroup
	urls := strings.Split(url, ",")
	blobs := int64(len(urls))
	whole := os.Getenv("REPRO_WHOLE_BLOB") == "1"

	for w := int64(0); w < concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int64(atomic.AddUint64(&next, 1)) - 1
				if i >= requests {
					return
				}
				// Request i gets blob i mod blobs; the sequential pattern then walks the chunks of each blob.
				chunkIndex := i
				if pattern != "random" {
					chunkIndex = i / blobs
				}
				start, end := byteRange(chunkIndex, payloadBytes, rangeBytes, pattern)
				if err := doRangeRequest(client, urls[i%blobs], start, end, rangeBytes, whole, &activeResponses, &maxIncomingResponses); err != nil {
					select {
					case errCh <- err:
					default:
					}
					return
				}
			}
		}()
	}

	wg.Wait()
	select {
	case err := <-errCh:
		return maxIncomingResponses, err
	default:
		return maxIncomingResponses, nil
	}
}

func byteRange(i, payloadBytes, rangeBytes int64, pattern string) (int64, int64) {
	chunkCount := payloadBytes / rangeBytes
	if chunkCount <= 1 {
		return 0, rangeBytes - 1
	}
	chunk := i % chunkCount
	if pattern == "random" {
		chunk = int64(splitmix64(uint64(i)+0x9e3779b97f4a7c15) % uint64(chunkCount))
	}
	start := chunk * rangeBytes
	return start, start + rangeBytes - 1
}

func minInt64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func splitmix64(x uint64) uint64 {
	x += 0x9e3779b97f4a7c15
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb
	return x ^ (x >> 31)
}

func doRangeRequest(client *http.Client, url string, start, end, wantBytes int64, whole bool, activeResponses, maxIncomingResponses *int64) error {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}
	wantStatus := http.StatusOK
	if !whole {
		wantStatus = http.StatusPartialContent
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
	}
	req.Header.Set("Accept-Encoding", "identity")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.ProtoMajor != 1 || resp.ProtoMinor != 1 {
		return fmt.Errorf("GET range used %s, want HTTP/1.1", resp.Proto)
	}
	active := atomic.AddInt64(activeResponses, 1)
	updateMaxInt64(maxIncomingResponses, active)
	defer atomic.AddInt64(activeResponses, -1)

	n, copyErr := io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != wantStatus {
		return fmt.Errorf("GET range %d-%d (whole blob: %t) got status %d after %d bytes, want %d", start, end, whole, resp.StatusCode, n, wantStatus)
	}
	if copyErr != nil {
		return copyErr
	}
	if n != wantBytes {
		return fmt.Errorf("GET range %d-%d returned %d bytes, want %d", start, end, n, wantBytes)
	}
	return nil
}

func updateMaxInt64(addr *int64, value int64) {
	for {
		current := atomic.LoadInt64(addr)
		if value <= current {
			return
		}
		if atomic.CompareAndSwapInt64(addr, current, value) {
			return
		}
	}
}

// cmdBlobs writes count deterministic blobs of the given size and a list file with one "digest path" line per blob.
// Existing blobs with a recorded digest are kept.
func cmdBlobs(dir, sizeStr, countStr, listPath string) error {
	size, err := strconv.ParseInt(sizeStr, 10, 64)
	if err != nil || size <= 0 {
		return fmt.Errorf("invalid blob size: %s", sizeStr)
	}
	count, err := strconv.Atoi(countStr)
	if err != nil || count <= 0 {
		return fmt.Errorf("invalid blob count: %s", countStr)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	list := ""
	for i := 0; i < count; i++ {
		path := filepath.Join(dir, fmt.Sprintf("blob-%d-%d.bin", size, i))
		digest := ""
		if st, err := os.Stat(path); err == nil && st.Size() == size {
			if b, err := os.ReadFile(path + ".sha256"); err == nil {
				digest = strings.TrimSpace(string(b))
			}
		}
		if digest == "" {
			fmt.Printf("generating blob %d of %d with %d bytes at %s\n", i+1, count, size, path)
			f, err := os.Create(path + ".tmp")
			if err != nil {
				return err
			}
			h := sha256.New()
			w := io.MultiWriter(f, h)
			buf := make([]byte, 1024*1024)
			state := uint64(size)*0x9e3779b97f4a7c15 + uint64(i)
			for written := int64(0); written < size; {
				for j := 0; j+8 <= len(buf); j += 8 {
					state = splitmix64(state)
					for k := 0; k < 8; k++ {
						buf[j+k] = byte(state >> (8 * k))
					}
				}
				n := minInt64(int64(len(buf)), size-written)
				if _, err := w.Write(buf[:n]); err != nil {
					f.Close()
					return err
				}
				written += n
			}
			if err := f.Close(); err != nil {
				return err
			}
			digest = "sha256:" + hex.EncodeToString(h.Sum(nil))
			if err := os.Rename(path+".tmp", path); err != nil {
				return err
			}
			if err := os.WriteFile(path+".sha256", []byte(digest+"\n"), 0o644); err != nil {
				return err
			}
		}
		list += digest + " " + path + "\n"
	}
	if err := os.WriteFile(listPath+".tmp", []byte(list), 0o644); err != nil {
		return err
	}
	return os.Rename(listPath+".tmp", listPath)
}

func coldCacheFiles() []string {
	if v := os.Getenv("REPRO_COLD_FILES"); v != "" {
		return strings.Split(v, ",")
	}
	return nil
}

// residentPages returns how many pages of the file are in the page cache, and the number of pages of the file.
func residentPages(path string) (int64, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return 0, 0, err
	}
	if st.Size() == 0 {
		return 0, 0, nil
	}
	m, err := syscall.Mmap(int(f.Fd()), 0, int(st.Size()), syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return 0, 0, fmt.Errorf("mmap: %w", err)
	}
	defer syscall.Munmap(m)
	pageSize := int64(os.Getpagesize())
	vec := make([]byte, (st.Size()+pageSize-1)/pageSize)
	if _, _, errno := syscall.Syscall(syscall.SYS_MINCORE, uintptr(unsafe.Pointer(&m[0])), uintptr(len(m)), uintptr(unsafe.Pointer(&vec[0]))); errno != 0 {
		return 0, 0, fmt.Errorf("mincore: %w", errno)
	}
	var resident int64
	for _, b := range vec {
		resident += int64(b & 1)
	}
	return resident, int64(len(vec)), nil
}

// dropFromPageCache removes the file from the page cache without root and fails if any page stays resident.
// It returns the number of pages of the file.
func dropFromPageCache(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, fmt.Errorf("dropping %s from the page cache: %w", path, err)
	}
	defer f.Close()
	// Dirty pages are not dropped; the registry wrote the file when it was uploaded.
	if err := f.Sync(); err != nil {
		return 0, fmt.Errorf("dropping %s from the page cache: fsync: %w", path, err)
	}
	const posixFadvDontneed = 4
	// Pages that a previous sendfile(2) still holds in socket buffers (until the peer has read and acknowledged the data)
	// are skipped by POSIX_FADV_DONTNEED. Repeat the drop until no page is resident, for at most 180 s; the file must
	// still be fully cold when this returns, otherwise this fails. The drop is outside every timed section.
	start := time.Now()
	for attempt := 1; ; attempt++ {
		if _, _, errno := syscall.Syscall6(syscall.SYS_FADVISE64, f.Fd(), 0, 0, posixFadvDontneed, 0, 0); errno != 0 {
			return 0, fmt.Errorf("dropping %s from the page cache: posix_fadvise(POSIX_FADV_DONTNEED): %w", path, errno)
		}
		resident, pages, err := residentPages(path)
		if err != nil {
			return 0, fmt.Errorf("dropping %s from the page cache: reading residency: %w", path, err)
		}
		if resident == 0 {
			if attempt > 1 {
				fmt.Printf("cold page cache: %s needed %d drop attempts, %.0f ms, until no page was resident\n", path, attempt, time.Since(start).Seconds()*1000)
			}
			return pages, nil
		}
		if time.Since(start) > 180*time.Second {
			return 0, fmt.Errorf("dropping %s from the page cache: %d of %d pages are still resident after %d attempts of posix_fadvise(POSIX_FADV_DONTNEED) in 180 s", path, resident, pages, attempt)
		}
		if attempt%1000 == 0 { // every 10 s of waiting, so that the harness is seen to be alive
			fmt.Printf("cold page cache: waiting for %d resident pages of %s to become droppable (%.0f s)\n", resident, path, time.Since(start).Seconds())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func selfCPUSeconds() (float64, error) {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0, fmt.Errorf("getrusage: %w", err)
	}
	return float64(ru.Utime.Sec+ru.Stime.Sec) + float64(ru.Utime.Usec+ru.Stime.Usec)/1e6, nil
}

// pinnedCPUBusyTicks sums user, nice, system, irq and softirq ticks of the CPUs in REPRO_PINNED_CPUS (0 when unset).
func pinnedCPUBusyTicks() (uint64, error) {
	list := os.Getenv("REPRO_PINNED_CPUS")
	if list == "" {
		return 0, nil
	}
	pinned := map[string]bool{}
	for _, part := range strings.Split(list, ",") {
		first, last, isRange := strings.Cut(part, "-")
		if !isRange {
			last = first
		}
		a, errA := strconv.Atoi(first)
		b, errB := strconv.Atoi(last)
		if errA != nil || errB != nil || a > b {
			return 0, fmt.Errorf("invalid REPRO_PINNED_CPUS entry %q", part)
		}
		for cpu := a; cpu <= b; cpu++ {
			pinned["cpu"+strconv.Itoa(cpu)] = true
		}
	}
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, err
	}
	var busy uint64
	found := 0
	for _, line := range strings.Split(string(b), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 8 || !pinned[fields[0]] {
			continue
		}
		found++
		for _, idx := range []int{1, 2, 3, 6, 7} {
			v, err := strconv.ParseUint(fields[idx], 10, 64)
			if err != nil {
				return 0, fmt.Errorf("unexpected /proc/stat line %q", line)
			}
			busy += v
		}
	}
	if found != len(pinned) {
		return 0, fmt.Errorf("/proc/stat lists %d of the %d CPUs in REPRO_PINNED_CPUS", found, len(pinned))
	}
	return busy, nil
}

// readPlacement reads CPU affinity (every thread), memory policy (every mapping) and network namespace of a process.
func readPlacement(pid int) (placement, error) {
	p := placement{PID: pid}
	tasks, err := os.ReadDir(fmt.Sprintf("/proc/%d/task", pid))
	if err != nil {
		return p, err
	}
	cpus := map[string]bool{}
	for _, task := range tasks {
		b, err := os.ReadFile(fmt.Sprintf("/proc/%d/task/%s/status", pid, task.Name()))
		if err != nil {
			continue // the thread exited
		}
		for _, line := range strings.Split(string(b), "\n") {
			if value, ok := strings.CutPrefix(line, "Cpus_allowed_list:"); ok {
				cpus[strings.TrimSpace(value)] = true
				p.Threads++
			}
		}
	}
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/numa_maps", pid))
	if err != nil {
		return p, err
	}
	policies := map[string]bool{}
	for _, line := range strings.Split(string(b), "\n") {
		if fields := strings.Fields(line); len(fields) > 1 {
			policies[fields[1]] = true
		}
	}
	for value := range cpus {
		p.CPUsAllowed = append(p.CPUsAllowed, value)
	}
	for value := range policies {
		p.NUMAPolicies = append(p.NUMAPolicies, value)
	}
	sort.Strings(p.CPUsAllowed)
	sort.Strings(p.NUMAPolicies)
	if p.NetNamespace, err = os.Readlink(fmt.Sprintf("/proc/%d/ns/net", pid)); err != nil {
		return p, err
	}
	return p, nil
}

func procCPUTicks(pid int) (cpuTicks, error) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return cpuTicks{}, err
	}
	s := string(b)
	idx := strings.LastIndex(s, ")")
	if idx < 0 || idx+2 >= len(s) {
		return cpuTicks{}, fmt.Errorf("unexpected /proc/%d/stat format", pid)
	}
	fields := strings.Fields(s[idx+2:])
	if len(fields) < 13 {
		return cpuTicks{}, fmt.Errorf("unexpected /proc/%d/stat field count", pid)
	}
	utime, err := strconv.ParseUint(fields[11], 10, 64)
	if err != nil {
		return cpuTicks{}, err
	}
	stime, err := strconv.ParseUint(fields[12], 10, 64)
	if err != nil {
		return cpuTicks{}, err
	}
	return cpuTicks{User: utime, Kernel: stime}, nil
}

func cmdResultRequests(path string) error {
	r, err := readResult(path)
	if err != nil {
		return err
	}
	if r.Requests <= 0 {
		return fmt.Errorf("result %s has invalid request count: %d", path, r.Requests)
	}
	fmt.Println(r.Requests)
	return nil
}

func cmdCompare(unpatchedPath, patchedPath string) error {
	u, err := readResult(unpatchedPath)
	if err != nil {
		return err
	}
	p, err := readResult(patchedPath)
	if err != nil {
		return err
	}

	fmt.Println("")
	fmt.Println("Performance comparison (registry process CPU only)")
	fmt.Printf("%-30s %-10s %14s %14s\n", "metric", "unit", "unpatched", "patched")
	fmt.Printf("%-30s %-10s %14d %14d\n", "timed HTTP GET requests (N)", "requests", u.Requests, p.Requests)
	fmt.Printf("%-30s %-10s %14d %14d\n", "all HTTP GET requests", "requests", u.Requests+u.WarmupRequests, p.Requests+p.WarmupRequests)
	fmt.Printf("%-30s %-10s %14d %14d\n", "configured concurrency", "responses", u.Concurrency, p.Concurrency)
	fmt.Printf("%-30s %-10s %14d %14d\n", "max incoming responses", "responses", u.MaxIncomingResponses, p.MaxIncomingResponses)
	fmt.Printf("%-30s %-10s %14.3f %14.3f\n", "wall time", "s", u.WallSeconds, p.WallSeconds)
	fmt.Printf("%-30s %-10s %14.3f %14.3f\n", "registry total CPU time", "s", u.RegistryCPUSeconds, p.RegistryCPUSeconds)
	fmt.Printf("%-30s %-10s %14.3f %14.3f\n", "registry user CPU time", "s", u.RegistryUserCPUSeconds, p.RegistryUserCPUSeconds)
	fmt.Printf("%-30s %-10s %14.3f %14.3f\n", "registry kernel CPU time", "s", u.RegistryKernelCPUSeconds, p.RegistryKernelCPUSeconds)
	fmt.Printf("%-30s %-10s %14.1f %14.1f\n", "registry CPU, one core", "%", u.RegistryCPUOneCore, p.RegistryCPUOneCore)
	fmt.Printf("%-30s %-10s %14.2f %14.2f\n", "registry CPU, whole host", "%", u.RegistryCPUHost, p.RegistryCPUHost)
	fmt.Printf("%-30s %-10s %14.3f %14.3f\n", "CPU time per GiB", "s/GiB", u.RegistryCPUPerGiB, p.RegistryCPUPerGiB)
	fmt.Printf("%-30s %-10s %14.1f %14.1f\n", "throughput", "MiB/s", u.ThroughputMiBPerSec, p.ThroughputMiBPerSec)

	if u.RegistryCPUPerGiB > 0 && p.RegistryCPUPerGiB > 0 {
		reduction := (1 - (p.RegistryCPUPerGiB / u.RegistryCPUPerGiB)) * 100
		ratio := u.RegistryCPUPerGiB / p.RegistryCPUPerGiB
		fmt.Printf("\nPatched registry CPU per GiB: %.1f%% lower, %.2fx less than unpatched.\n", reduction, ratio)
		if reduction <= 0 {
			fmt.Println("WARNING: patched run did not use less registry CPU in this sample.")
		}
	}
	return nil
}

func cmdRepeatSummary(paths []string) error {
	var unpatched []result
	var patched []result
	for i := 0; i < len(paths); i += 2 {
		u, err := readResult(paths[i])
		if err != nil {
			return err
		}
		p, err := readResult(paths[i+1])
		if err != nil {
			return err
		}
		unpatched = append(unpatched, u)
		patched = append(patched, p)
	}

	fmt.Printf("\nRepeated performance summary (n=%d, registry process CPU only)\n", len(unpatched))
	fmt.Printf("%-34s %-10s %16s %16s %16s %16s %16s %16s\n", "metric", "unit", "unpatched mean", "unpatched sd", "unpatched sem", "patched mean", "patched sd", "patched sem")
	printVariantMetric("timed HTTP GET requests (N)", "requests", unpatched, patched, func(r result) float64 { return float64(r.Requests) })
	printVariantMetric("all HTTP GET requests", "requests", unpatched, patched, func(r result) float64 { return float64(r.Requests + r.WarmupRequests) })
	printVariantMetric("chunk size", "MiB", unpatched, patched, func(r result) float64 { return float64(r.RangeBytes) / (1024 * 1024) })
	printVariantMetric("configured concurrency", "responses", unpatched, patched, func(r result) float64 { return float64(r.Concurrency) })
	printVariantMetric("max incoming responses", "responses", unpatched, patched, func(r result) float64 { return float64(r.MaxIncomingResponses) })
	printVariantMetric("wall time", "s", unpatched, patched, func(r result) float64 { return r.WallSeconds })
	printVariantMetric("registry total CPU time", "s", unpatched, patched, func(r result) float64 { return r.RegistryCPUSeconds })
	printVariantMetric("registry user CPU time", "s", unpatched, patched, func(r result) float64 { return r.RegistryUserCPUSeconds })
	printVariantMetric("registry kernel CPU time", "s", unpatched, patched, func(r result) float64 { return r.RegistryKernelCPUSeconds })
	printVariantMetric("registry CPU, one core", "%", unpatched, patched, func(r result) float64 { return r.RegistryCPUOneCore })
	printVariantMetric("registry CPU, whole host", "%", unpatched, patched, func(r result) float64 { return r.RegistryCPUHost })
	printVariantMetric("CPU time per GiB", "s/GiB", unpatched, patched, func(r result) float64 { return r.RegistryCPUPerGiB })
	printVariantMetric("throughput", "MiB/s", unpatched, patched, func(r result) float64 { return r.ThroughputMiBPerSec })

	unpatchedCPUSeconds := values(unpatched, func(r result) float64 { return r.RegistryCPUSeconds })
	patchedCPUSeconds := values(patched, func(r result) float64 { return r.RegistryCPUSeconds })
	uStats := stats(unpatchedCPUSeconds)
	pStats := stats(patchedCPUSeconds)
	ratio, ratioSEM := propagatedRatio(uStats, pStats)
	reduction, reductionSEM := propagatedReductionFromRatio(ratio, ratioSEM)
	envelopeRatio := ratioEnvelope(unpatchedCPUSeconds, patchedCPUSeconds)

	fmt.Printf("\nRepeated comparison summary\n")
	fmt.Printf("%-42s %-8s %s\n", "metric", "unit", "value")
	printSummaryRow("total CPU time values (unpatched)", "s", formatFloatList(unpatchedCPUSeconds))
	printSummaryRow("total CPU time values (patched)", "s", formatFloatList(patchedCPUSeconds))
	printSummaryRow("unpatched/patched CPU time total", "x", formatPlusMinus(ratio, ratioSEM))
	printSummaryRow("patched total CPU time reduction", "%", formatPlusMinus(reduction, reductionSEM))
	printSummaryRow("envelope max(unpatched)/min(patched)", "x", fmt.Sprintf("%.3f (diagnostic, not main KPI)", envelopeRatio))
	return nil
}

func printVariantMetric(name, unit string, unpatched, patched []result, f func(result) float64) {
	us := stats(values(unpatched, f))
	ps := stats(values(patched, f))
	fmt.Printf("%-34s %-10s %16.3f %16.3f %16.3f %16.3f %16.3f %16.3f\n", name, unit, us.Mean, us.Stddev, us.SEM, ps.Mean, ps.Stddev, ps.SEM)
}

func values(rs []result, f func(result) float64) []float64 {
	vals := make([]float64, 0, len(rs))
	for _, r := range rs {
		vals = append(vals, f(r))
	}
	return vals
}

func ratioEnvelope(unpatched, patched []float64) float64 {
	maxUnpatched, ok := maxFloat(unpatched)
	if !ok {
		return 0
	}
	minPatched, ok := minPositiveFloat(patched)
	if !ok {
		return 0
	}
	return maxUnpatched / minPatched
}

func maxFloat(vals []float64) (float64, bool) {
	if len(vals) == 0 {
		return 0, false
	}
	max := vals[0]
	for _, v := range vals[1:] {
		if v > max {
			max = v
		}
	}
	return max, true
}

func minPositiveFloat(vals []float64) (float64, bool) {
	var min float64
	ok := false
	for _, v := range vals {
		if v <= 0 {
			continue
		}
		if !ok || v < min {
			min = v
			ok = true
		}
	}
	return min, ok
}

func printSummaryRow(name, unit, value string) {
	fmt.Printf("%-42s %-8s %s\n", name, unit, value)
}

func formatPlusMinus(mean, err float64) string {
	return fmt.Sprintf("%.3f +/- %.3f", mean, err)
}

func formatFloatList(vals []float64) string {
	if len(vals) == 0 {
		return ""
	}
	parts := make([]string, 0, len(vals))
	for _, v := range vals {
		parts = append(parts, fmt.Sprintf("%.3f", v))
	}
	return strings.Join(parts, ", ")
}

func stats(vals []float64) seriesStats {
	if len(vals) == 0 {
		return seriesStats{}
	}
	var sum float64
	for _, v := range vals {
		sum += v
	}
	mean := sum / float64(len(vals))
	if len(vals) == 1 {
		return seriesStats{Mean: mean, N: len(vals)}
	}
	var sq float64
	for _, v := range vals {
		d := v - mean
		sq += d * d
	}
	stddev := math.Sqrt(sq / float64(len(vals)-1))
	sem := stddev / math.Sqrt(float64(len(vals)))
	return seriesStats{Mean: mean, Stddev: stddev, SEM: sem, N: len(vals)}
}

func propagatedRatio(numerator, denominator seriesStats) (float64, float64) {
	if denominator.Mean == 0 {
		return 0, 0
	}
	ratio := numerator.Mean / denominator.Mean
	var relSq float64
	if numerator.Mean != 0 {
		rel := numerator.SEM / numerator.Mean
		relSq += rel * rel
	}
	if denominator.Mean != 0 {
		rel := denominator.SEM / denominator.Mean
		relSq += rel * rel
	}
	return ratio, math.Abs(ratio) * math.Sqrt(relSq)
}

func propagatedReductionFromRatio(ratio, ratioErr float64) (float64, float64) {
	if ratio == 0 {
		return 0, 0
	}
	reduction := (1 - (1 / ratio)) * 100
	err := math.Abs(100 * ratioErr / (ratio * ratio))
	return reduction, err
}

func cmdSweepLine(label, autoTargetSeconds, unpatchedPath, patchedPath string) error {
	u, err := readResult(unpatchedPath)
	if err != nil {
		return err
	}
	p, err := readResult(patchedPath)
	if err != nil {
		return err
	}

	ratio := 0.0
	reduction := 0.0
	if p.RegistryCPUPerGiB > 0 {
		ratio = u.RegistryCPUPerGiB / p.RegistryCPUPerGiB
	}
	if u.RegistryCPUPerGiB > 0 {
		reduction = (1 - (p.RegistryCPUPerGiB / u.RegistryCPUPerGiB)) * 100
	}
	fmt.Printf("%s\t%s\t%d\t%d\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.1f\t%.1f\t%d\t%d\n",
		label,
		autoTargetSeconds,
		u.Requests,
		p.Requests,
		u.Concurrency,
		float64(u.RangeBytes)/(1024*1024),
		u.RegistryCPUPerGiB,
		p.RegistryCPUPerGiB,
		ratio,
		u.RegistryCPUSeconds,
		p.RegistryCPUSeconds,
		reduction,
		p.ThroughputMiBPerSec,
		u.MaxIncomingResponses,
		p.MaxIncomingResponses,
	)
	return nil
}

type sweepGroup struct {
	ChunkMiB          float64
	Concurrency       int64
	AutoTargetSeconds string
	RequestsLabel     string
	UnpatchedCPUGiB   []float64
	PatchedCPUGiB     []float64
	PatchedThroughput []float64
}

func cmdSweepSummary(path string) error {
	groups, order, err := readSweepGroups(path)
	if err != nil {
		return err
	}
	if len(order) == 0 {
		return fmt.Errorf("no sweep rows found in %s", path)
	}

	fmt.Printf("\nSweep KPI by input parameter combination (main KPI: unpatched/patched CPU per GiB)\n")
	fmt.Printf("%-10s %-12s %-14s %-12s %-8s %-18s %-18s %-21s %-21s %-18s %-18s\n",
		"chunk_MiB", "concurrency", "auto_target_s", "N", "R", "unpatched_s/GiB", "patched_s/GiB", "ratio_x +/- SEM", "reduction_% +/- SEM", "patched_MiB/s", "envelope_ratio_x")
	for _, key := range order {
		g := groups[key]
		uStats := stats(g.UnpatchedCPUGiB)
		pStats := stats(g.PatchedCPUGiB)
		throughputStats := stats(g.PatchedThroughput)
		ratio, ratioSEM := propagatedRatio(uStats, pStats)
		reduction, reductionSEM := propagatedReductionFromRatio(ratio, ratioSEM)
		envelopeRatio := ratioEnvelope(g.UnpatchedCPUGiB, g.PatchedCPUGiB)
		fmt.Printf("%-10.3f %-12d %-14s %-12s %-8d %-18.3f %-18.3f %8.3f +/- %-8.3f %8.3f +/- %-8.3f %-18.1f %-18.3f\n",
			g.ChunkMiB,
			g.Concurrency,
			g.AutoTargetSeconds,
			g.RequestsLabel,
			uStats.N,
			uStats.Mean,
			pStats.Mean,
			ratio,
			ratioSEM,
			reduction,
			reductionSEM,
			throughputStats.Mean,
			envelopeRatio,
		)
	}
	return nil
}

func readSweepGroups(path string) (map[string]*sweepGroup, []string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		return nil, nil, fmt.Errorf("empty sweep TSV: %s", path)
	}
	header := strings.Split(lines[0], "\t")
	idx := map[string]int{}
	for i, name := range header {
		idx[name] = i
	}
	required := []string{"auto_target_seconds", "unpatched_requests", "patched_requests", "concurrency", "chunk_mib", "unpatched_cpu_s_per_gib", "patched_cpu_s_per_gib", "patched_throughput_mib_s"}
	for _, name := range required {
		if _, ok := idx[name]; !ok {
			return nil, nil, fmt.Errorf("sweep TSV %s is missing column %q", path, name)
		}
	}

	groups := map[string]*sweepGroup{}
	var order []string
	for lineNo, line := range lines[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < len(header) {
			return nil, nil, fmt.Errorf("sweep TSV %s line %d has %d fields, want at least %d", path, lineNo+2, len(fields), len(header))
		}
		unpatchedRequests, err := parseSweepInt(fields, idx, "unpatched_requests")
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %w", lineNo+2, err)
		}
		autoTargetSeconds := fields[idx["auto_target_seconds"]]
		if _, err := strconv.ParseFloat(autoTargetSeconds, 64); err != nil {
			return nil, nil, fmt.Errorf("line %d: invalid auto_target_seconds %q: %w", lineNo+2, autoTargetSeconds, err)
		}
		patchedRequests, err := parseSweepInt(fields, idx, "patched_requests")
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %w", lineNo+2, err)
		}
		concurrency, err := parseSweepInt(fields, idx, "concurrency")
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %w", lineNo+2, err)
		}
		chunkMiB, err := parseSweepFloat(fields, idx, "chunk_mib")
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %w", lineNo+2, err)
		}
		unpatchedCPUGiB, err := parseSweepFloat(fields, idx, "unpatched_cpu_s_per_gib")
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %w", lineNo+2, err)
		}
		patchedCPUGiB, err := parseSweepFloat(fields, idx, "patched_cpu_s_per_gib")
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %w", lineNo+2, err)
		}
		patchedThroughput, err := parseSweepFloat(fields, idx, "patched_throughput_mib_s")
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %w", lineNo+2, err)
		}

		requestsLabel := strconv.FormatInt(unpatchedRequests, 10)
		if patchedRequests != unpatchedRequests {
			requestsLabel = fmt.Sprintf("%d/%d", unpatchedRequests, patchedRequests)
		}
		key := fmt.Sprintf("%.6f\t%d\t%s\t%s", chunkMiB, concurrency, autoTargetSeconds, requestsLabel)
		g, ok := groups[key]
		if !ok {
			g = &sweepGroup{
				ChunkMiB:          chunkMiB,
				Concurrency:       concurrency,
				AutoTargetSeconds: autoTargetSeconds,
				RequestsLabel:     requestsLabel,
			}
			groups[key] = g
			order = append(order, key)
		}
		g.UnpatchedCPUGiB = append(g.UnpatchedCPUGiB, unpatchedCPUGiB)
		g.PatchedCPUGiB = append(g.PatchedCPUGiB, patchedCPUGiB)
		g.PatchedThroughput = append(g.PatchedThroughput, patchedThroughput)
	}
	return groups, order, nil
}

func parseSweepInt(fields []string, idx map[string]int, name string) (int64, error) {
	v, err := strconv.ParseInt(fields[idx[name]], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s %q: %w", name, fields[idx[name]], err)
	}
	return v, nil
}

func parseSweepFloat(fields []string, idx map[string]int, name string) (float64, error) {
	v, err := strconv.ParseFloat(fields[idx[name]], 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s %q: %w", name, fields[idx[name]], err)
	}
	return v, nil
}

func cmdSweepBest(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	bestLabel := ""
	bestRatio := -1.0
	bestLine := ""
	for _, line := range lines {
		if line == "" || strings.HasPrefix(line, "label\t") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 9 {
			continue
		}
		ratio, err := strconv.ParseFloat(fields[8], 64)
		if err != nil {
			continue
		}
		if ratio > bestRatio {
			bestRatio = ratio
			bestLabel = fields[0]
			bestLine = line
		}
	}
	if bestLabel == "" {
		return fmt.Errorf("no sweep rows found in %s", path)
	}
	fmt.Printf("\nBest sweep ratio: %s (%.2fx less patched CPU/GiB)\n", bestLabel, bestRatio)
	fmt.Printf("%s\n", bestLine)
	return nil
}

func readResult(path string) (result, error) {
	var r result
	b, err := os.ReadFile(path)
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(b, &r); err != nil {
		return r, err
	}
	return r, nil
}
GOEOF
}

ensure_upstream() {
	# In the private network namespace there is no network; the first pass on the host has fetched.
	if [ -z "${RUN_REPRO_HOST_NETNS:-}" ]; then
		if [ ! -d "$UPSTREAM_DIR/.git" ]; then
			log "cloning $REGISTRY_REPO_URL into $UPSTREAM_DIR"
			git clone "$REGISTRY_REPO_URL" "$UPSTREAM_DIR"
		fi

		log "fetching $REGISTRY_REPO_URL refs"
		git -C "$UPSTREAM_DIR" remote set-url origin "$REGISTRY_REPO_URL"
		git -C "$UPSTREAM_DIR" fetch --tags --prune origin '+refs/heads/*:refs/remotes/origin/*'
	fi

	RESOLVED_COMMIT=$(git -C "$UPSTREAM_DIR" rev-parse --verify "origin/$REGISTRY_REF^{commit}" 2>/dev/null || true)
	if [ -z "$RESOLVED_COMMIT" ]; then
		RESOLVED_COMMIT=$(git -C "$UPSTREAM_DIR" rev-parse --verify "$REGISTRY_REF^{commit}" 2>/dev/null || true)
	fi
	[ -n "$RESOLVED_COMMIT" ] || die "could not resolve REGISTRY_REF=$REGISTRY_REF"
	log "using distribution commit $RESOLVED_COMMIT ($REGISTRY_REF)"
}

build_key() {
	printf '%s\n' \
		"repo=$REGISTRY_REPO_URL" \
		"ref=$REGISTRY_REF" \
		"commit=$RESOLVED_COMMIT" \
		"pkg=$REGISTRY_BUILD_PKG" \
		"go=$GO_VERSION" \
		"go_build_flags=$GO_BUILD_FLAGS" \
		"$@" | git hash-object --stdin
}

build_registry() {
	variant=$1
	bin=$2
	key=$3
	apply_patch=$4
	keyfile="$BIN_DIR/$variant.key"

	if [ -x "$bin" ] && [ -f "$keyfile" ] && [ "$(cat "$keyfile")" = "$key" ]; then
		log "keeping cached $variant registry build: $bin"
		return
	fi

	src="$BUILD_SRC_ROOT/$variant"
	log "building $variant registry"
	safe_rm_rf "$src"
	mkdir -p "$BUILD_SRC_ROOT"
	git clone --quiet "$UPSTREAM_DIR" "$src"
	git -C "$src" checkout --quiet --detach "$RESOLVED_COMMIT"

	if [ "$apply_patch" = "yes" ]; then
		git -C "$src" apply "$PATCH_FILE"
	fi

	tmpbin="$bin.tmp.$$"
	(cd "$src" && "$GO_BIN" build $GO_BUILD_FLAGS -o "$tmpbin" "$REGISTRY_BUILD_PKG")
	mv "$tmpbin" "$bin"
	printf '%s\n' "$key" > "$keyfile"
}

CURRENT_PID=
CURRENT_LOG=
CURRENT_PIDFILE=
CURRENT_LABEL=

stop_current_registry() {
	if [ -n "${CURRENT_PID:-}" ]; then
		if kill -0 "$CURRENT_PID" 2>/dev/null; then
			log "terminating ${CURRENT_LABEL:-registry} pid $CURRENT_PID on $REGISTRY_ADDR"
			kill "$CURRENT_PID" 2>/dev/null || true
			wait "$CURRENT_PID" 2>/dev/null || true
			log "terminated ${CURRENT_LABEL:-registry} pid $CURRENT_PID"
		else
			log "${CURRENT_LABEL:-registry} pid $CURRENT_PID already stopped"
		fi
		CURRENT_PID=
	fi
	if [ -n "${CURRENT_PIDFILE:-}" ]; then
		rm -f "$CURRENT_PIDFILE"
	fi
	CURRENT_LOG=
	CURRENT_PIDFILE=
	CURRENT_LABEL=
}

trap 'stop_current_registry' EXIT
trap 'stop_current_registry; exit 130' INT
trap 'stop_current_registry; exit 143' TERM

cleanup_repro_registries() {
	"$GO_BIN" run "$HELPER_GO" cleanup "$REGISTRY_PORT" "$REGISTRY_PORT_RANGE_START" "$REGISTRY_PORT_RANGE_END" "${UNPATCHED_BIN##*/}" "${PATCHED_BIN##*/}"
}

ensure_registry_port_free() {
	if "$GO_BIN" run "$HELPER_GO" port-free "$REGISTRY_PORT" >/dev/null 2>&1; then
		return
	fi

	if ! registry_port_in_cleanup_range; then
		die "port $REGISTRY_PORT has a listener and is outside repro cleanup range $REGISTRY_PORT_RANGE_START-$REGISTRY_PORT_RANGE_END; refusing automatic cleanup"
	fi

	log "port $REGISTRY_PORT already has a listener in repro range $REGISTRY_PORT_RANGE_START-$REGISTRY_PORT_RANGE_END; checking by process name"
	cleanup_repro_registries

	i=0
	while [ "$i" -lt 30 ]; do
		if "$GO_BIN" run "$HELPER_GO" port-free "$REGISTRY_PORT" >/dev/null 2>&1; then
			return
		fi
		i=$((i + 1))
		sleep 1
	done

	die "port $REGISTRY_PORT still has a listener, but no matching repro registry process was stopped; choose another REGISTRY_PORT or stop the non-repro process manually"
}

select_registry_port() {
	is_positive_int "$REGISTRY_PORT_RANGE_START" || die "REGISTRY_PORT_RANGE_START must be a positive integer: $REGISTRY_PORT_RANGE_START"
	is_positive_int "$REGISTRY_PORT_RANGE_END" || die "REGISTRY_PORT_RANGE_END must be a positive integer: $REGISTRY_PORT_RANGE_END"
	[ "$REGISTRY_PORT_RANGE_START" -le 65535 ] || die "REGISTRY_PORT_RANGE_START must be <= 65535: $REGISTRY_PORT_RANGE_START"
	[ "$REGISTRY_PORT_RANGE_END" -le 65535 ] || die "REGISTRY_PORT_RANGE_END must be <= 65535: $REGISTRY_PORT_RANGE_END"
	[ "$REGISTRY_PORT_RANGE_START" -le "$REGISTRY_PORT_RANGE_END" ] || die "invalid registry port range: $REGISTRY_PORT_RANGE_START-$REGISTRY_PORT_RANGE_END"

	if [ -n "$REGISTRY_PORT" ]; then
		is_positive_int "$REGISTRY_PORT" || die "REGISTRY_PORT must be a positive integer: $REGISTRY_PORT"
		[ "$REGISTRY_PORT" -le 65535 ] || die "REGISTRY_PORT must be <= 65535: $REGISTRY_PORT"
	else
		if ! REGISTRY_PORT=$("$GO_BIN" run "$HELPER_GO" choose-port "$REGISTRY_PORT_RANGE_START" "$REGISTRY_PORT_RANGE_END"); then
			die "could not choose a free registry port in range $REGISTRY_PORT_RANGE_START-$REGISTRY_PORT_RANGE_END"
		fi
	fi
	REGISTRY_ADDR="$REGISTRY_HOST:$REGISTRY_PORT"
	if [ "$REGISTRY_TLS" = 1 ]; then
		REGISTRY_BASE_URL="https://$REGISTRY_ADDR"
	else
		REGISTRY_BASE_URL="http://$REGISTRY_ADDR"
	fi
}

numa_node_has_cpus() {
	numa_node=$1
	is_numa_node_id "$numa_node" || return 1
	numa_cpulist_path="/sys/devices/system/node/node$numa_node/cpulist"
	[ -r "$numa_cpulist_path" ] || return 1
	numa_cpulist=
	# Some sh builtins return an empty value when reading these sysfs files.
	numa_cpulist=$(cat "$numa_cpulist_path") || numa_cpulist=
	[ -n "$numa_cpulist" ]
}

numa_nodes_with_cpus() {
	for numa_node_dir in /sys/devices/system/node/node[0-9]*; do
		[ -d "$numa_node_dir" ] || continue
		numa_node=${numa_node_dir##*/node}
		numa_node_has_cpus "$numa_node" || continue
		printf '%s\n' "$numa_node"
	done
}

first_different_numa_node() {
	numa_avoid=$1
	for numa_node in $(numa_nodes_with_cpus); do
		if [ "$numa_node" != "$numa_avoid" ]; then
			printf '%s\n' "$numa_node"
			return 0
		fi
	done
	return 1
}

numa_cpulist_for_node() {
	numa_node=$1
	numa_cpulist_path="/sys/devices/system/node/node$numa_node/cpulist"
	[ -r "$numa_cpulist_path" ] || return 1
	numa_cpulist=
	numa_cpulist=$(cat "$numa_cpulist_path") || numa_cpulist=
	[ -n "$numa_cpulist" ] || return 1
	printf '%s\n' "$numa_cpulist"
}

expand_cpu_list() {
	cpu_list=$1
	case "$cpu_list" in
		''|,*|*,|*,,*) return 1 ;;
	esac

	old_ifs=$IFS
	IFS=,
	set -- $cpu_list
	IFS=$old_ifs

	for cpu_part do
		case "$cpu_part" in
			*-*)
				cpu_start=${cpu_part%-*}
				cpu_end=${cpu_part#*-}
				is_numa_node_id "$cpu_start" || return 1
				is_numa_node_id "$cpu_end" || return 1
				[ "$cpu_start" -le "$cpu_end" ] || return 1
				while [ "$cpu_start" -le "$cpu_end" ]; do
					printf '%s\n' "$cpu_start"
					cpu_start=$((cpu_start + 1))
				done
				;;
			*)
				is_numa_node_id "$cpu_part" || return 1
				printf '%s\n' "$cpu_part"
				;;
		esac
	done
}

csv_append() {
	csv_existing=$1
	csv_value=$2
	if [ -n "$csv_existing" ]; then
		printf '%s,%s\n' "$csv_existing" "$csv_value"
	else
		printf '%s\n' "$csv_value"
	fi
}

cpu_list_contains_cpu() {
	cpu_needle=$1
	cpu_haystack=$2
	for cpu_item in $(expand_cpu_list "$cpu_haystack"); do
		[ "$cpu_item" = "$cpu_needle" ] && return 0
	done
	return 1
}

cpu_list_subset_of() {
	cpu_subset=$1
	cpu_superset=$2
	for cpu_item in $(expand_cpu_list "$cpu_subset"); do
		cpu_list_contains_cpu "$cpu_item" "$cpu_superset" || return 1
	done
	return 0
}

cpu_lists_overlap() {
	cpu_left=$1
	cpu_right=$2
	for cpu_item in $(expand_cpu_list "$cpu_left"); do
		cpu_list_contains_cpu "$cpu_item" "$cpu_right" && return 0
	done
	return 1
}

split_same_socket_cpu_lists() {
	numa_node=$1
	node_cpulist=$(numa_cpulist_for_node "$numa_node") || die "could not read CPUs for NUMA node $numa_node"
	expand_cpu_list "$node_cpulist" >/dev/null || die "invalid CPU list for NUMA node $numa_node: $node_cpulist"

	REGISTRY_CPU_LIST=
	CLIENT_CPU_LIST=
	cpu_index=0
	for cpu_item in $(expand_cpu_list "$node_cpulist"); do
		if [ $((cpu_index % 2)) -eq 0 ]; then
			REGISTRY_CPU_LIST=$(csv_append "$REGISTRY_CPU_LIST" "$cpu_item")
		else
			CLIENT_CPU_LIST=$(csv_append "$CLIENT_CPU_LIST" "$cpu_item")
		fi
		cpu_index=$((cpu_index + 1))
	done

	[ -n "$REGISTRY_CPU_LIST" ] && [ -n "$CLIENT_CPU_LIST" ] || die "NUMA node $numa_node needs at least two logical CPUs for NUMA_PIN=same-socket"
}

validate_same_socket_cpu_lists() {
	numa_node=$1
	node_cpulist=$(numa_cpulist_for_node "$numa_node") || die "could not read CPUs for NUMA node $numa_node"
	expand_cpu_list "$node_cpulist" >/dev/null || die "invalid CPU list for NUMA node $numa_node: $node_cpulist"
	expand_cpu_list "$REGISTRY_CPU_LIST" >/dev/null || die "invalid REGISTRY_CPU_LIST: $REGISTRY_CPU_LIST"
	expand_cpu_list "$CLIENT_CPU_LIST" >/dev/null || die "invalid CLIENT_CPU_LIST: $CLIENT_CPU_LIST"
	cpu_list_subset_of "$REGISTRY_CPU_LIST" "$node_cpulist" || die "REGISTRY_CPU_LIST is not contained in NUMA node $numa_node CPU list $node_cpulist"
	cpu_list_subset_of "$CLIENT_CPU_LIST" "$node_cpulist" || die "CLIENT_CPU_LIST is not contained in NUMA node $numa_node CPU list $node_cpulist"
	if cpu_lists_overlap "$REGISTRY_CPU_LIST" "$CLIENT_CPU_LIST"; then
		die "REGISTRY_CPU_LIST and CLIENT_CPU_LIST must be disjoint for NUMA_PIN=same-socket"
	fi
}

configure_numa_pinning() {
	NUMA_ACTIVE=0
	NUMA_CPUSET_ACTIVE=0

	numa_first_node=
	numa_detected_nodes=
	numa_detected_count=0
	for numa_node in $(numa_nodes_with_cpus); do
		numa_detected_count=$((numa_detected_count + 1))
		if [ -z "$numa_first_node" ]; then
			numa_first_node=$numa_node
		fi
		numa_detected_nodes="${numa_detected_nodes}${numa_detected_nodes:+ }$numa_node"
	done

	case "$NUMA_PIN" in
		same-socket)
			if [ "$numa_detected_count" -lt 2 ]; then
				die "same-socket pinning requires two detected NUMA nodes with CPUs on this benchmark host; found $numa_detected_count; refusing an unpinned measurement"
			fi
			if [ -n "$REGISTRY_NUMA_NODE" ]; then
				is_numa_node_id "$REGISTRY_NUMA_NODE" || die "REGISTRY_NUMA_NODE must be a NUMA node id: $REGISTRY_NUMA_NODE"
				numa_node_has_cpus "$REGISTRY_NUMA_NODE" || die "REGISTRY_NUMA_NODE=$REGISTRY_NUMA_NODE does not exist or has no CPUs"
			else
				REGISTRY_NUMA_NODE=$numa_first_node
			fi
			if [ -n "$CLIENT_NUMA_NODE" ] && [ "$CLIENT_NUMA_NODE" != "$REGISTRY_NUMA_NODE" ]; then
				die "CLIENT_NUMA_NODE must match REGISTRY_NUMA_NODE for NUMA_PIN=same-socket"
			fi
			CLIENT_NUMA_NODE=$REGISTRY_NUMA_NODE
			if ! command -v numactl >/dev/null 2>&1; then
				die "NUMA_PIN=same-socket requires numactl for CPU and memory pinning"
			fi
			if [ -z "$REGISTRY_CPU_LIST" ] && [ -z "$CLIENT_CPU_LIST" ]; then
				split_same_socket_cpu_lists "$REGISTRY_NUMA_NODE"
			elif [ -z "$REGISTRY_CPU_LIST" ] || [ -z "$CLIENT_CPU_LIST" ]; then
				die "set both REGISTRY_CPU_LIST and CLIENT_CPU_LIST, or neither, for NUMA_PIN=same-socket"
			fi
			validate_same_socket_cpu_lists "$REGISTRY_NUMA_NODE"
			NUMA_ACTIVE=1
			NUMA_CPUSET_ACTIVE=1
			log "NUMA same-socket pinning active: node $REGISTRY_NUMA_NODE, registry CPUs $REGISTRY_CPU_LIST, client CPUs $CLIENT_CPU_LIST; detected nodes with CPUs: $numa_detected_nodes"
			return
			;;
		cross-socket)
			;;
	esac

	if [ "$numa_detected_count" -lt 2 ]; then
		die "NUMA_PIN=cross-socket requested, but found fewer than two NUMA nodes with CPUs"
	fi

	if [ -n "$REGISTRY_NUMA_NODE" ]; then
		is_numa_node_id "$REGISTRY_NUMA_NODE" || die "REGISTRY_NUMA_NODE must be a NUMA node id: $REGISTRY_NUMA_NODE"
		numa_node_has_cpus "$REGISTRY_NUMA_NODE" || die "REGISTRY_NUMA_NODE=$REGISTRY_NUMA_NODE does not exist or has no CPUs"
	else
		REGISTRY_NUMA_NODE=$numa_first_node
	fi

	if [ -n "$CLIENT_NUMA_NODE" ]; then
		is_numa_node_id "$CLIENT_NUMA_NODE" || die "CLIENT_NUMA_NODE must be a NUMA node id: $CLIENT_NUMA_NODE"
		numa_node_has_cpus "$CLIENT_NUMA_NODE" || die "CLIENT_NUMA_NODE=$CLIENT_NUMA_NODE does not exist or has no CPUs"
	else
		CLIENT_NUMA_NODE=$(first_different_numa_node "$REGISTRY_NUMA_NODE") || die "could not choose a client NUMA node different from registry node $REGISTRY_NUMA_NODE"
	fi

	[ "$REGISTRY_NUMA_NODE" != "$CLIENT_NUMA_NODE" ] || die "registry and client NUMA nodes must differ: $REGISTRY_NUMA_NODE"

	if ! command -v numactl >/dev/null 2>&1; then
		die "NUMA nodes detected ($numa_detected_nodes), but numactl is required for CPU and memory pinning; install numactl before measuring"
	fi

	NUMA_ACTIVE=1
	log "NUMA cross-socket pinning active: registry node $REGISTRY_NUMA_NODE, client node $CLIENT_NUMA_NODE; detected nodes with CPUs: $numa_detected_nodes"
}

registry_port_in_cleanup_range() {
	[ "$REGISTRY_PORT" -ge "$REGISTRY_PORT_RANGE_START" ] && [ "$REGISTRY_PORT" -le "$REGISTRY_PORT_RANGE_END" ]
}

assert_registry_config_path() {
	config=$1
	case "$config" in
		"$RUN_DIR"/config-*.yml) ;;
		*) die "refusing to start registry with unexpected config path: $config" ;;
	esac
	[ -f "$config" ] || die "refusing to start registry with missing config path: $config"
}

check_started_registry_cmdline() {
	pid=$1
	config=$2
	if ! "$GO_BIN" run "$HELPER_GO" check-cmdline "$pid" "$config" "${UNPATCHED_BIN##*/}" "${PATCHED_BIN##*/}"; then
		stop_current_registry
		die "launched registry pid $pid did not have expected argv; refused to continue"
	fi
}

start_registry() {
	variant=$1
	bin=$2
	registry_label=${3:-"$variant registry"}
	config="$RUN_DIR/config-$variant.yml"
	log_file="$RUN_DIR/registry-$variant.log"
	pid_file="$RUN_DIR/registry-$variant.pid"

	ensure_registry_port_free

	tls_cert="$RUN_DIR/tls.crt"
	tls_key="$RUN_DIR/tls.key"
	if [ "$REGISTRY_TLS" = 1 ]; then
		if [ ! -f "$tls_cert" ]; then
			need_cmd openssl
			openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
				-subj "/CN=$REGISTRY_HOST" \
				-addext "subjectAltName=IP:$REGISTRY_HOST" \
				-keyout "$tls_key" -out "$tls_cert" >/dev/null 2>&1 \
				|| die "could not generate TLS certificate"
		fi
		# Trust the generated certificate in curl and in the Go load helper
		# without changing any client code.
		CURL_CA_BUNDLE="$tls_cert"; export CURL_CA_BUNDLE
		SSL_CERT_FILE="$tls_cert"; export SSL_CERT_FILE
	fi

	cat > "$config" <<EOF
version: 0.1
log:
  accesslog:
    disabled: true
  level: error
storage:
  cache:
    blobdescriptor: inmemory
  maintenance:
    uploadpurging:
      enabled: false
  filesystem:
    rootdirectory: "$STORAGE_DIR"
http:
  addr: "$REGISTRY_ADDR"
  secret: "sendfile-repro-local-secret"
EOF
	if [ "$REGISTRY_TLS" = 1 ]; then
		cat >> "$config" <<EOF
  tls:
    certificate: "$tls_cert"
    key: "$tls_key"
EOF
	fi
	assert_registry_config_path "$config"

	if [ "$NUMA_ACTIVE" = 1 ]; then
		if [ "$NUMA_CPUSET_ACTIVE" = 1 ]; then
			log "launching $registry_label on $REGISTRY_BASE_URL with config $config, NUMA node $REGISTRY_NUMA_NODE CPUs $REGISTRY_CPU_LIST"
			OTEL_TRACES_EXPORTER=none numactl --physcpubind="$REGISTRY_CPU_LIST" --membind="$REGISTRY_NUMA_NODE" "$bin" serve "$config" > "$log_file" 2>&1 &
		else
			log "launching $registry_label on $REGISTRY_BASE_URL with config $config, NUMA node $REGISTRY_NUMA_NODE"
			OTEL_TRACES_EXPORTER=none numactl --cpunodebind="$REGISTRY_NUMA_NODE" --membind="$REGISTRY_NUMA_NODE" "$bin" serve "$config" > "$log_file" 2>&1 &
		fi
	else
		log "launching $registry_label on $REGISTRY_BASE_URL with config $config"
		OTEL_TRACES_EXPORTER=none "$bin" serve "$config" > "$log_file" 2>&1 &
	fi
	CURRENT_PID=$!
	CURRENT_LOG=$log_file
	CURRENT_PIDFILE=$pid_file
	CURRENT_LABEL=$registry_label
	printf '%s\n' "$CURRENT_PID" > "$pid_file"
	[ "$(readlink "/proc/$CURRENT_PID/ns/net")" = "$NET_NAMESPACE" ] || die "$registry_label pid $CURRENT_PID is not running in network namespace $NET_NAMESPACE"

	i=0
	while [ "$i" -lt 600 ]; do
		if ! kill -0 "$CURRENT_PID" 2>/dev/null; then
			wait "$CURRENT_PID" 2>/dev/null || true
			CURRENT_PID=
			die "$registry_label exited while starting; see $log_file"
		fi
		if curl -fsS "$REGISTRY_BASE_URL/v2/" >/dev/null 2>&1; then
			if ! kill -0 "$CURRENT_PID" 2>/dev/null; then
				wait "$CURRENT_PID" 2>/dev/null || true
				CURRENT_PID=
				die "$registry_label exited after readiness check; see $log_file"
			fi
			check_started_registry_cmdline "$CURRENT_PID" "$config"
			log "$registry_label ready with pid $CURRENT_PID"
			return
		fi
		i=$((i + 1))
		sleep 0.1
	done
	die "$registry_label did not become ready within 60 s; see $log_file"
}

read_location_header() {
	headers=$1
	location=
	cr=$(printf '\r')
	while IFS= read -r line; do
		line=${line%"$cr"}
		case "$line" in
			Location:*|location:*)
				location=${line#*:}
				while [ "${location# }" != "$location" ]; do
					location=${location# }
				done
				;;
		esac
	done < "$headers"
	[ -n "$location" ] || die "registry upload response did not include a Location header"
	printf '%s\n' "$location"
}

absolute_upload_url() {
	location=$1
	case "$location" in
		http://*|https://*) printf '%s\n' "$location" ;;
		/*) printf '%s%s\n' "$REGISTRY_BASE_URL" "$location" ;;
		*) printf '%s/%s\n' "$REGISTRY_BASE_URL" "$location" ;;
	esac
}

append_digest_param() {
	url=$1
	digest=$2
	case "$url" in
		*\?*) printf '%s&digest=%s\n' "$url" "$digest" ;;
		*) printf '%s?digest=%s\n' "$url" "$digest" ;;
	esac
}

blob_exists() {
	digest=$1
	curl -fsI "$REGISTRY_BASE_URL/v2/$IMAGE_REPO/blobs/$digest" >/dev/null 2>&1
}

upload_blob() {
	digest=$1
	file=$2

	if blob_exists "$digest"; then
		log "blob already present: $digest"
		return
	fi

	headers="$RUN_DIR/upload-headers.$$"
	log "uploading blob $digest"
	curl -fsS -X POST -D "$headers" -o /dev/null "$REGISTRY_BASE_URL/v2/$IMAGE_REPO/blobs/uploads/"
	location=$(read_location_header "$headers")
	rm -f "$headers"
	upload_url=$(absolute_upload_url "$location")
	upload_url=$(append_digest_param "$upload_url" "$digest")
	curl -fsS -X PUT -H "Content-Type: application/octet-stream" --upload-file "$file" "$upload_url" >/dev/null
}

push_blobs() {
	while read -r blob_digest blob_file; do
		upload_blob "$blob_digest" "$blob_file" </dev/null
	done < "$BLOB_LIST"
}

manifest_exists() {
	curl -fsI -H "Accept: $MANIFEST_MEDIA_TYPE" "$REGISTRY_BASE_URL/v2/$IMAGE_REPO/manifests/$IMAGE_TAG" >/dev/null 2>&1
}

push_image() {
	upload_blob "$CONFIG_DIGEST" "$CONFIG_FILE"
	upload_blob "$LAYER_DIGEST" "$LAYER_FILE"

	if manifest_exists; then
		log "image manifest already present: $IMAGE_REPO:$IMAGE_TAG"
		return
	fi

	log "pushing OCI image manifest $IMAGE_REPO:$IMAGE_TAG"
	curl -fsS -X PUT \
		-H "Content-Type: $MANIFEST_MEDIA_TYPE" \
		--upload-file "$MANIFEST_FILE" \
		"$REGISTRY_BASE_URL/v2/$IMAGE_REPO/manifests/$IMAGE_TAG" >/dev/null
}

run_warmup_helper() {
	variant=$1
	out=$2
	request_spec=$3

	if [ "$NUMA_ACTIVE" = 1 ]; then
		if [ "$NUMA_CPUSET_ACTIVE" = 1 ]; then
			log "running $variant warmup client on NUMA node $CLIENT_NUMA_NODE CPUs $CLIENT_CPU_LIST"
			numactl --physcpubind="$CLIENT_CPU_LIST" --membind="$CLIENT_NUMA_NODE" \
				"$GO_BIN" run "$HELPER_GO" warmup \
				"$variant" \
				"$BLOB_URL" \
				"$CURRENT_PID" \
				"$LAYER_SIZE" \
				"$RANGE_SIZE_BYTES" \
				"$request_spec" \
				"$CONCURRENCY" \
				"$out"
		else
			log "running $variant warmup client on NUMA node $CLIENT_NUMA_NODE"
			numactl --cpunodebind="$CLIENT_NUMA_NODE" --membind="$CLIENT_NUMA_NODE" \
				"$GO_BIN" run "$HELPER_GO" warmup \
				"$variant" \
				"$BLOB_URL" \
				"$CURRENT_PID" \
				"$LAYER_SIZE" \
				"$RANGE_SIZE_BYTES" \
				"$request_spec" \
				"$CONCURRENCY" \
				"$out"
		fi
	else
		"$GO_BIN" run "$HELPER_GO" warmup \
			"$variant" \
			"$BLOB_URL" \
			"$CURRENT_PID" \
			"$LAYER_SIZE" \
			"$RANGE_SIZE_BYTES" \
			"$request_spec" \
			"$CONCURRENCY" \
			"$out"
	fi
}

run_load_helper() {
	variant=$1
	out=$2
	request_count=$3

	if [ "$NUMA_ACTIVE" = 1 ]; then
		if [ "$NUMA_CPUSET_ACTIVE" = 1 ]; then
			log "running $variant load client on NUMA node $CLIENT_NUMA_NODE CPUs $CLIENT_CPU_LIST"
			numactl --physcpubind="$CLIENT_CPU_LIST" --membind="$CLIENT_NUMA_NODE" \
				"$GO_BIN" run "$HELPER_GO" load \
				"$variant" \
				"$BLOB_URL" \
				"$CURRENT_PID" \
				"$CLK_TCK" \
				"$LAYER_SIZE" \
				"$RANGE_SIZE_BYTES" \
				"$request_count" \
				"$CONCURRENCY" \
				"$out"
		else
			log "running $variant load client on NUMA node $CLIENT_NUMA_NODE"
			numactl --cpunodebind="$CLIENT_NUMA_NODE" --membind="$CLIENT_NUMA_NODE" \
				"$GO_BIN" run "$HELPER_GO" load \
				"$variant" \
				"$BLOB_URL" \
				"$CURRENT_PID" \
				"$CLK_TCK" \
				"$LAYER_SIZE" \
				"$RANGE_SIZE_BYTES" \
				"$request_count" \
				"$CONCURRENCY" \
				"$out"
		fi
	else
		"$GO_BIN" run "$HELPER_GO" load \
			"$variant" \
			"$BLOB_URL" \
			"$CURRENT_PID" \
			"$CLK_TCK" \
			"$LAYER_SIZE" \
			"$RANGE_SIZE_BYTES" \
			"$request_count" \
			"$CONCURRENCY" \
			"$out"
	fi
}

run_repeated_load_helper() {
	variant=$1
	request_spec=$2
	repeats=$3
	shift 3

	if [ "$NUMA_ACTIVE" = 1 ]; then
		if [ "$NUMA_CPUSET_ACTIVE" = 1 ]; then
			log "running $variant repeated load client on NUMA node $CLIENT_NUMA_NODE CPUs $CLIENT_CPU_LIST"
			numactl --physcpubind="$CLIENT_CPU_LIST" --membind="$CLIENT_NUMA_NODE" \
				"$GO_BIN" run "$HELPER_GO" load-repeated \
				"$variant" \
				"$BLOB_URL" \
				"$CURRENT_PID" \
				"$CLK_TCK" \
				"$LAYER_SIZE" \
				"$RANGE_SIZE_BYTES" \
				"$request_spec" \
				"$CONCURRENCY" \
				"$repeats" \
				"$@"
		else
			log "running $variant repeated load client on NUMA node $CLIENT_NUMA_NODE"
			numactl --cpunodebind="$CLIENT_NUMA_NODE" --membind="$CLIENT_NUMA_NODE" \
				"$GO_BIN" run "$HELPER_GO" load-repeated \
				"$variant" \
				"$BLOB_URL" \
				"$CURRENT_PID" \
				"$CLK_TCK" \
				"$LAYER_SIZE" \
				"$RANGE_SIZE_BYTES" \
				"$request_spec" \
				"$CONCURRENCY" \
				"$repeats" \
				"$@"
		fi
	else
		"$GO_BIN" run "$HELPER_GO" load-repeated \
			"$variant" \
			"$BLOB_URL" \
			"$CURRENT_PID" \
			"$CLK_TCK" \
			"$LAYER_SIZE" \
			"$RANGE_SIZE_BYTES" \
			"$request_spec" \
			"$CONCURRENCY" \
			"$repeats" \
			"$@"
	fi
}

run_warmup_for_started_registry() {
	variant=$1
	out=$2
	request_spec=$3

	set +e
	run_warmup_helper "$variant" "$out" "$request_spec"
	status=$?
	set -e
	if [ "$status" -ne 0 ]; then
		if [ -n "${CURRENT_PID:-}" ] && ! kill -0 "$CURRENT_PID" 2>/dev/null; then
			wait "$CURRENT_PID" 2>/dev/null || true
			CURRENT_PID=
			die "$variant registry exited during warmup; see $CURRENT_LOG"
		fi
		stop_current_registry
		return "$status"
	fi
}

run_timed_for_started_registry() {
	variant=$1
	out=$2
	request_count=$3

	set +e
	run_load_helper "$variant" "$out" "$request_count"
	status=$?
	set -e
	if [ "$status" -ne 0 ]; then
		if [ -n "${CURRENT_PID:-}" ] && ! kill -0 "$CURRENT_PID" 2>/dev/null; then
			wait "$CURRENT_PID" 2>/dev/null || true
			CURRENT_PID=
			die "$variant registry exited during perf run; see $CURRENT_LOG"
		fi
		stop_current_registry
		return "$status"
	fi
}

run_repetitions_for_started_registry() {
	variant=$1
	request_spec=$2
	repeats=$3
	shift 3

	set +e
	run_repeated_load_helper "$variant" "$request_spec" "$repeats" "$@"
	status=$?
	set -e
	if [ "$status" -ne 0 ]; then
		if [ -n "${CURRENT_PID:-}" ] && ! kill -0 "$CURRENT_PID" 2>/dev/null; then
			wait "$CURRENT_PID" 2>/dev/null || true
			CURRENT_PID=
			die "$variant registry exited during repeated perf run; see $CURRENT_LOG"
		fi
		stop_current_registry
		return "$status"
	fi
}

write_result_tsv_header() {
	file=$1
	printf '%s\n' "label	auto_target_seconds	unpatched_requests	patched_requests	concurrency	chunk_mib	unpatched_cpu_s_per_gib	patched_cpu_s_per_gib	ratio	unpatched_total_cpu_s	patched_total_cpu_s	reduction_percent	patched_throughput_mib_s	unpatched_max_responses	patched_max_responses" > "$file"
}

append_result_tsv_line() {
	label=$1
	auto_target_seconds=$2
	unpatched_result=$3
	patched_result=$4
	file=$5

	line=$("$GO_BIN" run "$HELPER_GO" sweep-line "$label" "$auto_target_seconds" "$unpatched_result" "$patched_result")
	printf '%s\n' "$line"
	printf '%s\n' "$line" >> "$file"
}

run_sweep() {
	sweep_file="$RESULT_DIR/sweep.tsv"
	write_result_tsv_header "$sweep_file"

	for chunk_mib in $SWEEP_CHUNK_MIBS; do
		is_positive_int "$chunk_mib" || die "invalid SWEEP_CHUNK_MIBS entry: $chunk_mib"
		RANGE_SIZE_BYTES=$((chunk_mib * 1024 * 1024))
		[ "$RANGE_SIZE_BYTES" -le "$LAYER_SIZE_BYTES" ] || die "sweep chunk size must be <= layer size: ${chunk_mib}MiB"

		for sweep_concurrency in $SWEEP_CONCURRENCIES; do
			is_positive_int "$sweep_concurrency" || die "invalid SWEEP_CONCURRENCIES entry: $sweep_concurrency"
			CONCURRENCY=$sweep_concurrency

			for sweep_auto_target_seconds in $SWEEP_AUTO_TARGET_SECONDS; do
				AUTO_N_TARGET_SECONDS=$sweep_auto_target_seconds
				export AUTO_N_TARGET_SECONDS
				sweep_candidate_requests=$SWEEP_REQUESTS

				start_registry "unpatched" "$UNPATCHED_BIN"
				unpatched_request_label=$sweep_candidate_requests
				unpatched_outputs=
				first_unpatched_result=
				repeat=1
				while [ "$repeat" -le "$REPEATS" ]; do
					label="c${chunk_mib}m-x${CONCURRENCY}-t${sweep_auto_target_seconds}s-n${unpatched_request_label}-r${repeat}"
					unpatched_result="$RESULT_DIR/unpatched-$label.json"
					[ -n "$first_unpatched_result" ] || first_unpatched_result=$unpatched_result
					unpatched_outputs="$unpatched_outputs $unpatched_result"
					repeat=$((repeat + 1))
				done
				log "running unpatched sweep repetitions in one client process for chunk=${chunk_mib}MiB concurrency=$CONCURRENCY auto_target_seconds=$sweep_auto_target_seconds"
				run_repetitions_for_started_registry "unpatched" "$sweep_candidate_requests" "$REPEATS" $unpatched_outputs
				if [ "$sweep_candidate_requests" = "auto" ]; then
					sweep_resolved_requests=$("$GO_BIN" run "$HELPER_GO" result-requests "$first_unpatched_result")
					is_positive_int "$sweep_resolved_requests" || die "helper returned invalid unpatched request count: $sweep_resolved_requests"
					log "fixed sweep candidate N=$sweep_resolved_requests for patched build and all repetitions of chunk=${chunk_mib}MiB concurrency=$CONCURRENCY auto_target_seconds=$sweep_auto_target_seconds"
				else
					sweep_resolved_requests=$sweep_candidate_requests
				fi
				log "completed unpatched sweep runs; stopping registry before launching patched on $REGISTRY_ADDR"
				stop_current_registry

				start_registry "patched" "$PATCHED_BIN"
				patched_outputs=
				repeat=1
				while [ "$repeat" -le "$REPEATS" ]; do
					label="c${chunk_mib}m-x${CONCURRENCY}-t${sweep_auto_target_seconds}s-n${sweep_resolved_requests}-r${repeat}"
					patched_result="$RESULT_DIR/patched-$label.json"
					patched_outputs="$patched_outputs $patched_result"
					repeat=$((repeat + 1))
				done
				log "running patched sweep repetitions in one client process for chunk=${chunk_mib}MiB concurrency=$CONCURRENCY auto_target_seconds=$sweep_auto_target_seconds"
				run_repetitions_for_started_registry "patched" "$sweep_resolved_requests" "$REPEATS" $patched_outputs
				log "completed patched sweep runs; stopping registry on $REGISTRY_ADDR"
				stop_current_registry

				repeat=1
				while [ "$repeat" -le "$REPEATS" ]; do
					label="c${chunk_mib}m-x${CONCURRENCY}-t${sweep_auto_target_seconds}s-n${sweep_resolved_requests}-r${repeat}"
					unpatched_path_label="c${chunk_mib}m-x${CONCURRENCY}-t${sweep_auto_target_seconds}s-n${unpatched_request_label}-r${repeat}"
					unpatched_result="$RESULT_DIR/unpatched-$unpatched_path_label.json"
					patched_result="$RESULT_DIR/patched-$label.json"
					append_result_tsv_line "$label" "$sweep_auto_target_seconds" "$unpatched_result" "$patched_result" "$sweep_file"
					repeat=$((repeat + 1))
				done
			done
		done
	done

	"$GO_BIN" run "$HELPER_GO" sweep-summary "$sweep_file"
	"$GO_BIN" run "$HELPER_GO" sweep-best "$sweep_file"
	log "sweep results: $sweep_file"
}

run_default() {
	default_requests=$REQUESTS

	unpatched_request_label=$default_requests
	default_resolved_requests=$default_requests
	if [ "$VARIANTS" != patched ]; then
		start_registry "unpatched" "$UNPATCHED_BIN"
		unpatched_outputs=
		first_unpatched_result=
		repeat=1
		while [ "$repeat" -le "$REPEATS" ]; do
			label="default-n${unpatched_request_label}${LIFETIME_TAG}-r${repeat}"
			unpatched_result="$RESULT_DIR/unpatched-$label.json"
			[ -n "$first_unpatched_result" ] || first_unpatched_result=$unpatched_result
			unpatched_outputs="$unpatched_outputs $unpatched_result"
			repeat=$((repeat + 1))
		done
		log "running unpatched timed repetitions in one client process"
		run_repetitions_for_started_registry "unpatched" "$default_requests" "$REPEATS" $unpatched_outputs
		if [ "$default_requests" = "auto" ]; then
			default_resolved_requests=$("$GO_BIN" run "$HELPER_GO" result-requests "$first_unpatched_result")
			is_positive_int "$default_resolved_requests" || die "helper returned invalid unpatched request count: $default_resolved_requests"
			log "fixed default N=$default_resolved_requests for patched build and all repetitions"
		fi
		log "completed unpatched timed repetitions; stopping registry on $REGISTRY_ADDR"
		stop_current_registry
	fi

	if [ "$VARIANTS" != unpatched ]; then
		start_registry "patched" "$PATCHED_BIN"
		patched_outputs=
		repeat=1
		while [ "$repeat" -le "$REPEATS" ]; do
			label="default-n${default_resolved_requests}${LIFETIME_TAG}-r${repeat}"
			patched_result="$RESULT_DIR/patched-$label.json"
			patched_outputs="$patched_outputs $patched_result"
			repeat=$((repeat + 1))
		done
		log "running patched timed repetitions in one client process"
		run_repetitions_for_started_registry "patched" "$default_resolved_requests" "$REPEATS" $patched_outputs
		log "completed patched timed repetitions; stopping registry on $REGISTRY_ADDR"
		stop_current_registry
	fi

	if [ "$VARIANTS" != both ] || [ "$LIFETIMES" != 1 ]; then
		return
	fi

	if [ "$REPEATS" -eq 1 ]; then
		label="default-n${default_resolved_requests}-r1"
		unpatched_path_label="default-n${unpatched_request_label}-r1"
		UNPATCHED_RESULT="$RESULT_DIR/unpatched-$unpatched_path_label.json"
		PATCHED_RESULT="$RESULT_DIR/patched-$label.json"
		"$GO_BIN" run "$HELPER_GO" compare "$UNPATCHED_RESULT" "$PATCHED_RESULT"
		log "results: $UNPATCHED_RESULT $PATCHED_RESULT"
		return
	fi

	repeat_file="$RESULT_DIR/repeats-$(utc_timestamp).tsv"
	log "repeat results: $repeat_file"
	write_result_tsv_header "$repeat_file"
	summary_args=
	repeat=1
	while [ "$repeat" -le "$REPEATS" ]; do
		label="default-n${default_resolved_requests}-r${repeat}"
		unpatched_path_label="default-n${unpatched_request_label}-r${repeat}"
		unpatched_result="$RESULT_DIR/unpatched-$unpatched_path_label.json"
		patched_result="$RESULT_DIR/patched-$label.json"
		"$GO_BIN" run "$HELPER_GO" compare "$unpatched_result" "$patched_result"
		append_result_tsv_line "$label" "$AUTO_N_TARGET_SECONDS" "$unpatched_result" "$patched_result" "$repeat_file"
		summary_args="$summary_args $unpatched_result $patched_result"
		repeat=$((repeat + 1))
	done
	"$GO_BIN" run "$HELPER_GO" repeat-summary $summary_args
}

# LOOPBACK_NET=isolated: once the builds are done (they may need the network), re-execute this script in a
# private network namespace. The options are passed on through the environment.
enter_isolated_loopback() {
	if [ "$LOOPBACK_NET" != isolated ] || [ -n "${RUN_REPRO_HOST_NETNS:-}" ]; then
		return
	fi
	RUN_REPRO_HOST_NETNS=$NET_NAMESPACE
	export RUN_REPRO_HOST_NETNS LOOPBACK_NET NUMA_PIN CONCURRENCY REQUESTS CHUNK_SIZE_MIB REPEATS SWEEP AUTO_N_TARGET_SECONDS
	export BLOB_BYTES BLOB_COUNT WHOLE_BLOB COLD_CACHE LIFETIMES VARIANTS
	log "LOOPBACK_NET=isolated: re-executing in a private network namespace"
	exec unshare --user --map-root-user --net sh "$0"
}

# Establish and verify the network the measured processes use; sets NET_NAMESPACE and LOOPBACK_SETTINGS.
verify_loopback_net() {
	NET_NAMESPACE=$(readlink /proc/self/ns/net)
	if [ "$LOOPBACK_NET" = host ]; then
		LOOPBACK_SETTINGS="loopback_net=host net_namespace=$NET_NAMESPACE interfaces=$(ls /sys/class/net | tr '\n' ',') netfilter_rules=not-inspected(needs-root)"
	elif [ -n "${RUN_REPRO_HOST_NETNS:-}" ]; then
		[ "$NET_NAMESPACE" != "$RUN_REPRO_HOST_NETNS" ] || die "LOOPBACK_NET=isolated: still in the host network namespace $NET_NAMESPACE"
		ip link set lo up || die "LOOPBACK_NET=isolated: cannot bring up lo in $NET_NAMESPACE"
		net_interfaces=$(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')
		[ "$net_interfaces" = "lo " ] || die "LOOPBACK_NET=isolated: expected only lo in $NET_NAMESPACE, found: $net_interfaces"
		if command -v nft >/dev/null 2>&1; then
			net_rules=$(nft list ruleset) || die "LOOPBACK_NET=isolated: nft list ruleset failed in $NET_NAMESPACE"
			[ -z "$net_rules" ] || die "LOOPBACK_NET=isolated: netfilter rules present in $NET_NAMESPACE"
			net_rules="empty(nft-list-ruleset)"
		else
			net_rules="not-inspected(nft-not-installed)"
		fi
		LOOPBACK_SETTINGS="loopback_net=isolated net_namespace=$NET_NAMESPACE host_net_namespace=$RUN_REPRO_HOST_NETNS interfaces=lo netfilter_rules=$net_rules"
	else
		# First pass, still on the host: check now that the namespace can be created, enter it after the builds.
		need_cmd unshare
		need_cmd ip
		unshare --user --map-root-user --net true 2>/dev/null \
			|| die "LOOPBACK_NET=isolated: cannot create a private network namespace (unshare --user --map-root-user --net failed; unprivileged user namespaces may be disabled). Measuring nothing. Enable them, or pass --loopback-net host to measure on the host's loopback with whatever netfilter rules it has"
		LOOPBACK_SETTINGS="loopback_net=isolated (entered after the builds)"
	fi
	log "$LOOPBACK_SETTINGS"
}

write_helper
verify_loopback_net
select_registry_port
configure_numa_pinning
[ "$NUMA_ACTIVE" = 1 ] || die "refusing to measure without CPU and memory pinning"
if [ "$NUMA_CPUSET_ACTIVE" = 1 ]; then
	NUMA_SETTINGS="numa=same-socket node=$REGISTRY_NUMA_NODE registry_cpus=$REGISTRY_CPU_LIST client_cpus=$CLIENT_CPU_LIST"
else
	NUMA_SETTINGS="numa=cross-socket registry_node=$REGISTRY_NUMA_NODE client_node=$CLIENT_NUMA_NODE"
fi
log "settings: addr=$REGISTRY_ADDR blob=${LAYER_SIZE_BYTES}B blobs=$BLOB_COUNT whole_blob=$WHOLE_BLOB cold_cache=$COLD_CACHE lifetimes=$LIFETIMES variants=$VARIANTS chunk=${RANGE_SIZE_BYTES}B requests=$REQUESTS concurrency=$CONCURRENCY auto_target_seconds=$AUTO_N_TARGET_SECONDS sweep_auto_target_seconds=\"$SWEEP_AUTO_TARGET_SECONDS\" warmup=one-request-per-chunk-once-per-variant $NUMA_SETTINGS"
ensure_upstream
GO_VERSION=$("$GO_BIN" version)
PATCH_KEY=$(git hash-object "$PATCH_FILE")

UNPATCHED_BIN="$BIN_DIR/registry-unpatched"
PATCHED_BIN="$BIN_DIR/registry-patched"
UNPATCHED_KEY=$(build_key "patch=none")
PATCHED_KEY=$(build_key "patch=$PATCH_KEY")

build_registry "unpatched" "$UNPATCHED_BIN" "$UNPATCHED_KEY" "no"
build_registry "patched" "$PATCHED_BIN" "$PATCHED_KEY" "yes"
enter_isolated_loopback

if [ -n "$BLOB_BYTES" ]; then
	log "preparing $BLOB_COUNT deterministic blob(s) of $BLOB_BYTES bytes"
	BLOB_LIST="$WORK_DIR/blobs/blobs-$BLOB_BYTES-$BLOB_COUNT.list"
	"$GO_BIN" run "$HELPER_GO" blobs "$WORK_DIR/blobs" "$BLOB_BYTES" "$BLOB_COUNT" "$BLOB_LIST"
	LAYER_SIZE=$BLOB_BYTES
	BLOB_DIGESTS=$(cut -d' ' -f1 "$BLOB_LIST" | tr '\n' ' ')
else
	log "preparing deterministic OCI image artifact"
	"$GO_BIN" run "$HELPER_GO" image "$IMAGE_DIR" "$LAYER_SIZE_BYTES" "$IMAGE_VARS"
	. "$IMAGE_VARS"
	BLOB_DIGESTS=$LAYER_DIGEST
fi

# Reuse identical binaries and blobs across transports, but retain all raw results.
SESSION_ID=$(utc_timestamp)
SESSION_RESULT_DIR="$RESULT_DIR/$SESSION_ID"
SESSION_RUN_DIR="$RUN_DIR/$SESSION_ID"
mkdir -p "$SESSION_RESULT_DIR" "$SESSION_RUN_DIR"
cp "$PATCH_FILE" "$SESSION_RESULT_DIR/measured.patch"
cat > "$SESSION_RESULT_DIR/metadata.txt" <<EOF
go_version=$GO_VERSION
gotoolchain=$GOTOOLCHAIN
registry_repo=$REGISTRY_REPO_URL
registry_commit=$RESOLVED_COMMIT
patch_git_hash=$PATCH_KEY
harness_git_hash=$(git hash-object "$SCRIPT_DIR/run-repro.sh")
transports=$TRANSPORTS
protocol=HTTP/1.1
requests=$REQUESTS
concurrency=$CONCURRENCY
chunk_mib=$CHUNK_SIZE_MIB
layer_mib=$LAYER_SIZE_MB
repeats=$REPEATS
blob_bytes=$LAYER_SIZE
blob_count=$BLOB_COUNT
whole_blob=$WHOLE_BLOB
cold_cache=$COLD_CACHE
lifetimes=$LIFETIMES
variants=$VARIANTS
$NUMA_SETTINGS
$LOOPBACK_SETTINGS
EOF
for transport in $TRANSPORTS; do
	RUN_DIR="$SESSION_RUN_DIR/$transport"
	RESULT_DIR="$SESSION_RESULT_DIR/$transport"
	mkdir -p "$RUN_DIR" "$RESULT_DIR"
	if [ "$transport" = tls ]; then
		REGISTRY_TLS=1
		REGISTRY_BASE_URL="https://$REGISTRY_ADDR"
	else
		REGISTRY_TLS=0
		REGISTRY_BASE_URL="http://$REGISTRY_ADDR"
	fi
	# What the load helper requests, and the blob files in the registry storage (for --cold-cache).
	BLOB_URL=
	REPRO_COLD_FILES=
	for blob_digest in $BLOB_DIGESTS; do
		blob_hex=${blob_digest#sha256:}
		BLOB_URL="${BLOB_URL}${BLOB_URL:+,}$REGISTRY_BASE_URL/v2/$IMAGE_REPO/blobs/$blob_digest"
		if [ "$COLD_CACHE" = 1 ]; then
			REPRO_COLD_FILES="${REPRO_COLD_FILES}${REPRO_COLD_FILES:+,}$STORAGE_DIR/docker/registry/v2/blobs/sha256/$(printf '%.2s' "$blob_hex")/$blob_hex/data"
		fi
	done
	REPRO_WHOLE_BLOB=$WHOLE_BLOB
	REPRO_PINNED_CPUS=
	[ "$NUMA_CPUSET_ACTIVE" = 0 ] || REPRO_PINNED_CPUS="$REGISTRY_CPU_LIST,$CLIENT_CPU_LIST"
	export REPRO_COLD_FILES REPRO_WHOLE_BLOB REPRO_PINNED_CPUS
	log "benchmark transport: $transport (HTTP/1.1), Go: $GO_VERSION"
	log "seeding local registry storage; this is not a measured run"
	start_registry "storage-seed" "$UNPATCHED_BIN" "temporary storage-seeding registry"
	if [ -n "$BLOB_BYTES" ]; then
		push_blobs
	else
		push_image
	fi
	stop_current_registry
	if [ "$SWEEP" = 1 ]; then
		run_sweep
	else
		lifetime=1
		while [ "$lifetime" -le "$LIFETIMES" ]; do
			LIFETIME_TAG=
			[ "$LIFETIMES" = 1 ] || LIFETIME_TAG="-l$lifetime"
			[ "$LIFETIMES" = 1 ] || log "process lifetime $lifetime of $LIFETIMES"
			run_default
			lifetime=$((lifetime + 1))
		done
	fi
done
log "done; session results: $SESSION_RESULT_DIR"
