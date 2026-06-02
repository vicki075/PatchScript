#!/usr/bin/env bash
# =============================================================================
# 01-preflight.sh — UiPath AS 24.10.4 / RKE2 Pre-Patch Pre-Flight Checks
#
# Plan ref: https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/
#           pages/90751108300/Cluster+nodes+Pre-Patch+Tasks  (v1.1)
#
# Execution model:
#   Run on the PRIMARY SERVER NODE for full coverage (all 9 checks).
#   Run on EVERY NODE for local checks only (PF-05, PF-06, PF-09).
#   Script auto-detects role based on kubectl + KUBECONFIG availability.
#
# Error handling:
#   ALL applicable checks run regardless of individual failures.
#   A consolidated summary is printed at the end.
#
#   Three outcome levels:
#     [FAIL] — hard blocker; cluster or infra state makes patching unsafe.
#              Shown in RED. Script exits 1. Must be resolved before proceeding.
#     [WARN] — advisory; pre-existing or non-critical condition worth noting.
#              Shown in YELLOW. Script exits 0. Review before proceeding.
#     [PASS] — check passed.
#              Shown in GREEN.
#
#   What causes FAIL vs WARN:
#     FAIL: node not Ready, etcd unhealthy, API server down, critical disk (<rancher/<kubelet),
#           maintenance mode already set, uipathctl not found (needed for maintenance mode),
#           RKE2 package exclusion missing (yum upgrade would silently upgrade rke2 binaries)
#     WARN: pod CrashLoop/stuck Terminating (pre-existing app issues), /var or /opt low disk,
#           UiPath health check failures, stale/missing etcd snapshots
#
#   Exception: truly fatal infra errors (kubectl unavailable, topology broken)
#   still abort immediately — subsequent checks would be meaningless.
#
# etcdctl resolution (auto-detected, in priority order):
#   1. Host binary: /var/lib/rancher/rke2/bin/etcdctl
#   2. Container exec via crictl (clusters where etcdctl lives inside the etcd container)
#
# uipathctl resolution (auto-detected, in priority order):
#   1. PATH
#   2. UIPATH_INSTALLER_DIR env var:  <dir>/bin/uipathctl
#   3. /opt/UiPathAutomationSuite/latest/installer/bin/uipathctl
#   4. find /opt/UiPathAutomationSuite -name uipathctl (capped depth)
#
#   Override: UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./01-preflight.sh
#
# Exit codes:
#   0  — all checks passed (or passed with warnings only)
#   1  — one or more FAIL-level checks; must resolve before patching
# =============================================================================
set -uo pipefail

# =============================================================================
# ENVIRONMENT
# =============================================================================
if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
  export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
else
  export KUBECONFIG="/var/lib/rancher/rke2/agent/kubelet.kubeconfig"
fi
export PATH="$PATH:/usr/local/bin:/var/lib/rancher/rke2/bin"

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly UIPATH_NS="uipath"

DISCOVERED_TOTAL_NODES=0
DISCOVERED_SERVER_NODES=0
DISCOVERED_AGENT_NODES=0
DISCOVERED_SERVER_NAMES=()
DISCOVERED_AGENT_NAMES=()

readonly SNAP_DIR="/var/lib/rancher/rke2/server/db/snapshots"
readonly SNAP_MIN_COUNT=2
readonly SNAP_FRESHNESS_HOURS=24

readonly ETCD_DB_WARN_BYTES=$(( 4  * 1024 * 1024 * 1024 ))
readonly ETCD_DB_ABORT_BYTES=$(( 8 * 1024 * 1024 * 1024 ))

# Critical mount thresholds (FAIL if breached)
readonly DISK_RANCHER_MIN_GB=5
readonly DISK_KUBELET_MIN_GB=2
# Advisory mount thresholds (WARN if breached)
readonly DISK_VAR_MIN_GB=3
readonly DISK_OPT_MIN_GB=2

readonly ETCDCTL_HOST="/var/lib/rancher/rke2/bin/etcdctl"
readonly ETCD_CACERT="/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt"
readonly ETCD_CERT="/var/lib/rancher/rke2/server/tls/etcd/server-client.crt"
readonly ETCD_KEY="/var/lib/rancher/rke2/server/tls/etcd/server-client.key"
readonly ETCD_ENDPOINT="https://127.0.0.1:2379"

readonly CRICTL="/var/lib/rancher/rke2/bin/crictl"
readonly CRI_CONFIG="/var/lib/rancher/rke2/agent/etc/crictl.yaml"

ETCD_EXEC_MODE=""
ETCD_CONTAINER_ID=""
UIPATHCTL_BIN=""

readonly STATE_LOG="/opt/UiPathAutomationSuite/prepatch-state.log"

# Result accumulators
FAILED_CHECKS=()
WARNED_CHECKS=()

# Verbosity — default quiet; set by --verbose / --debug flag
VERBOSE=false

# Mid-patch mode — set with --mid-patch when running on subsequent nodes after Phase A+C+D
# have already started. Relaxes PF-01/PF-02/PF-08 expectations:
#   PF-01: nodes NotReady or cordoned → WARN (expected after prior --stop-server runs)
#   PF-02: some etcd endpoints unhealthy → WARN if quorum maintained, FAIL if quorum lost
#   PF-08: maintenance mode enabled → PASS (expected — Phase A was done)
MID_PATCH=false

# =============================================================================
# HELPERS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo -e "$(ts)  $*"; }
info() { [[ "${VERBOSE}" == "true" ]] && log "${CYAN}[INFO]${RESET}  $*" || true; }
pass() { log "${GREEN}[PASS]${RESET}  $*"; }
warn() { [[ "${VERBOSE}" == "true" ]] && log "${YELLOW}[WARN]${RESET}  $*" || true; }   # inline advisory (not recorded in summary)

# check_fail — hard blocker; recorded in FAILED_CHECKS; script exits 1 at end
check_fail() {
  local check="$1"; shift
  local msg="$*"
  log "${RED}[FAIL]${RESET}  ${msg}"
  FAILED_CHECKS+=("${check}")
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  PREFLIGHT_FAIL  ${check}  $(hostname)  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
}

# check_warn — advisory; recorded in WARNED_CHECKS; does NOT block patching
check_warn() {
  local check="$1"; shift
  local msg="$*"
  log "${YELLOW}[WARN]${RESET}  ${msg}"
  WARNED_CHECKS+=("${check}")
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  PREFLIGHT_WARN  ${check}  $(hostname)  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
}

# fail — fatal abort for infra/pre-conditions where continuing is meaningless
fail() {
  local msg="$*"
  log "${RED}[FATAL]${RESET}  ${msg}"
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  PREFLIGHT_FATAL  $(hostname)  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
  exit 1
}

avail_gb() {
  df -k "${1}" 2>/dev/null | awk 'NR==2 { printf "%d", $4/1024/1024 }'
}

# =============================================================================
# ETCDCTL ACCESS — host binary first, crictl exec fallback
# =============================================================================
init_etcd_access() {
  if [[ -x "${ETCDCTL_HOST}" ]]; then
    ETCD_EXEC_MODE="host"
    info "etcd access mode: host binary (${ETCDCTL_HOST})"
    return 0
  fi

  info "etcdctl not on host at ${ETCDCTL_HOST} — trying crictl container exec..."

  if [[ ! -x "${CRICTL}" ]]; then
    warn "crictl not found at ${CRICTL}"
    return 1
  fi

  local container_id
  container_id=$(CRI_CONFIG_FILE="${CRI_CONFIG}" \
    "${CRICTL}" ps --label io.kubernetes.container.name=etcd --quiet 2>/dev/null \
    | head -1)

  if [[ -z "${container_id}" ]]; then
    warn "No running etcd container found via crictl"
    return 1
  fi

  ETCD_EXEC_MODE="container"
  ETCD_CONTAINER_ID="${container_id}"
  info "etcd access mode: container exec (crictl, container ${container_id:0:12})"
  return 0
}

etcdctl_cmd() {
  case "${ETCD_EXEC_MODE}" in
    host)
      "${ETCDCTL_HOST}" \
        --endpoints="${ETCD_ENDPOINT}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" \
        "$@"
      ;;
    container)
      # etcd container is distroless (no sh) and this crictl version has no --env flag.
      # Pass TLS params directly as etcdctl CLI flags — works with all etcdctl 3.x builds.
      CRI_CONFIG_FILE="${CRI_CONFIG}" \
      "${CRICTL}" exec -i "${ETCD_CONTAINER_ID}" \
        etcdctl \
        --endpoints="${ETCD_ENDPOINT}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" \
        "$@"
      ;;
    *)
      echo "etcdctl not available (ETCD_EXEC_MODE='${ETCD_EXEC_MODE:-unset}')" >&2
      return 1
      ;;
  esac
}

# =============================================================================
# UIPATHCTL RESOLUTION
# =============================================================================
resolve_uipathctl() {
  if command -v uipathctl &>/dev/null; then
    UIPATHCTL_BIN="$(command -v uipathctl)"
    return 0
  fi

  if [[ -n "${UIPATH_INSTALLER_DIR:-}" ]]; then
    local candidate="${UIPATH_INSTALLER_DIR}/bin/uipathctl"
    if [[ -x "${candidate}" ]]; then
      UIPATHCTL_BIN="${candidate}"
      export PATH="$(dirname "${UIPATHCTL_BIN}"):${PATH}"
      return 0
    else
      warn "UIPATH_INSTALLER_DIR='${UIPATH_INSTALLER_DIR}' set but ${candidate} not found/executable"
    fi
  fi

  local known_paths=(
    "/opt/UiPathAutomationSuite/latest/installer/bin/uipathctl"
    "/opt/UiPathAutomationSuite/installer/bin/uipathctl"
  )
  local p
  for p in "${known_paths[@]}"; do
    if [[ -x "${p}" ]]; then
      UIPATHCTL_BIN="${p}"
      export PATH="$(dirname "${UIPATHCTL_BIN}"):${PATH}"
      return 0
    fi
  done

  local found
  found=$(find /opt/UiPathAutomationSuite -name uipathctl -maxdepth 6 -type f 2>/dev/null \
    | head -1)
  if [[ -n "${found}" && -x "${found}" ]]; then
    UIPATHCTL_BIN="${found}"
    export PATH="$(dirname "${UIPATHCTL_BIN}"):${PATH}"
    return 0
  fi

  return 1
}

# =============================================================================
# TOPOLOGY DISCOVERY — fatal on failure; PF-01/PF-02 depend on these globals
# =============================================================================
discover_topology() {
  info "Discovering cluster topology from node labels..."

  DISCOVERED_TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${DISCOVERED_TOTAL_NODES}" -eq 0 ]]; then
    fail "TOPOLOGY: No nodes returned by kubectl — API server unreachable or empty cluster"
  fi

  local role_label cp_count etcd_count
  cp_count=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  etcd_count=$(kubectl get nodes -l node-role.kubernetes.io/etcd=true \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "${cp_count}" -gt 0 ]]; then
    DISCOVERED_SERVER_NODES="${cp_count}"
    role_label="node-role.kubernetes.io/control-plane=true"
  elif [[ "${etcd_count}" -gt 0 ]]; then
    DISCOVERED_SERVER_NODES="${etcd_count}"
    role_label="node-role.kubernetes.io/etcd=true"
  else
    fail "TOPOLOGY: No control-plane or etcd role label found. Check: kubectl get nodes --show-labels"
  fi

  DISCOVERED_AGENT_NODES=$(( DISCOVERED_TOTAL_NODES - DISCOVERED_SERVER_NODES ))

  mapfile -t DISCOVERED_SERVER_NAMES < <(
    kubectl get nodes -l "${role_label}" \
      --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null
  )
  mapfile -t DISCOVERED_AGENT_NAMES < <(
    kubectl get nodes \
      -l "!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/etcd" \
      --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
      | grep -v "^$" || true
  )

  echo ""
  info "Discovered cluster topology:"
  info "  Total  : ${DISCOVERED_TOTAL_NODES}"
  info "  Server : ${DISCOVERED_SERVER_NODES}  (${role_label})"
  for n in "${DISCOVERED_SERVER_NAMES[@]:-}"; do [[ -n "${n}" ]] && info "      ${n}"; done
  info "  Agent  : ${DISCOVERED_AGENT_NODES}"
  for n in "${DISCOVERED_AGENT_NAMES[@]:-}"; do [[ -n "${n}" ]] && info "      ${n}"; done
  echo ""

  if (( DISCOVERED_SERVER_NODES % 2 == 0 )); then
    fail "TOPOLOGY: Server count (${DISCOVERED_SERVER_NODES}) is EVEN. etcd requires odd: 1, 3, 5, 7 ..."
  fi
  if [[ "${DISCOVERED_AGENT_NODES}" -lt 0 ]]; then
    fail "TOPOLOGY: Negative agent count — label mismatch. Check node labels."
  fi

  pass "TOPOLOGY: ${DISCOVERED_TOTAL_NODES} nodes — ${DISCOVERED_SERVER_NODES} server + ${DISCOVERED_AGENT_NODES} agent"
}

# =============================================================================
# PF-01 — All nodes Ready; none pre-cordoned
# Severity:
#   Normal    — FAIL if any node NotReady or cordoned (unexpected stale state)
#   Mid-patch — WARN if nodes NotReady (prior --stop-server runs expected);
#               PASS if nodes cordoned (Phase C did this intentionally)
# =============================================================================
pf01_node_readiness() {
  info "PF-01: Checking node readiness and cordon state..."
  local pf01_ok=true

  local not_ready
  not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}')
  if [[ -n "${not_ready}" ]]; then
    local nr_count; nr_count=$(echo "${not_ready}" | wc -l | tr -d ' ')
    echo "  Not-Ready nodes:"; echo "${not_ready}" | sed 's/^/    /'
    if [[ "${MID_PATCH}" == "true" ]]; then
      check_warn "PF-01" "${nr_count} node(s) not Ready — expected mid-patch (prior --stop-server runs)"
    else
      check_fail "PF-01" "One or more nodes are not Ready"
      pf01_ok=false
    fi
  fi

  local cordoned
  cordoned=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import json,sys
nodes=json.load(sys.stdin)['items']
print('\n'.join(n['metadata']['name'] for n in nodes if n.get('spec',{}).get('unschedulable')))
" 2>/dev/null || true)
  if [[ -n "${cordoned}" ]]; then
    if [[ "${MID_PATCH}" == "true" ]]; then
      local cord_count; cord_count=$(echo "${cordoned}" | wc -l | tr -d ' ')
      info "PF-01: ${cord_count} node(s) cordoned — expected mid-patch (Phase C applied)"
    else
      echo "  Pre-cordoned nodes:"; echo "${cordoned}" | sed 's/^/    /'
      check_fail "PF-01" "Nodes already SchedulingDisabled — investigate before proceeding"
      pf01_ok=false
    fi
  fi

  if [[ "${pf01_ok}" == "true" ]]; then
    if [[ "${MID_PATCH}" == "true" ]]; then
      pass "PF-01: Node state acceptable for mid-patch run"
    else
      pass "PF-01: All ${DISCOVERED_TOTAL_NODES} nodes Ready, none pre-cordoned"
    fi
  fi
}

# =============================================================================
# PF-02 — etcd: members healthy, leader elected, no alarms, DB size sane
# Severity: FAIL — etcd state is a hard gate for patching
# etcdctl auto-detected: host binary or crictl container exec
# =============================================================================
pf02_etcd_health() {
  info "PF-02: Checking etcd cluster health..."
  local pf02_ok=true
  local started_count="?" max_gb="?"

  if ! init_etcd_access; then
    check_fail "PF-02" \
      "etcdctl not available — no host binary at ${ETCDCTL_HOST} and no etcd container found via crictl"
    return
  fi

  # member list
  local members
  if ! members=$(etcdctl_cmd member list 2>/dev/null); then
    check_fail "PF-02" "etcdctl member list failed"
    pf02_ok=false
  else
    started_count=$(echo "${members}" | grep -c "started" || true)
    if [[ "${started_count}" -ne "${DISCOVERED_SERVER_NODES}" ]]; then
      echo "${members}" | sed 's/^/  /'
      check_fail "PF-02" "Expected ${DISCOVERED_SERVER_NODES} started etcd members, found ${started_count}"
      pf02_ok=false
    elif [[ "${VERBOSE}" == "true" ]]; then
      log "${CYAN}[INFO]${RESET}  PF-02: Member list:"; echo "${members}" | sed 's/^/  /'
    fi
  fi

  # endpoint health
  local health_output
  health_output=$(etcdctl_cmd endpoint health --cluster 2>&1) || true
  if echo "${health_output}" | grep -qi "unhealthy\|failed\|error"; then
    echo "${health_output}" | sed 's/^/  /'
    check_fail "PF-02" "One or more etcd endpoints reported unhealthy"
    pf02_ok=false
  elif [[ "${VERBOSE}" == "true" ]]; then
    echo "${health_output}" | sed 's/^/  /'
  fi

  # endpoint status (leader + DB)
  # Leader detection: Status.header.member_id == Status.leader
  # (etcdctl endpoint status JSON has no isLeader field — compare member_id to leader ID)
  local status_json
  if ! status_json=$(etcdctl_cmd endpoint status --cluster -w json 2>/dev/null); then
    check_fail "PF-02" "etcdctl endpoint status failed — cannot check leader or DB size"
    pf02_ok=false
  else
    local leader_count
    leader_count=$(echo "${status_json}" | python3 -c "
import json,sys
data=json.load(sys.stdin)
count=sum(1 for e in data
          if e.get('Status',{}).get('header',{}).get('member_id')
             == e.get('Status',{}).get('leader'))
print(count)
" 2>/dev/null || echo "0")
    if [[ "${leader_count}" -ne 1 ]]; then
      check_fail "PF-02" "Expected exactly 1 etcd leader, found ${leader_count}"
      pf02_ok=false
    elif [[ "${VERBOSE}" == "true" ]]; then
      log "${CYAN}[INFO]${RESET}  PF-02: Endpoint status:"
      etcdctl_cmd endpoint status --cluster -w table 2>/dev/null | sed 's/^/  /' || true
    fi

    local max_db_bytes
    max_db_bytes=$(echo "${status_json}" | python3 -c "
import json,sys
data=json.load(sys.stdin)
sizes=[e.get('Status',{}).get('dbSize',0) for e in data]
print(max(sizes) if sizes else 0)
" 2>/dev/null || echo "0")
    max_gb=$(( max_db_bytes / 1024 / 1024 / 1024 ))
    if [[ "${max_db_bytes}" -gt "${ETCD_DB_ABORT_BYTES}" ]]; then
      check_fail "PF-02" "etcd DB size ${max_gb} GB exceeds abort threshold (8 GB) — compact before patching"
      pf02_ok=false
    elif [[ "${max_db_bytes}" -gt "${ETCD_DB_WARN_BYTES}" ]]; then
      check_warn "PF-02" "etcd DB ${max_gb} GB approaching 8 GB threshold — consider compaction"
    fi
  fi

  # alarms
  local alarms
  alarms=$(etcdctl_cmd alarm list 2>/dev/null | grep -v "^$" || true)
  if [[ -n "${alarms}" ]]; then
    echo "${alarms}" | sed 's/^/  /'
    check_fail "PF-02" "etcd alarms present — resolve before patching"
    pf02_ok=false
  fi

  [[ "${pf02_ok}" == "true" ]] && \
    pass "PF-02: etcd OK — ${started_count} members, leader elected, no alarms, DB ~${max_gb} GB"
}

# =============================================================================
# PF-03 — API server /readyz clean
# Severity: FAIL — API must be healthy for kubectl operations during patching
# =============================================================================
pf03_api_readyz() {
  info "PF-03: Checking API server /readyz..."

  local result
  if ! result=$(kubectl get --raw='/readyz?verbose' 2>&1); then
    check_fail "PF-03" "kubectl get --raw='/readyz?verbose' failed"
    return
  fi
  if ! echo "${result}" | grep -q "readyz check passed"; then
    echo "${result}" | sed 's/^/  /'
    check_fail "PF-03" "API server /readyz did not return 'readyz check passed'"
    return
  fi

  pass "PF-03: API server /readyz clean"
}

# =============================================================================
# PF-04 — Pod health: CrashLoopBackOff / ImagePullBackOff / stuck Terminating
# Severity: WARN — pre-existing application issues; patching does not cause or fix these.
#           Both sub-checks run independently.
# =============================================================================
pf04_pod_health() {
  info "PF-04: Checking for pods in bad states cluster-wide..."
  local pf04_ok=true

  # Sub-check A: CrashLoopBackOff / ImagePullBackOff
  local bad_pods
  bad_pods=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 ~ /CrashLoopBackOff|ImagePullBackOff/')
  if [[ -n "${bad_pods}" ]]; then
    echo "  Pods in bad state (pre-existing — not caused by patching):"
    echo "${bad_pods}" | sed 's/^/    /'
    check_warn "PF-04" "Pods in CrashLoopBackOff or ImagePullBackOff (pre-existing app issue)"
    pf04_ok=false
  fi

  # Sub-check B: stuck Terminating > 10 min
  # Uses strptime (Python 3.6+) rather than fromisoformat (Python 3.7+)
  local stuck
  stuck=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json, sys, time, datetime
data = json.load(sys.stdin)
now = time.time()
stuck = []
for pod in data.get('items', []):
    dt = pod['metadata'].get('deletionTimestamp')
    if dt:
        ts_str = dt.rstrip('Z')
        try:
            ts = datetime.datetime.strptime(ts_str, '%Y-%m-%dT%H:%M:%S').timestamp()
            age_min = (now - ts) / 60
            if age_min > 10:
                ns = pod['metadata']['namespace']
                name = pod['metadata']['name']
                stuck.append(f'{ns}/{name}  ({age_min:.0f} min)')
        except Exception:
            pass
for s in stuck:
    print(s)
" 2>/dev/null || true)
  if [[ -n "${stuck}" ]]; then
    echo "  Stuck Terminating pods (>10 min — pre-existing):"; echo "${stuck}" | sed 's/^/    /'
    check_warn "PF-04" "Pods stuck Terminating >10 min (pre-existing — investigate separately)"
    pf04_ok=false
  fi

  [[ "${pf04_ok}" == "true" ]] && \
    pass "PF-04: No pods in CrashLoopBackOff / ImagePullBackOff / stuck Terminating"
}

# =============================================================================
# PF-05 — Disk space (LOCAL NODE)
# Severity:
#   FAIL — /var/lib/rancher, /var/lib/kubelet  (RKE2 runtime dirs — critical)
#   WARN — /var, /opt                           (advisory headroom)
# =============================================================================
pf05_disk_space() {
  info "PF-05: Checking disk space on $(hostname)..."
  local pf05_fail=false pf05_warn=false

  check_mount() {
    local mount="$1" min_gb="$2" severity="${3:-fail}"
    if [[ ! -d "${mount}" ]]; then
      warn "PF-05: ${mount} not found on $(hostname) — skipping"
      return 0
    fi
    local avail
    avail=$(avail_gb "${mount}")
    if [[ "${avail}" -lt "${min_gb}" ]]; then
      if [[ "${severity}" == "warn" ]]; then
        log "${YELLOW}[WARN]${RESET}  PF-05: ${mount} — ${avail} GB free (need ≥${min_gb} GB) [advisory]"
        pf05_warn=true
      else
        log "${RED}[FAIL]${RESET}  PF-05: ${mount} — ${avail} GB free (need ≥${min_gb} GB) [blocking]"
        pf05_fail=true
      fi
    else
      info "PF-05: ${mount} — ${avail} GB free  ✓"
    fi
  }

  check_mount /var/lib/rancher  "${DISK_RANCHER_MIN_GB}"  fail   # RKE2 data — FAIL
  check_mount /var/lib/kubelet  "${DISK_KUBELET_MIN_GB}"  fail   # kubelet    — FAIL
  check_mount /var              "${DISK_VAR_MIN_GB}"       warn   # OS space   — WARN
  check_mount /opt              "${DISK_OPT_MIN_GB}"       warn   # backup dir — WARN

  if [[ "${pf05_fail}" == "true" ]]; then
    check_fail "PF-05" "Critical disk space insufficient on $(hostname) — see above"
  elif [[ "${pf05_warn}" == "true" ]]; then
    check_warn "PF-05" "Disk space low on non-critical mount(s) on $(hostname) — see above"
  else
    pass "PF-05: Disk space OK on $(hostname)"
  fi
}

# =============================================================================
# PF-06 — RKE2 package pin (LOCAL NODE)
# Severity: FAIL — if rke2-* is not excluded, yum upgrade may silently upgrade
#           RKE2 binaries to an untested version, breaking the AS cluster.
#           Ref: UiPath AS docs — "rke2-* package upgrade will be handled via
#           the Automation Suite upgrade" (not via OS patch).
# Two remediation paths:
#   Permanent : echo 'exclude=rke2-*' >> /etc/yum.conf
#   Per-run   : yum upgrade --exclude "rke2-*"   (pass to patch orchestrator)
# =============================================================================
pf06_rke2_package_pin() {
  info "PF-06: Checking RKE2 package exclusion on $(hostname)..."

  # Match both 'exclude=rke2-*' and 'excludepkgs=rke2-*' (dnf style),
  # with optional whitespace around '=' and before 'rke2'
  if grep -Erq 'exclude(pkgs)?\s*=\s*rke2' /etc/yum.conf /etc/yum.repos.d/ /etc/dnf/dnf.conf 2>/dev/null; then
    pass "PF-06: RKE2 package exclusion confirmed on $(hostname)"
  else
    check_fail "PF-06" "RKE2 package exclusion missing on $(hostname)"
    log "${RED}[FAIL]${RESET}          Upgrading rke2-* via OS patch breaks the AS cluster."
    log "${RED}[FAIL]${RESET}          RKE2 version is managed by AS upgrade — not OS patch."
    log "${RED}[FAIL]${RESET}          Fix option 1 (permanent — recommended):"
    log "${RED}[FAIL]${RESET}            echo 'exclude=rke2-*' >> /etc/yum.conf"
    log "${RED}[FAIL]${RESET}          Fix option 2 (per patch run — pass to patch orchestrator):"
    log "${RED}[FAIL]${RESET}            yum upgrade --exclude \"rke2-*\""
  fi
}

# =============================================================================
# PF-07 — UiPath cluster health check
# Severity:
#   FAIL — uipathctl not found (required for maintenance mode enable in next phase)
#   WARN — health check itself fails (pre-existing app issue; does not block patching)
# =============================================================================
pf07_uipath_health() {
  info "PF-07: Running uipathctl health check (namespace: ${UIPATH_NS}, timeout: 10m)..."

  if [[ -z "${UIPATHCTL_BIN}" ]]; then
    check_fail "PF-07" \
      "uipathctl not found — required for maintenance mode (Phase A). Set UIPATH_INSTALLER_DIR. Example: UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./01-preflight.sh"
    return
  fi

  info "PF-07: Using ${UIPATHCTL_BIN}"

  # uipathctl prefixes ALL lines with logrus tags (INFO[XXXX] / WARN[XXXX] etc.)
  # and writes everything to stderr. Capture stderr+stdout together (2>&1),
  # then:
  #   1. Strip the logrus prefix (INFO[0009] ) from every line
  #   2. Keep only structured health check lines — those containing
  #      "Ran ", ✔, ❌, "successful", or "check" (filters out noisy lines like
  #      "application X has sync enabled", "Pod X is healthy", etc.)
  local hc_output hc_exit=0
  hc_output=$("${UIPATHCTL_BIN}" health check --namespace "${UIPATH_NS}" --timeout 10m \
    2>&1) || hc_exit=$?

  # Strip only pure logrus noise lines (INFO[0009] / WARN[0009] etc.)
  # Everything else — Checks run / ✔ / ❌ / Error lines — passes through unchanged.
  local clean_output
  clean_output=$(echo "${hc_output}" \
    | grep -vE '^(INFO|WARN|ERRO|DEBU)\[[0-9]' \
    || true)

  if [[ "${hc_exit}" -ne 0 ]]; then
    check_warn "PF-07" \
      "uipathctl health check reported failures (pre-existing app issue — does not block OS patching)"
    echo "${clean_output}" | sed 's/^/  /'
    return
  fi

  pass "PF-07: UiPath health check passed"
  if [[ "${VERBOSE}" == "true" ]]; then
    echo "${clean_output}" | sed 's/^/  /'
  fi
}

# =============================================================================
# PF-08 — No active uipathctl operation; maintenance mode not already set
# Severity: FAIL — stale maintenance mode or concurrent operation is a hard blocker
# =============================================================================
pf08_no_active_operation() {
  info "PF-08: Checking for stale maintenance mode or concurrent uipathctl operation..."
  local pf08_ok=true

  if [[ -z "${UIPATHCTL_BIN}" ]]; then
    # uipathctl already caught as FAIL in PF-07; skip maintenance check to avoid double-reporting
    info "PF-08: Skipping maintenance mode check — uipathctl not found (see PF-07)"
  else
    # is-enabled may return "true"/"false" or a descriptive string like
    # "Maintenance mode is enabled" — check both forms; negatives take priority
    local mm_raw mm_on=false
    mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled \
      --namespace "${UIPATH_NS}" 2>/dev/null || true)
    if ! echo "${mm_raw}" | grep -qi "not\|false\|disabled"; then
      echo "${mm_raw}" | grep -qi "true\|enabled" && mm_on=true || true
    fi
    if [[ "${mm_on}" == "true" ]]; then
      check_fail "PF-08" "Maintenance mode already enabled — investigate stale state before proceeding"
      pf08_ok=false
    fi
  fi

  local running
  running=$(pgrep -a uipathctl 2>/dev/null | grep -v "$$\|is-enabled\|prepatch" || true)
  if [[ -n "${running}" ]]; then
    echo "  Running uipathctl processes:"; echo "${running}" | sed 's/^/    /'
    check_fail "PF-08" "Concurrent uipathctl process detected"
    pf08_ok=false
  fi

  [[ "${pf08_ok}" == "true" ]] && \
    pass "PF-08: Maintenance mode not set; no concurrent uipathctl operation"
}

# =============================================================================
# PF-09 — etcd snapshots: configured and fresh (SERVER NODE)
# Severity: WARN — snapshots are a safety net; infra-level backups are the
#           primary protection. Missing/stale snapshots are advisory.
# =============================================================================
pf09_etcd_snapshots() {
  if ! systemctl is-active --quiet rke2-server 2>/dev/null; then
    info "PF-09: rke2-server not active on $(hostname) — skipping (agent node)"
    return 0
  fi

  info "PF-09: Checking etcd snapshots on server $(hostname)..."

  if [[ ! -d "${SNAP_DIR}" ]]; then
    check_warn "PF-09" "Snapshot directory ${SNAP_DIR} not found on $(hostname) — verify snapshot config"
    return
  fi

  if grep -qi "etcd-snapshot" /etc/rancher/rke2/config.yaml 2>/dev/null; then
    info "PF-09: Snapshot schedule configured in /etc/rancher/rke2/config.yaml"
    grep -i "etcd-snapshot" /etc/rancher/rke2/config.yaml | sed 's/^/  /'
  else
    warn "PF-09: etcd-snapshot keys absent from config.yaml — using RKE2 default (0 */12 * * *)"
  fi

  local snap_count
  snap_count=$(ls -1 "${SNAP_DIR}/" 2>/dev/null | grep -c "^etcd-snapshot-" || echo "0")
  if [[ "${snap_count}" -lt "${SNAP_MIN_COUNT}" ]]; then
    check_warn "PF-09" "Only ${snap_count} snapshot(s) found in ${SNAP_DIR} (minimum ${SNAP_MIN_COUNT})"
    return
  fi

  info "PF-09: Found ${snap_count} snapshot(s). Checking freshness..."

  local newest_file
  newest_file=$(ls -1 "${SNAP_DIR}/" \
    | grep "^etcd-snapshot-" \
    | while read -r f; do
        ep=$(echo "${f}" | grep -oE '[0-9]{9,11}' | tail -1)
        echo "${ep:-0} ${f}"
      done \
    | sort -n | tail -1 | awk '{print $2}')

  if [[ -z "${newest_file}" ]]; then
    check_warn "PF-09" "Could not identify most recent snapshot by filename epoch in ${SNAP_DIR}"
    return
  fi

  local newest_epoch age_hours
  newest_epoch=$(echo "${newest_file}" | grep -oE '[0-9]{9,11}' | tail -1)

  if [[ -z "${newest_epoch}" || "${newest_epoch}" -eq 0 ]]; then
    warn "PF-09: Cannot parse epoch from '${newest_file}' — manual freshness check required"
    pass "PF-09: ${snap_count} snapshots present on $(hostname) (freshness inconclusive)"
    return 0
  fi

  age_hours=$(( ( $(date +%s) - newest_epoch ) / 3600 ))

  if [[ "${age_hours}" -gt "${SNAP_FRESHNESS_HOURS}" ]]; then
    check_warn "PF-09" \
      "Most recent snapshot is ${age_hours}h old on $(hostname) (threshold: ${SNAP_FRESHNESS_HOURS}h) — scheduled snapshots may have stopped"
    return
  fi

  if [[ "${VERBOSE}" == "true" ]]; then
    log "${CYAN}[INFO]${RESET}  PF-09: Most recent: ${newest_file}  (${age_hours}h old)"
    rke2 etcd-snapshot ls 2>/dev/null | sed 's/^/  /' || true
  fi
  pass "PF-09: etcd snapshots OK on $(hostname) — ${snap_count} snapshots, newest ${age_hours}h old"
}

# =============================================================================
# SUMMARY — consolidated result; exit 0 on pass/warn-only, exit 1 on any FAIL
# =============================================================================
print_preflight_summary() {
  local fail_count="${#FAILED_CHECKS[@]}"
  local warn_count="${#WARNED_CHECKS[@]}"

  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  PRE-FLIGHT SUMMARY — $(hostname)   |   $(ts)${RESET}"
  echo -e "${BOLD}================================================================${RESET}"

  # Warnings block (shown regardless of fail/pass)
  if [[ "${warn_count}" -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}  Warnings — advisory, review before patching:${RESET}"
    for check in "${WARNED_CHECKS[@]}"; do
      echo -e "${YELLOW}    ⚠  ${check}${RESET}"
    done
    echo ""
  fi

  if [[ "${fail_count}" -gt 0 ]]; then
    echo -e "${RED}${BOLD}  Failed checks — must resolve before patching:${RESET}"
    for check in "${FAILED_CHECKS[@]}"; do
      echo -e "${RED}${BOLD}    ✗  ${check}${RESET}"
    done
    echo ""
    echo -e "${RED}${BOLD}  RESULT: ${fail_count} CHECK(S) FAILED — DO NOT PROCEED${RESET}"
    echo -e "${BOLD}  Resolve all failures above and re-run.${RESET}"
    echo -e "${BOLD}  State log: ${STATE_LOG}${RESET}"
    echo -e "${BOLD}================================================================${RESET}\n"
    mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
    echo "$(ts)  PREFLIGHT_FAIL_SUMMARY  $(hostname)  failed=${FAILED_CHECKS[*]}  warned=${WARNED_CHECKS[*]:-none}" \
      >> "${STATE_LOG}" 2>/dev/null || true
    return 1
  fi

  if [[ "${warn_count}" -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}  RESULT: PASSED WITH ${warn_count} WARNING(S)${RESET}"
    echo -e "${YELLOW}${BOLD}  Review warnings above before starting the patch window.${RESET}"
    echo -e "${BOLD}================================================================${RESET}\n"
    mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
    echo "$(ts)  PREFLIGHT_PASS_WITH_WARNINGS  $(hostname)  warned=${WARNED_CHECKS[*]}" \
      >> "${STATE_LOG}" 2>/dev/null || true
    return 0
  fi

  echo -e "${GREEN}${BOLD}  RESULT: ALL CHECKS PASSED ✓${RESET}"
  echo -e "${GREEN}${BOLD}  Safe to proceed to the next phase.${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  PREFLIGHT_PASS  $(hostname)" >> "${STATE_LOG}" 2>/dev/null || true
  return 0
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  # Parse flags
  for arg in "$@"; do
    case "${arg}" in
      --verbose|--debug|-v) VERBOSE=true ;;
      --help|-h)
        echo "Usage: $0 [--verbose|--debug]"
        echo "  Default: only PASS/WARN/FAIL lines + summary"
        echo "  --verbose / --debug: full output including INFO and command output"
        exit 0 ;;
    esac
  done

  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  UiPath AS 24.10.4 / RKE2 — Pre-Patch Pre-Flight Checks${RESET}"
  echo -e "${BOLD}  Node: $(hostname)   |   $(ts)${RESET}"
  [[ "${VERBOSE}" == "true" ]] && echo -e "${CYAN}  Mode: verbose${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  local is_server=false has_kubectl=false

  if systemctl is-active --quiet rke2-server 2>/dev/null; then is_server=true; fi
  if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then has_kubectl=true; fi

  if [[ "${is_server}" == "false" && "${has_kubectl}" == "false" ]]; then
    info "Detected: AGENT node — running local checks only (PF-05, PF-06)"
    echo ""
    pf05_disk_space
    pf06_rke2_package_pin
  else
    if [[ "${has_kubectl}" == "true" ]]; then
      info "Detected: SERVER node with kubectl access — running full pre-flight"
    else
      info "Detected: SERVER node (no kubectl — running server-local checks only)"
    fi

    # Resolve uipathctl once; PF-07 and PF-08 use UIPATHCTL_BIN
    echo ""
    if resolve_uipathctl; then
      info "uipathctl resolved: ${UIPATHCTL_BIN}"
    else
      warn "uipathctl not found in PATH or common locations"
      warn "Set UIPATH_INSTALLER_DIR to the installer directory and re-run"
      warn "  Example: UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./01-preflight.sh"
    fi
    echo ""

    pf05_disk_space
    echo ""
    pf06_rke2_package_pin
    echo ""
    pf09_etcd_snapshots

    if [[ "${has_kubectl}" == "true" ]]; then
      echo ""
      discover_topology   # fatal on error — PF-01/PF-02 need its globals
      pf01_node_readiness
      echo ""
      pf02_etcd_health
      echo ""
      pf03_api_readyz
      echo ""
      pf04_pod_health
      echo ""
      pf07_uipath_health
      echo ""
      pf08_no_active_operation
    else
      warn "kubectl not available — skipping cluster-wide checks (PF-01 through PF-08)"
    fi
  fi

  print_preflight_summary
  exit $?
}

main "$@"
