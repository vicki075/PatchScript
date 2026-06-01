#!/usr/bin/env bash
# =============================================================================
# 03-prepatch.sh — UiPath AS 24.10.4 / RKE2 Pre-Patch Execution
#
# Plan ref: https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/
#           pages/90751108300/Cluster+nodes+Pre-Patch+Tasks  (v1.1, Phases A/C/D)
#
# MODES (pass as first argument):
#
#   --global  (default, run from PRIMARY SERVER NODE)
#             Phase A: Enable UiPath maintenance mode
#             Phase C: Cordon all 6 nodes
#             Identifies etcd leader (print for operator — use output to sequence D)
#
#   --stop-agent  (run LOCALLY on each AGENT node, one at a time)
#             Phase D: Drain → stop rke2-agent → rke2-killall.sh → verify clean
#
#   --stop-server  (run LOCALLY on each SERVER node, non-leader first, leader last)
#             Phase D: etcd quorum check → drain → stop rke2-server →
#                      rke2-killall.sh → verify clean → write PREPATCH_COMPLETE (leader)
#
#   --identify-leader  (run from any server node with etcdctl access)
#             Prints which server is the current etcd leader. Use to determine
#             server stop order for --stop-server runs.
#
# ORCHESTRATION ORDER (called by the OS patch orchestrator):
#   Cluster shape is detected at runtime — works for any odd server count + any
#   agent count (3+1, 3+3, 5+n, 7+n ...). Run --global once from the primary
#   server; then --stop-agent on every agent; then --stop-server on every server.
#
#   1. ./03-prepatch.sh --global              # primary server (1 run)
#   2. ./03-prepatch.sh --stop-agent          # each agent node (N runs, one per agent)
#   3. ./03-prepatch.sh --stop-server         # each server, non-leader first, leader LAST
#
# ABORT BEHAVIOUR: any failure exits immediately with code 1.
# NO automatic rollback — human triage required on failure.
#
# Exit codes:
#   0  — mode completed successfully
#   1  — failure; investigate state before continuing or re-running
# =============================================================================
set -uo pipefail

# =============================================================================
# ENVIRONMENT — detect node type, export KUBECONFIG and PATH
#
# --global and --stop-server run on server nodes → rke2.yaml
# --stop-agent runs on agent nodes               → kubelet.kubeconfig
#   (agent KUBECONFIG is read-only and scoped to the local node;
#    no cluster-wide kubectl calls are made in --stop-agent mode)
#
# PATH is extended the same way on both roles so that rke2-killall.sh,
# etcdctl, and kubectl are reachable without hardcoded full paths.
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
readonly MAINTENANCE_TIMEOUT="30m"

readonly ETCDCTL="/var/lib/rancher/rke2/bin/etcdctl"
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
readonly MARKER_DIR="/opt/UiPathAutomationSuite"

readonly DRAIN_TIMEOUT_SECS=600      # 10 min — abort if node-drain.service hangs
readonly STOP_TIMEOUT_SECS=300       # 5 min  — abort if rke2-server/agent hangs
readonly KILLALL_TIMEOUT_SECS=120    # 2 min  — abort if rke2-killall.sh hangs

# =============================================================================
# HELPERS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# Verbosity — default quiet; set by --verbose / --debug flag
VERBOSE=false

ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo -e "$(ts)  $*"; }
info() { [[ "${VERBOSE}" == "true" ]] && log "${CYAN}[INFO]${RESET}  $*" || true; }
pass() { log "${GREEN}[PASS]${RESET}  $*"; }
warn() { [[ "${VERBOSE}" == "true" ]] && log "${YELLOW}[WARN]${RESET}  $*" || true; }

fail() {
  local msg="$*"
  log "${RED}[FAIL]${RESET}  ${msg}"
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  FAIL  $(hostname)  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
  echo ""
  echo -e "${RED}${BOLD}ABORT: ${msg}${RESET}"
  echo -e "${RED}${BOLD}NO automatic rollback. Investigate cluster state before retrying.${RESET}\n"
  exit 1
}

state_log() {
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  $*" >> "${STATE_LOG}" 2>/dev/null || true
}

# maintenance_is_enabled <raw-output>
# Returns 0 if maintenance mode is on, 1 if off.
# Handles both boolean output ("true"/"false") and descriptive strings
# ("Maintenance mode is enabled" / "Maintenance mode is not enabled").
maintenance_is_enabled() {
  local raw="$1"
  # Explicit negatives take priority
  echo "${raw}" | grep -qi "not\|false\|disabled" && return 1
  # Positive match
  echo "${raw}" | grep -qi "true\|enabled" && return 0
  return 1
}

init_etcd_access() {
  if [[ -x "${ETCDCTL}" ]]; then
    ETCD_EXEC_MODE="host"
    return 0
  fi
  if [[ ! -x "${CRICTL}" ]]; then return 1; fi
  local container_id
  container_id=$(CRI_CONFIG_FILE="${CRI_CONFIG}" \
    "${CRICTL}" ps --label io.kubernetes.container.name=etcd --quiet 2>/dev/null | head -1)
  if [[ -z "${container_id}" ]]; then return 1; fi
  ETCD_EXEC_MODE="container"
  ETCD_CONTAINER_ID="${container_id}"
  return 0
}

etcdctl_cmd() {
  case "${ETCD_EXEC_MODE}" in
    host)
      "${ETCDCTL}" \
        --endpoints="${ETCD_ENDPOINT}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" \
        "$@"
      ;;
    container)
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
      echo "etcdctl not available" >&2; return 1 ;;
  esac
}

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

usage() {
  echo ""
  echo "Usage: $0 [--global | --stop-agent | --stop-server | --identify-leader]"
  echo ""
  echo "  --global            Enable maintenance mode + cordon all nodes (primary server)"
  echo "  --stop-agent        Drain and stop this agent node (run locally on agent)"
  echo "  --stop-server       Drain and stop this server node (run locally on server, leader last)"
  echo "  --identify-leader   Print current etcd leader (any server node)"
  echo ""
  echo "Ref: Plan v1.1 — Phases A, C, D"
  echo ""
}

# =============================================================================
# MODE: --identify-leader
# Helper — run before sequencing server stops to know which server is last
# =============================================================================
mode_identify_leader() {
  echo -e "\n${BOLD}--- Identifying etcd leader ---${RESET}"

  if ! init_etcd_access; then
    fail "--identify-leader: etcdctl not available (no host binary and no etcd container via crictl)"
  fi

  if [[ "${VERBOSE}" == "true" ]]; then
    info "etcd endpoint status (cluster-wide):"
    etcdctl_cmd endpoint status --cluster -w table 2>/dev/null | sed 's/^/  /' \
      || fail "--identify-leader: etcdctl endpoint status failed"
    echo ""
  fi

  log "${CYAN}[INFO]${RESET}  Leader summary:"
  etcdctl_cmd endpoint status --cluster -w json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for e in data:
    ep = e.get('Endpoint','?')
    st = e.get('Status', {})
    member_id = st.get('header', {}).get('member_id', -1)
    leader_id  = st.get('leader', -2)
    is_leader  = (member_id == leader_id)
    label = '  <<< LEADER — stop this server LAST' if is_leader else ''
    print(f'  {ep}{label}')
" 2>/dev/null || log "${YELLOW}[WARN]${RESET}  Could not parse leader from JSON output — re-run with --verbose for table"

  echo ""
}

# =============================================================================
# MODE: --global  (Phase A + Phase C)
# Run from primary server node
# =============================================================================
mode_global() {
  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  Phase A + C — Maintenance Mode + Cordon All Nodes${RESET}"
  echo -e "${BOLD}  Server: $(hostname)   |   $(ts)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  # Guard: kubectl must be available
  if ! command -v kubectl &>/dev/null || ! kubectl get nodes &>/dev/null 2>&1; then
    fail "--global: kubectl not available. Run from the primary server node with KUBECONFIG set."
  fi

  if ! resolve_uipathctl; then
    fail "--global: uipathctl not found — set UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer"
  fi
  info "uipathctl: ${UIPATHCTL_BIN}"

  # ---- Phase A: Enable Maintenance Mode ----
  echo -e "${BOLD}--- Phase A: Enable UiPath Maintenance Mode ---${RESET}"
  info "Ref: https://docs.uipath.com/automation-suite/automation-suite/2024.10/reference-guide/uipathctl-cluster-maintenance-enable"
  echo ""

  # Confirm 01-preflight passed (PF-08 verifies maintenance mode is off)
  local mm_raw
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled \
    --namespace "${UIPATH_NS}" 2>/dev/null || true)

  if maintenance_is_enabled "${mm_raw}"; then
    fail "Phase A: Maintenance mode is already enabled. Was --global run twice? Check state log."
  fi

  info "Enabling maintenance mode (namespace: ${UIPATH_NS}, timeout: ${MAINTENANCE_TIMEOUT})..."
  info "Command: ${UIPATHCTL_BIN} cluster maintenance enable --namespace ${UIPATH_NS} --timeout ${MAINTENANCE_TIMEOUT} --force"
  echo ""

  # Suppress logrus INFO[xxxx] and k8s W0601... warnings (stderr); keep stdout ("Successfully enabled...")
  local enable_stderr="/dev/null"
  [[ "${VERBOSE}" == "true" ]] && enable_stderr="/dev/stderr"

  if ! "${UIPATHCTL_BIN}" cluster maintenance enable \
       --namespace "${UIPATH_NS}" \
       --timeout "${MAINTENANCE_TIMEOUT}" \
       --force 2>"${enable_stderr}"; then
    fail "Phase A: uipathctl cluster maintenance enable failed or timed out"
  fi

  # Verify maintenance mode took effect
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled \
    --namespace "${UIPATH_NS}" 2>/dev/null || true)

  if ! maintenance_is_enabled "${mm_raw}"; then
    fail "Phase A: Maintenance mode not confirmed enabled after enable command (is-enabled returned: '${mm_raw}')"
  fi

  pass "Phase A: Maintenance mode enabled"
  state_log "MAINTENANCE_ENABLED  $(hostname)"

  # Show product pod state
  echo ""
  info "Product deployment state in namespace ${UIPATH_NS} (expect replicas→0):"
  if [[ "${VERBOSE}" == "true" ]]; then
    kubectl get deploy -n "${UIPATH_NS}" \
      -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
      2>/dev/null | sed 's/^/  /' || true
  fi

  echo ""
  info "Non-zero replica deployments remaining (expect none for product services):"
  if [[ "${VERBOSE}" == "true" ]]; then
    kubectl get deploy -n "${UIPATH_NS}" --no-headers 2>/dev/null \
      | awk '$2 != "0" && $2 != "<none>" {print}' \
      | sed 's/^/  /' || true
  fi

  # ---- Phase C: Cordon All Nodes ----
  echo ""
  echo -e "${BOLD}--- Phase C: Cordon All Nodes ---${RESET}"
  info "Cordoning all nodes upfront — scheduler will have no targets during per-node stops"
  info "Also labelling nodejanitor/skip=true so nodejanitor does not auto-uncordon during patch window"
  info "Ref: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/"
  echo ""

  local all_nodes
  all_nodes=$(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null)

  if [[ -z "${all_nodes}" ]]; then
    fail "Phase C: Could not retrieve node list from kubectl"
  fi

  local node_count
  node_count=$(echo "${all_nodes}" | wc -l | tr -d ' ')
  info "Processing ${node_count} node(s): label nodejanitor/skip=true, then cordon..."

  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue

    # Label FIRST — prevents nodejanitor from uncordoning a node that is
    # cordoned but not yet labelled if the script is interrupted mid-loop.
    if kubectl label --overwrite node "${node}" nodejanitor/skip=true 2>/dev/null; then
      info "  Labelled:  ${node}  (nodejanitor/skip=true)"
    else
      fail "Phase C: kubectl label nodejanitor/skip=true failed for node ${node}"
    fi

    if kubectl cordon "${node}" 2>/dev/null; then
      info "  Cordoned:  ${node}"
    else
      fail "Phase C: kubectl cordon failed for node ${node}"
    fi
  done <<< "${all_nodes}"

  echo ""
  info "Verifying all nodes show SchedulingDisabled and carry nodejanitor/skip=true..."
  if [[ "${VERBOSE}" == "true" ]]; then
    kubectl get nodes --show-labels 2>/dev/null | sed 's/^/  /'
  fi

  # Verify: no node missing SchedulingDisabled
  local not_cordoned
  not_cordoned=$(kubectl get nodes -o json 2>/dev/null \
    | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
print('\n'.join(
  n['metadata']['name']
  for n in items
  if not n.get('spec', {}).get('unschedulable')
))" 2>/dev/null || true)

  if [[ -n "${not_cordoned}" ]]; then
    echo "  Not cordoned:"
    echo "${not_cordoned}" | sed 's/^/    /'
    fail "Phase C: Not all nodes are SchedulingDisabled after cordon"
  fi

  # Verify: no node missing nodejanitor/skip=true label
  local not_labelled
  not_labelled=$(kubectl get nodes -o json 2>/dev/null \
    | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
print('\n'.join(
  n['metadata']['name']
  for n in items
  if n.get('metadata', {}).get('labels', {}).get('nodejanitor/skip') != 'true'
))" 2>/dev/null || true)

  if [[ -n "${not_labelled}" ]]; then
    echo "  Missing nodejanitor/skip=true:"
    echo "${not_labelled}" | sed 's/^/    /'
    fail "Phase C: Not all nodes carry nodejanitor/skip=true label after labelling"
  fi

  pass "Phase C: All ${node_count} nodes cordoned and labelled nodejanitor/skip=true"
  state_log "ALL_NODES_CORDONED  $(hostname)  count=${node_count}  nodejanitor_skip=true"

  # ---- Identify etcd leader for operator reference ----
  echo ""
  echo -e "${BOLD}--- etcd Leader Identification (for Phase D sequencing) ---${RESET}"
  mode_identify_leader

  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${GREEN}${BOLD}  PHASES A + C COMPLETE${RESET}"
  echo -e "${BOLD}  Next steps:${RESET}"
  echo -e "${BOLD}    1. Run 02-backup.sh on each server node${RESET}"
  echo -e "${BOLD}    2. Run ./03-prepatch.sh --stop-agent on each agent (agents first)${RESET}"
  echo -e "${BOLD}    3. Run ./03-prepatch.sh --stop-server on each server${RESET}"
  echo -e "${BOLD}       (non-leader first, leader = node marked above — LAST)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"
}

# =============================================================================
# SHARED: drain this node via node-drain.service
# Per UiPath 2024.10 docs:
# https://docs.uipath.com/automation-suite/automation-suite/2024.10/
#   installation-guide/starting-and-shutting-down-a-node
# =============================================================================
drain_this_node() {
  info "Draining node $(hostname) via node-drain.service (timeout: ${DRAIN_TIMEOUT_SECS}s)..."
  info "Ref: https://docs.uipath.com/automation-suite/automation-suite/2024.10/installation-guide/starting-and-shutting-down-a-node"

  if ! systemctl is-active --quiet node-drain.service 2>/dev/null; then
    warn "node-drain.service is not currently active — may already be stopped or not present"
    warn "If this is unexpected, investigate before continuing"
    # Don't abort — service may legitimately be inactive if already drained
    return 0
  fi

  if ! timeout "${DRAIN_TIMEOUT_SECS}" systemctl stop node-drain.service 2>&1; then
    fail "DRAIN_TIMEOUT: node-drain.service did not stop within ${DRAIN_TIMEOUT_SECS}s on $(hostname). DO NOT run rke2-killall.sh. Investigate stuck pods."
  fi

  # Brief wait for pod eviction to propagate
  sleep 5

  log "${CYAN}[INFO]${RESET}  Drain step complete on $(hostname)"
  log "${CYAN}[INFO]${RESET}    --> OPERATOR ACTION: Verify from primary server node that no non-DaemonSet pods remain:"
  log "${CYAN}[INFO]${RESET}        kubectl get pods -A --field-selector spec.nodeName=$(hostname) | grep -v -E 'Completed|DaemonSet'"
}

# =============================================================================
# SHARED: verify no residual rke2/containerd/kubelet processes
# =============================================================================
verify_clean_stop() {
  info "Verifying no residual rke2 / containerd / kubelet processes on $(hostname)..."
  sleep 3

  local residual
  residual=$(ps aux 2>/dev/null \
    | grep -E 'containerd|kubelet|rke2' \
    | grep -v grep \
    | grep -v "03-prepatch" || true)

  if [[ -n "${residual}" ]]; then
    echo "  Residual processes:"
    echo "${residual}" | sed 's/^/    /'
    fail "KILLALL_FAIL: Residual processes remain on $(hostname). DO NOT start OS patch. Clear manually then verify."
  fi

  pass "No residual rke2/containerd/kubelet processes on $(hostname)  ✓"
}

# =============================================================================
# MODE: --stop-agent  (Phase D — agent node stop)
# Run LOCALLY on each agent node. Repeat for all 3 agents in sequence.
# =============================================================================
mode_stop_agent() {
  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  Phase D — Agent Node Stop${RESET}"
  echo -e "${BOLD}  Node: $(hostname)   |   $(ts)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  # Guard: must be an agent node
  if systemctl is-active --quiet rke2-server 2>/dev/null; then
    fail "--stop-agent: rke2-server is active on $(hostname). This is a SERVER node. Use --stop-server instead."
  fi

  if ! systemctl is-active --quiet rke2-agent 2>/dev/null; then
    warn "rke2-agent is not currently active on $(hostname) — may already be stopped"
    info "Checking for residual processes anyway..."
    verify_clean_stop
    state_log "AGENT_STOPPED  $(hostname)  (was already stopped)"
    pass "Agent node $(hostname) already stopped — no action needed"
    return 0
  fi

  # Step 1: Drain
  drain_this_node
  echo ""

  # Step 2: Stop rke2-agent
  info "Stopping rke2-agent (timeout: ${STOP_TIMEOUT_SECS}s)..."
  if ! timeout "${STOP_TIMEOUT_SECS}" systemctl stop rke2-agent 2>&1; then
    fail "STOP_HANG: rke2-agent did not stop within ${STOP_TIMEOUT_SECS}s on $(hostname). DO NOT run rke2-killall.sh. Investigate."
  fi

  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    fail "STOP_HANG: systemctl stop rke2-agent exited ${rc} on $(hostname)"
  fi
  info "rke2-agent stopped  ✓"
  echo ""

  # Step 3: rke2-killall.sh — clear residual containerd/kubelet and unmount pod mounts
  # Safe to run ONLY after drain + systemctl stop. Never before.
  info "Running rke2-killall.sh to clear residual containerd/kubelet processes and unmount pod mounts..."
  if ! timeout "${KILLALL_TIMEOUT_SECS}" /var/lib/rancher/rke2/bin/rke2-killall.sh 2>&1; then
    fail "KILLALL_FAIL: rke2-killall.sh did not complete within ${KILLALL_TIMEOUT_SECS}s on $(hostname)"
  fi
  info "rke2-killall.sh complete  ✓"
  echo ""

  # Step 4: Verify clean
  verify_clean_stop

  # Step 5: State log
  state_log "AGENT_STOPPED  $(hostname)"

  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${GREEN}${BOLD}  AGENT NODE STOPPED CLEANLY: $(hostname)${RESET}"
  echo -e "${BOLD}  The calling orchestrator should verify from primary server:${RESET}"
  echo -e "${BOLD}    kubectl get node $(hostname)${RESET}"
  echo -e "${BOLD}  Expected: NotReady,SchedulingDisabled${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"
}

# =============================================================================
# MODE: --stop-server  (Phase D — server node stop)
# Run LOCALLY on each server node. Non-leader first. Leader last.
# The script auto-detects whether this is the final server by counting
# healthy etcd members before stopping.
# =============================================================================
mode_stop_server() {
  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  Phase D — Server Node Stop${RESET}"
  echo -e "${BOLD}  Node: $(hostname)   |   $(ts)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  # Guard: must be a server node
  if ! systemctl is-active --quiet rke2-server 2>/dev/null; then
    # Check if already stopped
    warn "rke2-server is not active on $(hostname)"
    info "Checking for residual processes..."
    verify_clean_stop
    state_log "SERVER_STOPPED  $(hostname)  (was already stopped)"
    pass "Server node $(hostname) already stopped — no action needed"
    return 0
  fi

  if ! init_etcd_access; then
    fail "--stop-server: etcdctl not available (no host binary and no etcd container via crictl)"
  fi

  # Step 1: Determine if this is the final server node
  # Count how many etcd members respond as healthy BEFORE we stop this one
  info "Checking etcd member health before stopping this server..."
  local health_output healthy_count
  health_output=$(etcdctl_cmd endpoint health --cluster 2>&1 || true)
  healthy_count=$(echo "${health_output}" | grep -c "is healthy" || echo "0")

  info "Healthy etcd endpoints visible from $(hostname): ${healthy_count}"
  if [[ "${VERBOSE}" == "true" ]]; then
    echo "${health_output}" | sed 's/^/  /'
  fi
  echo ""

  local is_last_server=false
  if [[ "${healthy_count}" -le 1 ]]; then
    is_last_server=true
    warn "Only ${healthy_count} healthy etcd endpoint(s) — this appears to be the LAST server node"
    warn "Quorum will be lost when this server stops — this is expected and marks end of pre-patch phase"
  else
    # Quorum check: ensure remaining servers (after this one stops) are healthy
    info "etcd quorum check: ${healthy_count} healthy members currently, will be $((healthy_count - 1)) after this stop  ✓"
  fi

  echo ""

  # Step 2: Drain
  drain_this_node
  echo ""

  # Step 3: Stop rke2-server
  info "Stopping rke2-server (timeout: ${STOP_TIMEOUT_SECS}s)..."
  if ! timeout "${STOP_TIMEOUT_SECS}" systemctl stop rke2-server 2>&1; then
    fail "STOP_HANG: rke2-server did not stop within ${STOP_TIMEOUT_SECS}s on $(hostname). DO NOT run rke2-killall.sh. Investigate."
  fi
  info "rke2-server stopped  ✓"
  echo ""

  # Step 4: rke2-killall.sh
  info "Running rke2-killall.sh to clear residual containerd/kubelet processes and unmount pod mounts..."
  if ! timeout "${KILLALL_TIMEOUT_SECS}" /var/lib/rancher/rke2/bin/rke2-killall.sh 2>&1; then
    fail "KILLALL_FAIL: rke2-killall.sh did not complete within ${KILLALL_TIMEOUT_SECS}s on $(hostname)"
  fi
  info "rke2-killall.sh complete  ✓"
  echo ""

  # Step 5: Verify clean
  verify_clean_stop

  # Step 6: State log + completion marker
  state_log "SERVER_STOPPED  $(hostname)"

  if [[ "${is_last_server}" == "true" ]]; then
    # Write PREPATCH_COMPLETE marker — consumed by OS patch orchestrator
    local marker="${MARKER_DIR}/PREPATCH_COMPLETE_$(date -u +%Y%m%d-%H%M%S)"
    mkdir -p "${MARKER_DIR}" 2>/dev/null || true
    cat > "${marker}" <<MARKEREOF
PREPATCH_COMPLETE
timestamp_utc: $(ts)
last_server: $(hostname)
state_log: ${STATE_LOG}

Cluster is fully stopped and ready for OS patch + reboot.
All cluster nodes should now have rke2-server/rke2-agent stopped and no residual processes.

POST-PATCH CHECKLIST (after cluster restart):
  1. Verify all nodes Ready:       kubectl get nodes
  2. Verify etcd health:           /var/lib/rancher/rke2/bin/etcdctl endpoint health --cluster
  3. Disable maintenance mode:     uipathctl cluster maintenance disable --namespace uipath
  4. Remove nodejanitor label:     kubectl label node <each-node> nodejanitor/skip-
     (removes the label so nodejanitor resumes normal management)
  5. Uncordon all nodes:           kubectl uncordon <each-node>
     NOTE: remove nodejanitor/skip label BEFORE uncordoning, otherwise
     nodejanitor may re-cordon the node before you finish the checklist.
  6. Run health check:             uipathctl health check --namespace uipath
MARKEREOF
    state_log "PREPATCH_COMPLETE  $(hostname)  marker=${marker}"

    echo ""
    echo -e "${BOLD}================================================================${RESET}"
    echo -e "${GREEN}${BOLD}  PRE-PATCH PHASE COMPLETE${RESET}"
    echo -e "${GREEN}${BOLD}  Last server stopped: $(hostname)${RESET}"
    echo -e "${GREEN}${BOLD}  Marker written: ${marker}${RESET}"
    echo -e "${BOLD}================================================================${RESET}"
    echo -e "${BOLD}  Cluster is FULLY STOPPED — safe to proceed with OS patch + reboot${RESET}"
    echo -e "${BOLD}  State log: ${STATE_LOG}${RESET}"
    echo -e "${BOLD}================================================================${RESET}\n"
  else
    echo ""
    echo -e "${BOLD}================================================================${RESET}"
    echo -e "${GREEN}${BOLD}  SERVER NODE STOPPED CLEANLY: $(hostname)${RESET}"
    echo -e "${BOLD}  Verify from remaining server (while API still up):${RESET}"
    echo -e "${BOLD}    kubectl get node $(hostname)${RESET}"
    echo -e "${BOLD}  Expected: NotReady,SchedulingDisabled${RESET}"
    echo -e "${BOLD}  NEXT: run --stop-server on the next server (leader last)${RESET}"
    echo -e "${BOLD}================================================================${RESET}\n"
  fi
}

# =============================================================================
# MAIN — argument dispatch
# =============================================================================
main() {
  local mode=""

  for arg in "$@"; do
    case "${arg}" in
      --verbose|--debug|-v) VERBOSE=true ;;
      --global|--stop-agent|--stop-server|--identify-leader) mode="${arg}" ;;
      --help|-h) usage; exit 0 ;;
      *) echo -e "${RED}Unknown argument: ${arg}${RESET}"; usage; exit 1 ;;
    esac
  done

  [[ -z "${mode}" ]] && mode="--global"

  [[ "${VERBOSE}" == "true" ]] && echo -e "${CYAN}  Mode: verbose${RESET}"

  case "${mode}" in
    --global)
      mode_global
      ;;
    --stop-agent)
      mode_stop_agent
      ;;
    --stop-server)
      mode_stop_server
      ;;
    --identify-leader)
      mode_identify_leader
      ;;
  esac
}

main "$@"
