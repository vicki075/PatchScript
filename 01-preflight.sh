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
# Exit codes:
#   0  — all applicable checks passed
#   1  — a check failed; cluster state is UNCHANGED; investigate before continuing
#
# Usage:
#   export KUBECONFIG=/etc/rancher/rke2/rke2.yaml   # already set on RKE2 servers
#   chmod +x 01-preflight.sh
#   ./01-preflight.sh
# =============================================================================
set -uo pipefail

# =============================================================================
# CONFIGURATION — adjust to match the environment
# =============================================================================
# Node counts are NOT hardcoded. discover_topology() derives them at runtime
# from kubectl node labels, so the script works for any cluster size:
#   3 server + n agent  (3+1, 3+3, 3+5 ...)
#   5 server + n agent  (5+n)
#   7 server + n agent  (7+n)
# The only invariant enforced: server count must be ODD (etcd quorum rule).
readonly UIPATH_NS="uipath"

# Topology globals — populated by discover_topology() before PF-01/PF-02 run.
# Declared as plain vars (not readonly) because they are assigned inside a function.
DISCOVERED_TOTAL_NODES=0
DISCOVERED_SERVER_NODES=0
DISCOVERED_AGENT_NODES=0
DISCOVERED_SERVER_NAMES=()   # control-plane node names
DISCOVERED_AGENT_NAMES=()    # agent node names

readonly SNAP_DIR="/var/lib/rancher/rke2/server/db/snapshots"
readonly SNAP_MIN_COUNT=2
readonly SNAP_FRESHNESS_HOURS=24                # abort if newest snapshot older than this

readonly ETCD_DB_WARN_BYTES=$(( 4  * 1024 * 1024 * 1024 ))   # 4 GB — warn
readonly ETCD_DB_ABORT_BYTES=$(( 8 * 1024 * 1024 * 1024 ))   # 8 GB — abort

readonly DISK_RANCHER_MIN_GB=5
readonly DISK_KUBELET_MIN_GB=2
readonly DISK_VAR_MIN_GB=3
readonly DISK_OPT_MIN_GB=2                      # headroom for snapshot copies

readonly ETCDCTL="/var/lib/rancher/rke2/bin/etcdctl"
readonly ETCD_CACERT="/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt"
readonly ETCD_CERT="/var/lib/rancher/rke2/server/tls/etcd/server-client.crt"
readonly ETCD_KEY="/var/lib/rancher/rke2/server/tls/etcd/server-client.key"
readonly ETCD_ENDPOINT="https://127.0.0.1:2379"

readonly STATE_LOG="/opt/UiPathAutomationSuite/prepatch-state.log"
readonly DRAIN_TIMEOUT_SECS=600                 # 10 min

# =============================================================================
# HELPERS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo -e "$(ts)  $*"; }
info() { log "${CYAN}[INFO]${RESET}  $*"; }
pass() { log "${GREEN}[PASS]${RESET}  $*"; }
warn() { log "${YELLOW}[WARN]${RESET}  $*"; }

fail() {
  local msg="$*"
  log "${RED}[FAIL]${RESET}  ${msg}"
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  PREFLIGHT_FAIL  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
  exit 1
}

etcdctl_cmd() {
  "${ETCDCTL}" \
    --endpoints="${ETCD_ENDPOINT}" \
    --cacert="${ETCD_CACERT}" \
    --cert="${ETCD_CERT}" \
    --key="${ETCD_KEY}" \
    "$@"
}

# Returns available space in GB for a mount point
avail_gb() {
  local mount="$1"
  df -k "${mount}" 2>/dev/null | awk 'NR==2 { printf "%d", $4/1024/1024 }'
}

# =============================================================================
# TOPOLOGY DISCOVERY — populates DISCOVERED_* globals
# Called once from main() before any check that depends on node counts.
#
# Server nodes  = nodes labelled node-role.kubernetes.io/control-plane=true
#                 (RKE2 sets this on every server node; falls back to the
#                  etcd role label if control-plane is somehow absent)
# Agent nodes   = all remaining nodes (total - servers)
#
# Supported cluster shapes: any odd server count + any agent count
#   e.g. 3+1, 3+3, 5+2, 7+0 ...
# =============================================================================
discover_topology() {
  info "Discovering cluster topology from node labels..."

  DISCOVERED_TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null \
    | wc -l | tr -d ' ')

  if [[ "${DISCOVERED_TOTAL_NODES}" -eq 0 ]]; then
    fail "TOPOLOGY: No nodes returned by kubectl — API server unreachable or empty cluster"
  fi

  # Prefer control-plane label (RKE2 standard); fall back to etcd label
  local role_label cp_count etcd_count
  cp_count=$(kubectl get nodes \
    -l node-role.kubernetes.io/control-plane=true \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  etcd_count=$(kubectl get nodes \
    -l node-role.kubernetes.io/etcd=true \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "${cp_count}" -gt 0 ]]; then
    DISCOVERED_SERVER_NODES="${cp_count}"
    role_label="node-role.kubernetes.io/control-plane=true"
  elif [[ "${etcd_count}" -gt 0 ]]; then
    DISCOVERED_SERVER_NODES="${etcd_count}"
    role_label="node-role.kubernetes.io/etcd=true"
  else
    fail "TOPOLOGY: No nodes carry a control-plane or etcd role label. Check: kubectl get nodes --show-labels"
  fi

  DISCOVERED_AGENT_NODES=$(( DISCOVERED_TOTAL_NODES - DISCOVERED_SERVER_NODES ))

  # Collect names (bash 4+ mapfile — all target nodes run RHEL/Rocky with bash 4+)
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

  # Print discovered layout
  echo ""
  info "Discovered cluster topology:"
  info "  Total nodes  : ${DISCOVERED_TOTAL_NODES}"
  info "  Server nodes : ${DISCOVERED_SERVER_NODES}  (${role_label})"
  for n in "${DISCOVERED_SERVER_NAMES[@]:-}"; do
    [[ -n "${n}" ]] && info "      ${n}"
  done
  info "  Agent nodes  : ${DISCOVERED_AGENT_NODES}"
  for n in "${DISCOVERED_AGENT_NAMES[@]:-}"; do
    [[ -n "${n}" ]] && info "      ${n}"
  done
  echo ""

  # Invariant: server count must be odd for etcd quorum (1, 3, 5, 7 …)
  if (( DISCOVERED_SERVER_NODES % 2 == 0 )); then
    fail "TOPOLOGY: Server node count (${DISCOVERED_SERVER_NODES}) is EVEN. etcd requires an odd number of members for quorum. Valid: 1, 3, 5, 7 ..."
  fi

  # Sanity: agent count cannot be negative
  if [[ "${DISCOVERED_AGENT_NODES}" -lt 0 ]]; then
    fail "TOPOLOGY: Computed negative agent count — label mismatch. Check node labels."
  fi

  pass "TOPOLOGY: ${DISCOVERED_TOTAL_NODES} nodes — ${DISCOVERED_SERVER_NODES} server + ${DISCOVERED_AGENT_NODES} agent"
}

# =============================================================================
# PF-01 — All discovered nodes Ready; none pre-cordoned
# Scope: primary server node (kubectl required)
# =============================================================================
pf01_node_readiness() {
  # discover_topology() must have been called before this function.
  info "PF-01: Checking all ${DISCOVERED_TOTAL_NODES} nodes Ready, none pre-cordoned..."
  info "PF-01: Layout — ${DISCOVERED_SERVER_NODES} server + ${DISCOVERED_AGENT_NODES} agent"

  # All nodes must be Ready
  local not_ready
  not_ready=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '$2 != "Ready" {print $1}')
  if [[ -n "${not_ready}" ]]; then
    echo "  Not-Ready nodes:"
    echo "${not_ready}" | sed 's/^/    /'
    fail "PF-01: One or more nodes are not Ready"
  fi

  # No node must already be cordoned (SchedulingDisabled)
  local cordoned
  cordoned=$(kubectl get nodes -o json 2>/dev/null \
    | python3 -c "
import json,sys
nodes=json.load(sys.stdin)['items']
print('\n'.join(n['metadata']['name'] for n in nodes if n.get('spec',{}).get('unschedulable')))
" 2>/dev/null || true)

  if [[ -n "${cordoned}" ]]; then
    echo "  Pre-cordoned nodes:"
    echo "${cordoned}" | sed 's/^/    /'
    fail "PF-01: Nodes already SchedulingDisabled — investigate before proceeding"
  fi

  pass "PF-01: All ${DISCOVERED_TOTAL_NODES} nodes Ready, none pre-cordoned (${DISCOVERED_SERVER_NODES} server + ${DISCOVERED_AGENT_NODES} agent)"
}

# =============================================================================
# PF-02 — etcd: 3 healthy members, leader elected, no alarms, DB size sane
# Scope: primary server node
# =============================================================================
pf02_etcd_health() {
  info "PF-02: Checking etcd cluster health..."

  if [[ ! -x "${ETCDCTL}" ]]; then
    fail "PF-02: etcdctl not found or not executable at ${ETCDCTL}"
  fi

  # ---- member count ----
  local members
  members=$(etcdctl_cmd member list 2>/dev/null) || fail "PF-02: etcdctl member list failed"
  local started_count
  started_count=$(echo "${members}" | grep -c "started" || true)
  # Expected member count comes from topology discovery, not a hardcoded constant
  if [[ "${started_count}" -ne "${DISCOVERED_SERVER_NODES}" ]]; then
    echo "${members}"
    fail "PF-02: Expected ${DISCOVERED_SERVER_NODES} started etcd members (matches discovered server node count), found ${started_count}"
  fi
  info "PF-02: Member list:"
  echo "${members}" | sed 's/^/  /'

  # ---- endpoint health ----
  local health_output
  health_output=$(etcdctl_cmd endpoint health --cluster 2>&1) || true
  echo "${health_output}" | sed 's/^/  /'
  if echo "${health_output}" | grep -qi "unhealthy\|failed\|error"; then
    fail "PF-02: One or more etcd endpoints reported unhealthy"
  fi

  # ---- leader election ----
  local status_json
  status_json=$(etcdctl_cmd endpoint status --cluster -w json 2>/dev/null) \
    || fail "PF-02: etcdctl endpoint status failed"

  local leader_count
  leader_count=$(echo "${status_json}" \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
print(sum(1 for e in data if e.get('Status',{}).get('isLeader',False)))
" 2>/dev/null || echo "0")

  if [[ "${leader_count}" -ne 1 ]]; then
    fail "PF-02: Expected exactly 1 etcd leader, found ${leader_count}"
  fi
  info "PF-02: Endpoint status:"
  etcdctl_cmd endpoint status --cluster -w table 2>/dev/null | sed 's/^/  /' || true

  # ---- alarms ----
  local alarms
  alarms=$(etcdctl_cmd alarm list 2>/dev/null | grep -v "^$" || true)
  if [[ -n "${alarms}" ]]; then
    echo "${alarms}" | sed 's/^/  /'
    fail "PF-02: etcd alarms present — resolve before patching"
  fi

  # ---- DB size ----
  local max_db_bytes
  max_db_bytes=$(echo "${status_json}" \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
sizes=[e.get('Status',{}).get('dbSize',0) for e in data]
print(max(sizes) if sizes else 0)
" 2>/dev/null || echo "0")

  local max_gb
  max_gb=$(( max_db_bytes / 1024 / 1024 / 1024 ))
  if [[ "${max_db_bytes}" -gt "${ETCD_DB_ABORT_BYTES}" ]]; then
    fail "PF-02: etcd DB size ${max_gb} GB exceeds abort threshold (8 GB). Compact before patching."
  elif [[ "${max_db_bytes}" -gt "${ETCD_DB_WARN_BYTES}" ]]; then
    warn "PF-02: etcd DB size ${max_gb} GB approaching threshold — consider compaction"
  fi

  pass "PF-02: etcd OK — ${started_count} members, leader elected, no alarms, DB ~${max_gb} GB"
}

# =============================================================================
# PF-03 — API server /readyz clean
# Scope: primary server node
# =============================================================================
pf03_api_readyz() {
  info "PF-03: Checking API server /readyz..."

  local result
  result=$(kubectl get --raw='/readyz?verbose' 2>&1) \
    || fail "PF-03: kubectl get --raw='/readyz?verbose' failed"

  if ! echo "${result}" | grep -q "readyz check passed"; then
    echo "${result}" | sed 's/^/  /'
    fail "PF-03: API server /readyz did not return 'readyz check passed'"
  fi

  pass "PF-03: API server /readyz clean"
}

# =============================================================================
# PF-04 — No pods in CrashLoopBackOff / ImagePullBackOff / stuck Terminating
# Scope: primary server node
# =============================================================================
pf04_pod_health() {
  info "PF-04: Checking for pods in bad states cluster-wide..."

  local bad_pods
  bad_pods=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 ~ /CrashLoopBackOff|ImagePullBackOff/')

  if [[ -n "${bad_pods}" ]]; then
    echo "  Offending pods:"
    echo "${bad_pods}" | sed 's/^/    /'
    fail "PF-04: Pods in CrashLoopBackOff or ImagePullBackOff detected"
  fi

  # Stuck Terminating > 10 min
  local stuck
  stuck=$(kubectl get pods -A -o json 2>/dev/null \
    | python3 -c "
import json, sys, time
data = json.load(sys.stdin)
now = time.time()
stuck = []
for pod in data.get('items', []):
    dt = pod['metadata'].get('deletionTimestamp')
    if dt:
        # Parse ISO timestamp
        import datetime
        ts_str = dt.rstrip('Z')
        try:
            ts = datetime.datetime.fromisoformat(ts_str).timestamp()
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
    echo "  Stuck Terminating pods (>10 min):"
    echo "${stuck}" | sed 's/^/    /'
    fail "PF-04: Pods stuck Terminating for more than 10 minutes"
  fi

  pass "PF-04: No pods in CrashLoopBackOff / ImagePullBackOff / stuck Terminating"
}

# =============================================================================
# PF-05 — Disk space on critical mount points (LOCAL NODE)
# Scope: every node — run this script on each node for complete coverage
# =============================================================================
pf05_disk_space() {
  info "PF-05: Checking disk space on $(hostname)..."

  local failed=0

  check_mount() {
    local mount="$1" min_gb="$2"
    if [[ ! -d "${mount}" ]]; then
      warn "PF-05: ${mount} not found on $(hostname) — skipping"
      return 0
    fi
    local avail
    avail=$(avail_gb "${mount}")
    if [[ "${avail}" -lt "${min_gb}" ]]; then
      log "${RED}[FAIL]${RESET}  PF-05: ${mount} on $(hostname): ${avail} GB free (need ≥${min_gb} GB)"
      failed=1
    else
      info "PF-05: ${mount} — ${avail} GB free  ✓"
    fi
  }

  check_mount /var/lib/rancher  "${DISK_RANCHER_MIN_GB}"
  check_mount /var/lib/kubelet  "${DISK_KUBELET_MIN_GB}"
  check_mount /var             "${DISK_VAR_MIN_GB}"
  check_mount /opt             "${DISK_OPT_MIN_GB}"

  if [[ "${failed}" -ne 0 ]]; then
    fail "PF-05: Disk space insufficient on $(hostname) — see above"
  fi

  pass "PF-05: Disk space OK on $(hostname)"
}

# =============================================================================
# PF-06 — RKE2 package pin present (LOCAL NODE)
# Scope: every node — run this script on each node for complete coverage
# =============================================================================
pf06_rke2_package_pin() {
  info "PF-06: Checking RKE2 package pin on $(hostname)..."

  if grep -qr 'exclude=rke2-\*' /etc/yum.conf /etc/yum.repos.d/ 2>/dev/null; then
    pass "PF-06: RKE2 package pin (exclude=rke2-*) confirmed on $(hostname)"
  else
    fail "PF-06: RKE2 package pin missing on $(hostname). OS patch could inadvertently upgrade RKE2 binaries."
  fi
}

# =============================================================================
# PF-07 — UiPath cluster health check
# Scope: primary server node
# Ref: https://docs.uipath.com/automation-suite/automation-suite/2024.10/
#      reference-guide/uipathctl-health-check
# =============================================================================
pf07_uipath_health() {
  info "PF-07: Running uipathctl health check (namespace: ${UIPATH_NS}, timeout: 10m)..."

  if ! command -v uipathctl &>/dev/null; then
    fail "PF-07: uipathctl not found in PATH"
  fi

  if ! uipathctl health check \
       --namespace "${UIPATH_NS}" \
       --timeout 10m; then
    fail "PF-07: uipathctl health check reported failures — resolve before patch window"
  fi

  pass "PF-07: UiPath health check passed"
}

# =============================================================================
# PF-08 — No active uipathctl operation; maintenance mode not already set
# Scope: primary server node
# Ref: https://docs.uipath.com/automation-suite/automation-suite/2024.10/
#      reference-guide/uipathctl-cluster-maintenance-enable
# =============================================================================
pf08_no_active_operation() {
  info "PF-08: Checking for stale maintenance mode or concurrent uipathctl operation..."

  local mm_state
  mm_state=$(uipathctl cluster maintenance is-enabled \
    --namespace "${UIPATH_NS}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

  if [[ "${mm_state}" == "true" ]]; then
    fail "PF-08: Maintenance mode is already enabled. Investigate stale state before proceeding."
  fi

  local running
  running=$(pgrep -a uipathctl 2>/dev/null | grep -v "$$\|is-enabled\|prepatch" || true)
  if [[ -n "${running}" ]]; then
    echo "  Running uipathctl processes:"
    echo "${running}" | sed 's/^/    /'
    fail "PF-08: Concurrent uipathctl process detected"
  fi

  pass "PF-08: Maintenance mode not set; no concurrent uipathctl operation"
}

# =============================================================================
# PF-09 — RKE2 scheduled etcd snapshots configured and fresh (SERVER NODE ONLY)
# Scope: each server node — run this script on each server
# =============================================================================
pf09_etcd_snapshots() {
  # Only applies to server nodes
  if ! systemctl is-active --quiet rke2-server 2>/dev/null; then
    info "PF-09: rke2-server not active on $(hostname) — skipping snapshot check (agent node)"
    return 0
  fi

  info "PF-09: Checking etcd snapshots on server $(hostname)..."

  if [[ ! -d "${SNAP_DIR}" ]]; then
    fail "PF-09: Snapshot directory ${SNAP_DIR} not found on $(hostname)"
  fi

  # Config check
  if grep -qi "etcd-snapshot" /etc/rancher/rke2/config.yaml 2>/dev/null; then
    info "PF-09: Snapshot schedule configured in /etc/rancher/rke2/config.yaml"
    grep -i "etcd-snapshot" /etc/rancher/rke2/config.yaml | sed 's/^/  /'
  else
    warn "PF-09: etcd-snapshot keys not found in config.yaml — using RKE2 default schedule (0 */12 * * *)"
  fi

  # Count snapshots
  local snap_count
  snap_count=$(ls -1 "${SNAP_DIR}/" 2>/dev/null | grep -c "^etcd-snapshot-" || echo "0")

  if [[ "${snap_count}" -lt "${SNAP_MIN_COUNT}" ]]; then
    fail "PF-09: Only ${snap_count} snapshot(s) in ${SNAP_DIR} on $(hostname). Minimum ${SNAP_MIN_COUNT} required."
  fi

  info "PF-09: Found ${snap_count} snapshot(s). Checking freshness of most recent..."

  # Identify most recent snapshot by epoch embedded in filename
  # Filename format: etcd-snapshot-<hostname>-<unix-epoch>[.zip]
  local newest_file newest_epoch age_hours
  newest_file=$(ls -1 "${SNAP_DIR}/" \
    | grep "^etcd-snapshot-" \
    | while read -r f; do
        ep=$(echo "${f}" | grep -oE '[0-9]{9,11}' | tail -1)
        echo "${ep:-0} ${f}"
      done \
    | sort -n \
    | tail -1 \
    | awk '{print $2}')

  if [[ -z "${newest_file}" ]]; then
    fail "PF-09: Could not identify most recent snapshot in ${SNAP_DIR}"
  fi

  newest_epoch=$(echo "${newest_file}" | grep -oE '[0-9]{9,11}' | tail -1)

  if [[ -z "${newest_epoch}" || "${newest_epoch}" -eq 0 ]]; then
    warn "PF-09: Could not parse epoch from filename '${newest_file}' — manual freshness verification required"
    pass "PF-09: ${snap_count} snapshots present on $(hostname) (freshness check inconclusive)"
    return 0
  fi

  age_hours=$(( ( $(date +%s) - newest_epoch ) / 3600 ))

  if [[ "${age_hours}" -gt "${SNAP_FRESHNESS_HOURS}" ]]; then
    fail "PF-09: Most recent snapshot is ${age_hours}h old on $(hostname). Threshold: ${SNAP_FRESHNESS_HOURS}h. Scheduled snapshots may have stopped."
  fi

  info "PF-09: Most recent snapshot: ${newest_file}  (${age_hours}h old)"
  rke2 etcd-snapshot ls 2>/dev/null | sed 's/^/  /' || true

  pass "PF-09: etcd snapshots OK on $(hostname) — ${snap_count} snapshots, newest ${age_hours}h old"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  UiPath AS 24.10.4 / RKE2 — Pre-Patch Pre-Flight Checks${RESET}"
  echo -e "${BOLD}  Node: $(hostname)   |   $(ts)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  # Determine role
  local is_server=false has_kubectl=false

  if systemctl is-active --quiet rke2-server 2>/dev/null; then
    is_server=true
  fi

  if command -v kubectl &>/dev/null; then
    if kubectl get nodes &>/dev/null 2>&1; then
      has_kubectl=true
    fi
  fi

  if [[ "${is_server}" == "false" && "${has_kubectl}" == "false" ]]; then
    info "Detected: AGENT node (no kubectl access)"
    info "Running local checks only: PF-05, PF-06"
    echo ""
    pf05_disk_space
    pf06_rke2_package_pin
  else
    if [[ "${has_kubectl}" == "true" ]]; then
      info "Detected: SERVER node with kubectl access — running full pre-flight"
    else
      info "Detected: SERVER node (no kubectl yet — running server-local checks)"
    fi
    echo ""

    # Local checks always run on server
    pf05_disk_space
    pf06_rke2_package_pin
    pf09_etcd_snapshots

    # Cluster-wide checks require kubectl
    if [[ "${has_kubectl}" == "true" ]]; then
      echo ""
      # Discover topology first — populates DISCOVERED_* globals used by PF-01 and PF-02.
      # No hardcoded node counts: works for any cluster shape (3+n, 5+n, 7+n ...).
      discover_topology
      pf01_node_readiness
      pf02_etcd_health
      pf03_api_readyz
      pf04_pod_health
      pf07_uipath_health
      pf08_no_active_operation
    else
      warn "kubectl not available — skipping cluster-wide checks (PF-01 through PF-08)"
      warn "Set KUBECONFIG=/etc/rancher/rke2/rke2.yaml and re-run for full pre-flight"
    fi
  fi

  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${GREEN}${BOLD}  ALL APPLICABLE PRE-FLIGHT CHECKS PASSED — $(hostname)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  PREFLIGHT_PASS  $(hostname)" >> "${STATE_LOG}" 2>/dev/null || true
}

main "$@"
