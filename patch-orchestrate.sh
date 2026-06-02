#!/usr/bin/env bash
# =============================================================================
# patch-orchestrate.sh — UiPath AS 24.10.4 / RKE2 SSH Orchestrator
#
# Runs from the primary server node (or a jump host with kubectl access).
# Auto-discovers nodes from kubectl, controls the full shutdown sequence with
# explicit ordering. No coordination annotations needed — the orchestrator
# controls order directly.
#
# chmod +x patch-orchestrate.sh
#
# Usage:
#   patch-orchestrate.sh [OPTIONS]
#
# Required:
#   --ssh-password=<pw>      SSH password for all nodes
#
# Options:
#   --installer-dir=<path>   UiPath version folder; required unless uipathctl is in PATH
#   --ssh-user=<user>        SSH user (default: root)
#   --ssh-port=<port>        SSH port (default: 22)
#   --skip-hc=comp1,comp2   Health check component names to skip on failure
#   --servers=a,b,c          Server node hostnames (auto-discovered if omitted)
#   --agents=a,b             Agent node hostnames (auto-discovered if omitted)
#   --help                   Show this help
#
# Exit codes:
#   0  — all nodes stopped cleanly
#   1  — failure; investigate cluster state before continuing or re-running
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

readonly ETCDCTL="/var/lib/rancher/rke2/bin/etcdctl"
readonly ETCD_CACERT="/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt"
readonly ETCD_CERT="/var/lib/rancher/rke2/server/tls/etcd/server-client.crt"
readonly ETCD_KEY="/var/lib/rancher/rke2/server/tls/etcd/server-client.key"
readonly ETCD_ENDPOINT="https://127.0.0.1:2379"

readonly STATE_LOG="/opt/UiPathAutomationSuite/prepatch-state.log"
readonly BACKUP_BASE="/opt/UiPathAutomationSuite/backup_patch"

readonly DRAIN_TIMEOUT_SECS=600
readonly STOP_TIMEOUT_SECS=300
readonly KILLALL_TIMEOUT_SECS=120

SSH_USER="root"
SSH_PASSWORD=""
SSH_PORT=22
INSTALLER_DIR=""
SKIP_HC_COMPONENTS=()
SERVER_NODES_ARG=""
AGENT_NODES_ARG=""
VERBOSE=false

UIPATHCTL_BIN=""
LEADER_NODE=""

# =============================================================================
# HELPERS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo -e "$(ts)  $*"; }
info() { [[ "${VERBOSE}" == "true" ]] && log "${CYAN}[INFO]${RESET}  $*" || true; }
pass() { log "${GREEN}[PASS]${RESET}  $*"; }
warn() { log "${YELLOW}[WARN]${RESET}  $*"; }

abort() {
  local msg="$*"
  log "${RED}[FAIL]${RESET}  ${msg}"
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  FAIL  orchestrator  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
  echo ""
  echo -e "${RED}${BOLD}ABORT: ${msg}${RESET}"
  echo -e "${RED}${BOLD}NO automatic rollback. Investigate cluster state before retrying.${RESET}\n"
  exit 1
}

state_log() {
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  $*" >> "${STATE_LOG}" 2>/dev/null || true
}

usage() {
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Required:"
  echo "  --ssh-password=<pw>      SSH password for all nodes"
  echo ""
  echo "Options:"
  echo "  --installer-dir=<path>   UiPath version folder; required unless uipathctl is in PATH"
  echo "  --ssh-user=<user>        SSH user (default: root)"
  echo "  --ssh-port=<port>        SSH port (default: 22)"
  echo "  --skip-hc=all           Skip health check failures entirely"
  echo "  --skip-hc=comp1,comp2   Skip specific failing components by name"
  echo "  --servers=a,b,c          Server node hostnames (auto-discovered if omitted)"
  echo "  --agents=a,b             Agent node hostnames (auto-discovered if omitted)"
  echo "  --help                   Show this help"
  echo ""
}

# =============================================================================
# SSH WRAPPER
# Requires sshpass installed. Uses SSHPASS env var for password.
# =============================================================================
check_sshpass() {
  if ! command -v sshpass &>/dev/null; then
    abort "sshpass not installed. Install with: yum install sshpass  OR  apt-get install sshpass"
  fi
}

# remote <node> <cmd> — blocking SSH, output tee'd to STATE_LOG
remote() {
  local node="$1"
  local cmd="$2"
  SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -p "${SSH_PORT}" \
    "${SSH_USER}@${node}" \
    "${cmd}" 2>&1 | tee -a "${STATE_LOG}"
  return "${PIPESTATUS[0]}"
}

# remote_bg <node> <cmd> — non-blocking SSH (for parallel jobs)
remote_bg() {
  local node="$1"
  local cmd="$2"
  SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -p "${SSH_PORT}" \
    "${SSH_USER}@${node}" \
    "${cmd}" 2>&1 | tee -a "${STATE_LOG}"
}

# =============================================================================
# SSH CONNECTIVITY TEST
# =============================================================================
test_ssh_connectivity() {
  local nodes=("$@")
  local failed=()

  log "Testing SSH connectivity to ${#nodes[@]} node(s)..."
  for node in "${nodes[@]}"; do
    if SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=15 \
       -p "${SSH_PORT}" \
       "${SSH_USER}@${node}" \
       "echo ssh-ok" &>/dev/null; then
      pass "  SSH OK: ${node}"
    else
      warn "  SSH FAIL: ${node}"
      failed+=("${node}")
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    abort "SSH connectivity test failed for: ${failed[*]}"
  fi
}

# =============================================================================
# uipathctl resolution (local)
# Priority: PATH → --installer-dir flag → /opt/UiPathAutomationSuite/latest/...
# =============================================================================
resolve_uipathctl() {
  if command -v uipathctl &>/dev/null; then
    UIPATHCTL_BIN="$(command -v uipathctl)"
    info "uipathctl (PATH): ${UIPATHCTL_BIN}"
    return 0
  fi

  if [[ -n "${INSTALLER_DIR}" ]]; then
    local candidate="${INSTALLER_DIR%/}/installer/bin/uipathctl"
    if [[ -x "${candidate}" ]]; then
      UIPATHCTL_BIN="${candidate}"
      export PATH="$(dirname "${UIPATHCTL_BIN}"):${PATH}"
      info "uipathctl (--installer-dir): ${UIPATHCTL_BIN}"
      return 0
    else
      warn "--installer-dir set but ${candidate} not found/executable"
    fi
  fi

  local fallback="/opt/UiPathAutomationSuite/latest/installer/bin/uipathctl"
  if [[ -x "${fallback}" ]]; then
    UIPATHCTL_BIN="${fallback}"
    export PATH="$(dirname "${UIPATHCTL_BIN}"):${PATH}"
    info "uipathctl (fallback): ${UIPATHCTL_BIN}"
    return 0
  fi

  return 1
}

# =============================================================================
# MAINTENANCE MODE HELPER
# =============================================================================
maintenance_is_enabled() {
  local raw="$1"
  echo "${raw}" | grep -qi "not\|false\|disabled" && return 1
  echo "${raw}" | grep -qi "true\|enabled" && return 0
  return 1
}

# =============================================================================
# NODE DISCOVERY
# =============================================================================
discover_nodes() {
  local server_nodes=()
  local agent_nodes=()

  if [[ -n "${SERVER_NODES_ARG}" ]]; then
    IFS=',' read -ra server_nodes <<< "${SERVER_NODES_ARG}"
  else
    info "Auto-discovering server nodes from kubectl (label: node-role.kubernetes.io/control-plane=true)..."
    while IFS= read -r n; do
      [[ -n "${n}" ]] && server_nodes+=("${n}")
    done < <(kubectl get nodes -l 'node-role.kubernetes.io/control-plane=true' \
      --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null || true)
  fi

  if [[ -n "${AGENT_NODES_ARG}" ]]; then
    IFS=',' read -ra agent_nodes <<< "${AGENT_NODES_ARG}"
  else
    info "Auto-discovering agent nodes from kubectl (no control-plane label)..."
    while IFS= read -r n; do
      [[ -n "${n}" ]] && agent_nodes+=("${n}")
    done < <(kubectl get nodes \
      --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
      | while IFS= read -r node; do
          label=$(kubectl get node "${node}" \
            -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' \
            2>/dev/null || true)
          [[ -z "${label}" ]] && echo "${node}"
        done || true)
  fi

  if [[ ${#server_nodes[@]} -eq 0 ]]; then
    abort "No server nodes found — check kubectl access or provide --servers="
  fi

  # Export as global arrays via temp file to avoid subshell scoping
  printf '%s\n' "${server_nodes[@]}" > /tmp/patch-orchestrate-servers.$$
  printf '%s\n' "${agent_nodes[@]}"  > /tmp/patch-orchestrate-agents.$$
}

# =============================================================================
# ETCD LEADER DETECTION (local etcdctl)
# =============================================================================
detect_leader() {
  if [[ ! -x "${ETCDCTL}" ]]; then
    warn "etcdctl not found at ${ETCDCTL} — leader detection skipped"
    LEADER_NODE=""
    return 0
  fi

  local cluster_status
  cluster_status=$("${ETCDCTL}" \
    --endpoints="${ETCD_ENDPOINT}" \
    --cacert="${ETCD_CACERT}" \
    --cert="${ETCD_CERT}" \
    --key="${ETCD_KEY}" \
    endpoint status --cluster -w json 2>/dev/null || true)

  if [[ -z "${cluster_status}" ]]; then
    warn "etcdctl cluster endpoint status returned empty — leader unknown"
    LEADER_NODE=""
    return 0
  fi

  local node_ip_map
  node_ip_map=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
for n in items:
    name = n['metadata']['name']
    for addr in n.get('status', {}).get('addresses', []):
        if addr.get('type') == 'InternalIP':
            print(addr['address'], name)
            break
" 2>/dev/null || true)

  LEADER_NODE=$(echo "${cluster_status}" | python3 -c "
import json, sys, os
node_map = {}
for line in os.environ.get('NODE_IP_MAP','').splitlines():
    parts = line.split(None, 1)
    if len(parts) == 2:
        node_map[parts[0]] = parts[1]
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list):
        data = [data]
    for e in data:
        st = e.get('Status', {})
        member_id = st.get('header', {}).get('member_id', -1)
        leader_id = st.get('leader', -2)
        if member_id == leader_id:
            ep = e.get('Endpoint', '')
            try:
                ip = ep.split('//')[1].split(':')[0]
            except Exception:
                ip = ep
            print(node_map.get(ip, ip))
            break
except Exception:
    pass
" NODE_IP_MAP="${node_ip_map}" 2>/dev/null || true)

  info "etcd leader: ${LEADER_NODE:-unknown}"
}

# =============================================================================
# HEALTH CHECK (local uipathctl)
# =============================================================================
run_health_check() {
  echo -e "\n${BOLD}--- Health Check ---${RESET}"

  local mm_raw
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled \
    --namespace "${UIPATH_NS}" 2>/dev/null || true)

  if maintenance_is_enabled "${mm_raw}"; then
    pass "Health check: maintenance mode already enabled — skipping"
    return 0
  fi

  info "Running: ${UIPATHCTL_BIN} health check --timeout 10m"
  local hc_output hc_exit=0
  hc_output=$("${UIPATHCTL_BIN}" health check --timeout 10m 2>&1) || hc_exit=$?

  local cleaned
  cleaned=$(echo "${hc_output}" | grep -vE '^(INFO|WARN|ERRO|DEBU)\[[0-9]' || true)

  echo ""
  echo "${cleaned}" | sed 's/^/  /'
  echo ""

  if [[ ${hc_exit} -eq 0 ]]; then
    pass "Health check passed"
    return 0
  fi

  local failed_components=()
  while IFS= read -r line; do
    if echo "${line}" | grep -qE '❌| failed '; then
      local comp
      comp=$(echo "${line}" | awk '{print $2}')
      [[ -n "${comp}" ]] && failed_components+=("${comp}")
    fi
  done <<< "${cleaned}"

  if [[ ${#failed_components[@]} -eq 0 ]]; then
    abort "Health check command failed — check binary version/path (use --installer-dir)"
  fi

  # --skip-hc=all  →  ignore every failure
  for skip_comp in "${SKIP_HC_COMPONENTS[@]:-}"; do
    if [[ "${skip_comp,,}" == "all" ]]; then
      warn "Health check had failures — skipped (--skip-hc=all): ${failed_components[*]}"
      return 0
    fi
  done

  # Check each failed component against the explicit skip list
  local unresolved=()
  for comp in "${failed_components[@]}"; do
    local skip=false
    for skip_comp in "${SKIP_HC_COMPONENTS[@]:-}"; do
      if [[ "${comp,,}" == "${skip_comp,,}" ]]; then
        skip=true
        break
      fi
    done
    [[ "${skip}" == "false" ]] && unresolved+=("${comp}")
  done

  if [[ ${#unresolved[@]} -gt 0 ]]; then
    local unresolved_str
    unresolved_str=$(IFS=','; echo "${unresolved[*]}")
    abort "Health check failed — unresolved: ${unresolved_str}. Use --skip-hc=all to bypass or --skip-hc=comp1,comp2 for specific ones."
  fi

  warn "Health check had failures but all in --skip-hc list: ${failed_components[*]} — continuing"
}

# =============================================================================
# MAINTENANCE MODE (local uipathctl)
# =============================================================================
enable_maintenance_mode() {
  echo -e "\n${BOLD}--- Enable Maintenance Mode ---${RESET}"

  local mm_raw
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled \
    --namespace "${UIPATH_NS}" 2>/dev/null || true)

  if maintenance_is_enabled "${mm_raw}"; then
    pass "Maintenance mode already enabled — skipping"
    return 0
  fi

  info "Enabling maintenance mode..."
  if ! "${UIPATHCTL_BIN}" cluster maintenance enable \
       --namespace "${UIPATH_NS}" 2>/dev/null; then
    abort "uipathctl cluster maintenance enable failed"
  fi

  # Wait up to 3 min for UiPath pods to scale to 0
  local deadline=$(( $(date +%s) + 180 ))
  local running_count
  while [[ $(date +%s) -lt ${deadline} ]]; do
    running_count=$(kubectl get pods -n "${UIPATH_NS}" \
      --no-headers 2>/dev/null \
      | grep -v -E 'Completed|Terminating' \
      | grep -c 'Running' || echo "0")
    if [[ "${running_count}" -eq 0 ]]; then
      break
    fi
    info "  Waiting for UiPath pods to scale down... (${running_count} Running)"
    sleep 15
  done

  running_count=$(kubectl get pods -n "${UIPATH_NS}" \
    --no-headers 2>/dev/null \
    | grep -v -E 'Completed|Terminating' \
    | grep -c 'Running' || echo "0")

  if [[ "${running_count}" -gt 0 ]]; then
    warn "  ${running_count} Running UiPath pod(s) still present after 3m — continuing"
  fi

  pass "Maintenance mode enabled"
  state_log "MAINTENANCE_ENABLED  orchestrator"
}

# =============================================================================
# CORDON ALL NODES (local kubectl)
# =============================================================================
cordon_all_nodes() {
  local all_nodes=("$@")
  echo -e "\n${BOLD}--- Cordon All Nodes ---${RESET}"

  for node in "${all_nodes[@]}"; do
    kubectl label node "${node}" nodejanitor/skip=true --overwrite 2>/dev/null \
      || warn "  label nodejanitor/skip=true failed for ${node}"
    kubectl cordon "${node}" 2>/dev/null \
      || warn "  cordon failed for ${node}"
    pass "  Cordoned: ${node}"
  done
}

# =============================================================================
# BACKUP — SSH to each server node in parallel
# =============================================================================
backup_server_nodes() {
  local servers=("$@")
  echo -e "\n${BOLD}--- Backup All Server Nodes (parallel) ---${RESET}"

  local pids=()
  local server_list=()

  for node in "${servers[@]}"; do
    log "  Starting backup on ${node} (background)..."
    (
      remote "${node}" "
set -uo pipefail
BACKUP_DIR='${BACKUP_BASE}/${node}-\$(date +%Y%m%d-%H%M%S)'
ETCD_DIR=\"\${BACKUP_DIR}/etcd\"
CFG_DIR=\"\${BACKUP_DIR}/rke2-config\"
SNAP_SRC='/var/lib/rancher/rke2/server/db/snapshots'
mkdir -p \"\${ETCD_DIR}\" \"\${CFG_DIR}\"
snapshots=()
while IFS= read -r snap; do
  snapshots+=(\"\${snap}\")
done < <(find \"\${SNAP_SRC}\" -maxdepth 1 -type f ! -name '*.meta.json' \\
  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -2 | awk '{print \$2}')
if [[ \${#snapshots[@]} -eq 0 ]]; then
  echo 'ERROR: No etcd snapshots found in '\"\${SNAP_SRC}\"
  exit 1
fi
for snap in \"\${snapshots[@]}\"; do
  dest=\"\${ETCD_DIR}/\$(basename \"\${snap}\")\"
  cp \"\${snap}\" \"\${dest}\"
  sha256sum \"\${dest}\" | tee -a \"\${BACKUP_DIR}/sha256sums.txt\"
  meta=\"\${snap}.meta.json\"
  if [[ -f \"\${meta}\" ]]; then
    cp \"\${meta}\" \"\${ETCD_DIR}/\$(basename \"\${meta}\")\"
    echo \"meta: \$(basename \"\${meta}\") copied\"
  fi
done
if [[ -f /etc/rancher/rke2/config.yaml ]]; then
  cp /etc/rancher/rke2/config.yaml \"\${CFG_DIR}/config.yaml\"
  echo 'config.yaml copied'
fi
echo \"BACKUP_COMPLETE dir=\${BACKUP_DIR}\"
"
    ) &
    pids+=($!)
    server_list+=("${node}")
  done

  # Wait for all background jobs and collect exit codes
  local all_ok=true
  for i in "${!pids[@]}"; do
    local pid="${pids[$i]}"
    local node="${server_list[$i]}"
    if wait "${pid}"; then
      pass "  Backup OK: ${node}"
    else
      warn "  Backup FAILED: ${node}"
      all_ok=false
    fi
  done

  if [[ "${all_ok}" == "false" ]]; then
    abort "One or more server node backups failed — check STATE_LOG for details"
  fi

  pass "All server node backups complete"
}

# =============================================================================
# STOP NODE — drain (local kubectl) + SSH stop
# =============================================================================
stop_agent_node() {
  local node="$1"
  echo -e "\n${BOLD}--- Stop Agent Node: ${node} ---${RESET}"

  # Drain via local kubectl
  log "  Draining ${node}..."
  if ! kubectl drain "${node}" \
       --ignore-daemonsets \
       --delete-emptydir-data \
       --timeout="${DRAIN_TIMEOUT_SECS}s" \
       --force 2>&1; then
    warn "  kubectl drain returned non-zero for ${node} — continuing"
  fi
  pass "  Drain complete: ${node}"

  # SSH: stop rke2-agent + killall
  log "  Stopping rke2-agent on ${node} via SSH..."
  remote "${node}" "
set -uo pipefail
echo 'Stopping rke2-agent...'
timeout ${STOP_TIMEOUT_SECS} systemctl stop rke2-agent 2>&1 || echo 'WARN: rke2-agent stop returned non-zero'
echo 'Running rke2-killall.sh...'
timeout ${KILLALL_TIMEOUT_SECS} rke2-killall.sh 2>&1 || echo 'WARN: rke2-killall.sh returned non-zero'
residual=\$(ps aux 2>/dev/null | grep -E 'containerd|kubelet|rke2' | grep -v grep | grep -v patch-orchestrate || true)
if [[ -n \"\${residual}\" ]]; then
  echo 'WARN: residual processes remain:'
  echo \"\${residual}\"
else
  echo 'No residual processes.'
fi
echo 'AGENT_STOPPED'
" || warn "  SSH stop command returned non-zero for ${node}"

  state_log "AGENT_STOPPED  ${node}  (orchestrated)"
  pass "  Agent node stopped: ${node}"
}

stop_server_node() {
  local node="$1"
  echo -e "\n${BOLD}--- Stop Server Node: ${node} ---${RESET}"

  # Drain via local kubectl
  log "  Draining ${node}..."
  if ! kubectl drain "${node}" \
       --ignore-daemonsets \
       --delete-emptydir-data \
       --timeout="${DRAIN_TIMEOUT_SECS}s" \
       --force 2>&1; then
    warn "  kubectl drain returned non-zero for ${node} — continuing"
  fi
  pass "  Drain complete: ${node}"

  # SSH: stop rke2-server + killall
  log "  Stopping rke2-server on ${node} via SSH..."
  remote "${node}" "
set -uo pipefail
echo 'Stopping rke2-server...'
timeout ${STOP_TIMEOUT_SECS} systemctl stop rke2-server 2>&1 || echo 'WARN: rke2-server stop returned non-zero'
echo 'Running rke2-killall.sh...'
timeout ${KILLALL_TIMEOUT_SECS} rke2-killall.sh 2>&1 || echo 'WARN: rke2-killall.sh returned non-zero'
residual=\$(ps aux 2>/dev/null | grep -E 'containerd|kubelet|rke2' | grep -v grep | grep -v patch-orchestrate || true)
if [[ -n \"\${residual}\" ]]; then
  echo 'WARN: residual processes remain:'
  echo \"\${residual}\"
else
  echo 'No residual processes.'
fi
echo 'SERVER_STOPPED'
" || warn "  SSH stop command returned non-zero for ${node}"

  state_log "SERVER_STOPPED  ${node}  (orchestrated)"
  pass "  Server node stopped: ${node}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  # Parse arguments
  for arg in "$@"; do
    case "${arg}" in
      --installer-dir=*) INSTALLER_DIR="${arg#*=}" ;;
      --ssh-user=*)      SSH_USER="${arg#*=}" ;;
      --ssh-password=*)  SSH_PASSWORD="${arg#*=}" ;;
      --ssh-port=*)      SSH_PORT="${arg#*=}" ;;
      --skip-hc=*)
        IFS=',' read -ra SKIP_HC_COMPONENTS <<< "${arg#*=}"
        ;;
      --servers=*)       SERVER_NODES_ARG="${arg#*=}" ;;
      --agents=*)        AGENT_NODES_ARG="${arg#*=}" ;;
      --verbose|-v)      VERBOSE=true ;;
      --help|-h)         usage; exit 0 ;;
      *) echo -e "${RED}Unknown argument: ${arg}${RESET}"; usage; exit 1 ;;
    esac
  done

  if [[ -z "${SSH_PASSWORD}" ]]; then
    abort "--ssh-password is required"
  fi

  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  patch-orchestrate.sh — UiPath AS 24.10.4 / RKE2 SSH Orchestrator${RESET}"
  echo -e "${BOLD}  Orchestrator: $(hostname -s)   |   $(ts)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true

  # Step 1: Resolve uipathctl locally
  if ! resolve_uipathctl; then
    abort "uipathctl not found — set --installer-dir=<path> or ensure uipathctl is in PATH"
  fi

  # Step 2: Check sshpass
  check_sshpass

  # Step 3: Discover nodes
  discover_nodes

  local server_nodes=()
  local agent_nodes=()
  while IFS= read -r n; do
    [[ -n "${n}" ]] && server_nodes+=("${n}")
  done < /tmp/patch-orchestrate-servers.$$
  while IFS= read -r n; do
    [[ -n "${n}" ]] && agent_nodes+=("${n}")
  done < /tmp/patch-orchestrate-agents.$$
  rm -f /tmp/patch-orchestrate-servers.$$ /tmp/patch-orchestrate-agents.$$

  # Step 4: Detect etcd leader + split server nodes
  detect_leader

  local non_leaders=()
  for node in "${server_nodes[@]}"; do
    if [[ "${node}" != "${LEADER_NODE}" ]]; then
      non_leaders+=("${node}")
    fi
  done

  # Step 5: Print topology
  echo -e "${BOLD}--- Cluster Topology ---${RESET}"
  echo "  Server nodes:   ${server_nodes[*]:-none}"
  echo "  etcd leader:    ${LEADER_NODE:-unknown} (stop last, reboot first)"
  echo "  Non-leaders:    ${non_leaders[*]:-none}"
  echo "  Agent nodes:    ${agent_nodes[*]:-none}"
  echo ""
  echo "  Stop order:     agents → non-leader servers → ${LEADER_NODE:-leader} (last)"
  echo "  Reboot order:   ${LEADER_NODE:-leader} (first) → other servers → agents"
  echo ""

  # Step 6: Test SSH connectivity to all nodes
  local all_nodes=("${server_nodes[@]}" "${agent_nodes[@]}")
  if [[ ${#all_nodes[@]} -gt 0 ]]; then
    test_ssh_connectivity "${all_nodes[@]}"
  fi

  # Step 7: Health check (local uipathctl)
  run_health_check

  # Step 8: Enable maintenance mode (local uipathctl)
  enable_maintenance_mode

  # Step 9: Cordon all nodes (local kubectl)
  cordon_all_nodes "${all_nodes[@]}"

  # Step 10: Backup all server nodes in parallel
  if [[ ${#server_nodes[@]} -gt 0 ]]; then
    backup_server_nodes "${server_nodes[@]}"
  fi

  # Step 11: Stop agent nodes (sequential)
  if [[ ${#agent_nodes[@]} -gt 0 ]]; then
    echo -e "\n${BOLD}--- Stopping Agent Nodes (sequential) ---${RESET}"
    for node in "${agent_nodes[@]}"; do
      stop_agent_node "${node}"
    done
  fi

  # Step 12: Stop non-leader servers (sequential)
  if [[ ${#non_leaders[@]} -gt 0 ]]; then
    echo -e "\n${BOLD}--- Stopping Non-Leader Server Nodes (sequential) ---${RESET}"
    for node in "${non_leaders[@]}"; do
      stop_server_node "${node}"
    done
  fi

  # Step 13: Stop leader (last)
  if [[ -n "${LEADER_NODE}" ]]; then
    echo -e "\n${BOLD}--- Stopping etcd Leader: ${LEADER_NODE} (last) ---${RESET}"
    stop_server_node "${LEADER_NODE}"
  else
    warn "Leader node unknown — if any server nodes remain, stop them manually"
  fi

  # Final banner
  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${GREEN}${BOLD}  ALL NODES STOPPED${RESET}"
  echo ""
  echo -e "${BOLD}  REBOOT ORDER: ${LEADER_NODE:-leader} FIRST, then other servers, then agents${RESET}"
  echo ""
  echo -e "${YELLOW}${BOLD}  Patch team can now apply OS patches. Reboot leader first.${RESET}"
  echo ""
  echo -e "${BOLD}  State log: ${STATE_LOG}${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"
}

main "$@"
