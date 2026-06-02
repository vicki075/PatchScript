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
readonly CRICTL="/var/lib/rancher/rke2/bin/crictl"
readonly CRI_CONFIG="/var/lib/rancher/rke2/agent/etc/crictl.yaml"
readonly ETCD_CACERT="/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt"
readonly ETCD_CERT="/var/lib/rancher/rke2/server/tls/etcd/server-client.crt"
readonly ETCD_KEY="/var/lib/rancher/rke2/server/tls/etcd/server-client.key"
readonly ETCD_ENDPOINT="https://127.0.0.1:2379"

ETCD_EXEC_MODE=""
ETCD_CONTAINER_ID=""

readonly STATE_LOG="/opt/UiPathAutomationSuite/prepatch-state.log"
readonly BACKUP_BASE="/opt/UiPathAutomationSuite/backup_patch"

readonly DRAIN_TIMEOUT_SECS=600
readonly STOP_TIMEOUT_SECS=300
readonly KILLALL_TIMEOUT_SECS=120

SSH_USER="root"
SSH_PASSWORD=""
USE_SUDO=false    # auto-set to true when SSH_USER != "root"
SSH_PORT=22
INSTALLER_DIR=""
SKIP_HC_COMPONENTS=()
SERVER_NODES_ARG=""
AGENT_NODES_ARG=""
VERBOSE=false

UIPATHCTL_BIN=""
LEADER_NODE=""
SERVER_NODES=()   # populated in main() after discover_nodes; used by init_etcd_access + build_node_name_map
AGENT_NODES=()
declare -A NODE_K8S_NAME   # SSH addr (IP) → Kubernetes node name

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
  echo "                           If non-root (e.g. admin), sudo is used automatically."
  echo "                           The same password is used for SSH and sudo."
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
# Requires sshpass installed. Uses SSHPASS env var for SSH password auth.
#
# Sudo mode (auto-enabled when SSH_USER != "root"):
#   sshpass handles SSH authentication via the SSHPASS env var.
#   After SSH auth, the same password is piped as the first stdin line for
#   sudo -S, followed by the script body.  sudo reads one line (password),
#   then bash -s reads the rest (the actual commands).
#   Command: printf '%s\n%s\n' PASSWORD SCRIPT | ssh ... "sudo -S -p '' bash -s"
# =============================================================================
check_sshpass() {
  if ! command -v sshpass &>/dev/null; then
    abort "sshpass not installed. Install with: yum install sshpass  OR  apt-get install sshpass"
  fi
}

# _ssh_base <node> — emit common SSH options (used by remote and remote_bg)
_ssh_opts() {
  echo -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p "${SSH_PORT}"
}

# remote <node> <cmd> — blocking SSH, output tee'd to STATE_LOG
remote() {
  local node="$1"
  local cmd="$2"
  local exit_idx   # which PIPESTATUS slot holds the ssh/sudo exit code

  if [[ "${USE_SUDO}" == "true" ]]; then
    # Feed: line 1 = sudo password, remaining lines = script
    printf '%s\n%s\n' "${SSH_PASSWORD}" "${cmd}" \
      | SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
          -o StrictHostKeyChecking=no \
          -o ConnectTimeout=15 \
          -p "${SSH_PORT}" \
          "${SSH_USER}@${node}" \
          "sudo -S -p '' bash -s" 2>&1 \
      | tee -a "${STATE_LOG}"
    # PIPESTATUS: [0]=printf [1]=sshpass/ssh [2]=tee
    return "${PIPESTATUS[1]}"
  else
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -p "${SSH_PORT}" \
      "${SSH_USER}@${node}" \
      "${cmd}" 2>&1 | tee -a "${STATE_LOG}"
    return "${PIPESTATUS[0]}"
  fi
}

# remote_bg <node> <cmd> — non-blocking SSH (for parallel backup jobs)
remote_bg() {
  local node="$1"
  local cmd="$2"

  if [[ "${USE_SUDO}" == "true" ]]; then
    printf '%s\n%s\n' "${SSH_PASSWORD}" "${cmd}" \
      | SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
          -o StrictHostKeyChecking=no \
          -o ConnectTimeout=15 \
          -p "${SSH_PORT}" \
          "${SSH_USER}@${node}" \
          "sudo -S -p '' bash -s" 2>&1 \
      | tee -a "${STATE_LOG}"
  else
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -p "${SSH_PORT}" \
      "${SSH_USER}@${node}" \
      "${cmd}" 2>&1 | tee -a "${STATE_LOG}"
  fi
}

# =============================================================================
# SSH CONNECTIVITY TEST — verifies SSH + sudo (if non-root user)
# =============================================================================
test_ssh_connectivity() {
  local nodes=("$@")
  local failed=()

  log "Testing SSH connectivity to ${#nodes[@]} node(s) (user: ${SSH_USER}, sudo: ${USE_SUDO})..."
  for node in "${nodes[@]}"; do
    # Basic SSH test
    if ! SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
         -o StrictHostKeyChecking=no \
         -o ConnectTimeout=15 \
         -p "${SSH_PORT}" \
         "${SSH_USER}@${node}" \
         "echo ssh-ok" &>/dev/null; then
      warn "  SSH FAIL: ${node}"
      failed+=("${node}")
      continue
    fi

    # Sudo test (non-root users)
    if [[ "${USE_SUDO}" == "true" ]]; then
      local sudo_out
      sudo_out=$(printf '%s\nid\n' "${SSH_PASSWORD}" \
        | SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=15 \
            -p "${SSH_PORT}" \
            "${SSH_USER}@${node}" \
            "sudo -S -p '' bash -s" 2>/dev/null)
      if echo "${sudo_out}" | grep -q "uid=0"; then
        pass "  SSH + sudo OK: ${node}"
      else
        warn "  SSH OK but sudo to root FAILED on ${node} — check sudoers"
        failed+=("${node}")
      fi
    else
      pass "  SSH OK: ${node}"
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    abort "SSH/sudo connectivity test failed for: ${failed[*]}"
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
# ETCD ACCESS — ported from 01-preflight.sh
# Priority: local host binary → local crictl container exec → SSH into first server
# =============================================================================
init_etcd_access() {
  # 1. Local host binary
  if [[ -x "${ETCDCTL}" ]]; then
    ETCD_EXEC_MODE="host"
    info "etcd access: local host binary (${ETCDCTL})"
    return 0
  fi

  # 2. Local crictl container exec
  if [[ -x "${CRICTL}" ]]; then
    local cid
    cid=$(CRI_CONFIG_FILE="${CRI_CONFIG}" \
      "${CRICTL}" ps --label io.kubernetes.container.name=etcd --quiet 2>/dev/null | head -1)
    if [[ -n "${cid}" ]]; then
      ETCD_EXEC_MODE="container"
      ETCD_CONTAINER_ID="${cid}"
      info "etcd access: crictl container exec (${cid:0:12})"
      return 0
    fi
  fi

  # 3. SSH into first server node and run etcdctl there
  local first_server="${SERVER_NODES[0]:-}"
  if [[ -n "${first_server}" ]]; then
    info "etcd not accessible locally — will run via SSH on ${first_server}"
    ETCD_EXEC_MODE="ssh:${first_server}"
    return 0
  fi

  warn "etcdctl not accessible locally or via SSH — leader detection skipped"
  return 1
}

etcdctl_cmd() {
  local args=("$@")
  case "${ETCD_EXEC_MODE}" in
    host)
      "${ETCDCTL}" \
        --endpoints="${ETCD_ENDPOINT}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" \
        "${args[@]}"
      ;;
    container)
      CRI_CONFIG_FILE="${CRI_CONFIG}" \
      "${CRICTL}" exec -i "${ETCD_CONTAINER_ID}" \
        etcdctl \
        --endpoints="${ETCD_ENDPOINT}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" \
        "${args[@]}"
      ;;
    ssh:*)
      local ssh_node="${ETCD_EXEC_MODE#ssh:}"
      # Build the etcdctl command as a remote string
      local remote_args
      remote_args=$(printf ' %q' "${args[@]}")
      remote "${ssh_node}" "
export PATH=\$PATH:/usr/local/bin:/var/lib/rancher/rke2/bin
/var/lib/rancher/rke2/bin/etcdctl \
  --endpoints=${ETCD_ENDPOINT} \
  --cacert=${ETCD_CACERT} \
  --cert=${ETCD_CERT} \
  --key=${ETCD_KEY} \
  ${remote_args} 2>/dev/null
" 2>/dev/null
      ;;
    *)
      echo "etcdctl not available" >&2; return 1 ;;
  esac
}

# =============================================================================
# IP → KUBERNETES NODE NAME RESOLUTION
# When --servers/--agents are given as IPs, kubectl needs the actual node name.
# Build NODE_K8S_NAME map from: kubectl get nodes -o wide (NAME + INTERNAL-IP)
# SSH uses the original addr (IP); kubectl uses k8s_name(addr).
# =============================================================================
build_node_name_map() {
  info "Resolving SSH addresses to Kubernetes node names..."
  local nodes_wide
  nodes_wide=$(kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{print $1, $6}') || return 0
  # awk fields: $1=NAME  $6=INTERNAL-IP

  for addr in "${SERVER_NODES[@]:-}" "${AGENT_NODES[@]:-}"; do
    [[ -z "${addr}" ]] && continue
    # Already a node name?
    if echo "${nodes_wide}" | awk '{print $1}' | grep -qx "${addr}"; then
      NODE_K8S_NAME["${addr}"]="${addr}"
    else
      local name
      name=$(echo "${nodes_wide}" | awk -v ip="${addr}" '$2==ip {print $1}' | head -1)
      if [[ -n "${name}" ]]; then
        NODE_K8S_NAME["${addr}"]="${name}"
        info "  ${addr} → ${name}"
      else
        NODE_K8S_NAME["${addr}"]="${addr}"
        warn "  Could not resolve ${addr} to a k8s node name — kubectl ops may fail"
      fi
    fi
  done
}

# k8s_name <ssh-addr> — Kubernetes node name for kubectl operations
k8s_name() { echo "${NODE_K8S_NAME[${1}]:-${1}}"; }

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
# ETCD LEADER DETECTION
# Uses init_etcd_access() + etcdctl_cmd() — host binary → crictl → SSH fallback.
# LEADER_NODE is set to the SSH address (IP) from SERVER_NODES that matches
# the etcd leader IP, so that node comparison in main() works correctly.
# =============================================================================
detect_leader() {
  if ! init_etcd_access; then
    warn "etcd not accessible — leader detection skipped (will stop servers in listed order)"
    LEADER_NODE="${SERVER_NODES[${#SERVER_NODES[@]}-1]:-}"
    [[ -n "${LEADER_NODE}" ]] && warn "  Defaulting leader to last server: ${LEADER_NODE}"
    return 0
  fi

  local cluster_status
  cluster_status=$(etcdctl_cmd endpoint status --cluster -w json 2>/dev/null || true)

  if [[ -z "${cluster_status}" ]]; then
    warn "etcdctl cluster endpoint status returned empty — leader unknown"
    LEADER_NODE="${SERVER_NODES[${#SERVER_NODES[@]}-1]:-}"
    [[ -n "${LEADER_NODE}" ]] && warn "  Defaulting leader to last server: ${LEADER_NODE}"
    return 0
  fi

  # Parse the leader's IP from the etcd JSON output
  local leader_ip
  leader_ip=$(echo "${cluster_status}" | python3 -c "
import json, sys
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
            print(ip)
            break
except Exception:
    pass
" 2>/dev/null || true)

  if [[ -z "${leader_ip}" ]]; then
    warn "Could not parse etcd leader IP — leader unknown"
    LEADER_NODE="${SERVER_NODES[${#SERVER_NODES[@]}-1]:-}"
    [[ -n "${LEADER_NODE}" ]] && warn "  Defaulting leader to last server: ${LEADER_NODE}"
    return 0
  fi

  # Match leader_ip against SERVER_NODES list (which may be IPs for SSH)
  LEADER_NODE=""
  for node in "${SERVER_NODES[@]:-}"; do
    if [[ "${node}" == "${leader_ip}" ]]; then
      LEADER_NODE="${node}"
      break
    fi
  done

  # If SERVER_NODES contain hostnames, check the resolved IPs in NODE_K8S_NAME
  if [[ -z "${LEADER_NODE}" ]]; then
    for node in "${SERVER_NODES[@]:-}"; do
      local kname="${NODE_K8S_NAME[${node}]:-}"
      if [[ "${kname}" == "${leader_ip}" ]]; then
        LEADER_NODE="${node}"
        break
      fi
    done
  fi

  if [[ -z "${LEADER_NODE}" ]]; then
    warn "Leader IP ${leader_ip} not found in SERVER_NODES — defaulting to last server"
    LEADER_NODE="${SERVER_NODES[${#SERVER_NODES[@]}-1]:-}"
  fi

  log "${GREEN}[INFO]${RESET}  etcd leader IP: ${leader_ip} → SSH addr: ${LEADER_NODE}"
}

# =============================================================================
# HEALTH CHECK (local uipathctl)
# =============================================================================
run_health_check() {
  echo -e "\n${BOLD}--- Health Check ---${RESET}"

  local mm_raw
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled 2>/dev/null || true)

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

  # Extract ALL-CAPS bracket tokens from ❌ lines: ❌ [COMPONENTNAME] or ❌ [COMPONENT_SUBCHECK]
  local failed_components=()
  while IFS= read -r line; do
    if echo "${line}" | grep -qE '❌'; then
      local comp
      comp=$(echo "${line}" | grep -oE '\[[A-Z_]+\]' | head -1 | tr -d '[]')
      [[ -n "${comp}" ]] && failed_components+=("${comp}")
    fi
  done <<< "${cleaned}"

  if [[ ${#failed_components[@]} -eq 0 ]]; then
    abort "Health check command failed — check binary version/path (use --installer-dir)"
  fi

  # --skip-hc=all  →  ignore every failure
  for skip_comp in "${SKIP_HC_COMPONENTS[@]:-}"; do
    if [[ "${skip_comp,,}" == "all" ]]; then
      warn "Health check had failures — skipped via --skip-hc=all: ${failed_components[*]}"
      return 0
    fi
  done

  # Prefix match: --skip-hc=DOCUMENTUNDERSTANDING covers DOCUMENTUNDERSTANDING_HEALTH too
  local unresolved=()
  for comp in "${failed_components[@]}"; do
    local skip=false
    for skip_comp in "${SKIP_HC_COMPONENTS[@]:-}"; do
      if [[ "${comp,,}" == "${skip_comp,,}"* ]]; then
        skip=true
        break
      fi
    done
    [[ "${skip}" == "false" ]] && unresolved+=("${comp}")
  done

  if [[ ${#unresolved[@]} -gt 0 ]]; then
    local unresolved_str
    unresolved_str=$(IFS=','; echo "${unresolved[*]}")
    log "${YELLOW}[WARN]${RESET}  Failed components not in skip list:"
    for c in "${unresolved[@]}"; do log "${YELLOW}[WARN]${RESET}    ❌  ${c}"; done
    abort "Health check failed — unresolved: ${unresolved_str}
  Use --skip-hc=all to bypass everything, or --skip-hc=SYNC,DOCUMENTUNDERSTANDING for specific ones."
  fi

  warn "Health check had failures — all covered by --skip-hc: ${failed_components[*]} — continuing"
}

# =============================================================================
# MAINTENANCE MODE (local uipathctl)
# =============================================================================
enable_maintenance_mode() {
  echo -e "\n${BOLD}--- Enable Maintenance Mode ---${RESET}"

  local mm_raw
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled 2>/dev/null || true)

  if maintenance_is_enabled "${mm_raw}"; then
    pass "Maintenance mode already enabled — skipping"
    return 0
  fi

  info "Enabling maintenance mode..."
  local enable_out enable_exit=0
  enable_out=$("${UIPATHCTL_BIN}" cluster maintenance enable \
    --timeout 20m 2>&1) || enable_exit=$?
  local enable_clean
  enable_clean=$(echo "${enable_out}" | grep -vE '^(INFO|WARN|ERRO|DEBU)\[[0-9]' || true)
  if [[ "${enable_exit}" -ne 0 ]]; then
    log "${RED}[FAIL]${RESET}  uipathctl cluster maintenance enable failed"
    echo "${enable_clean}" | sed 's/^/    /'
    abort "uipathctl cluster maintenance enable failed — see output above"
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
    local kname; kname=$(k8s_name "${node}")
    kubectl label node "${kname}" nodejanitor/skip=true --overwrite 2>/dev/null \
      || warn "  label nodejanitor/skip=true failed for ${kname} (SSH: ${node})"
    kubectl cordon "${kname}" 2>/dev/null \
      || warn "  cordon failed for ${kname} (SSH: ${node})"
    pass "  Cordoned: ${kname} (SSH: ${node})"
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

  # Step 1 (UiPath docs): stop node-drain.service — ExecStop=/opt/node-drain.sh does
  # the actual kubectl drain; timeout must cover full drain time, not just service startup
  log "  Running on ${node}: systemctl stop node-drain.service"
  remote "${node}" "
if systemctl is-active --quiet node-drain.service 2>/dev/null \
   || systemctl is-enabled --quiet node-drain.service 2>/dev/null; then
  echo '  node-drain.service found — stopping (timeout: ${DRAIN_TIMEOUT_SECS}s)'
  if timeout ${DRAIN_TIMEOUT_SECS} systemctl stop node-drain.service 2>&1; then
    echo '[PASS]  node-drain.service stopped'
  else
    echo \"[WARN]  systemctl stop node-drain.service exited \$? — continuing with kubectl drain\"
  fi
else
  echo '[WARN]  node-drain.service not found or disabled — will kubectl drain directly'
fi
" || warn "  node-drain remote check returned non-zero for ${node}"

  # Step 1b: Kubernetes-level pod eviction (local kubectl — uses k8s node name)
  local kname; kname=$(k8s_name "${node}")
  log "  Running: kubectl drain ${kname} --ignore-daemonsets --delete-emptydir-data --timeout=${DRAIN_TIMEOUT_SECS}s --force"
  if ! kubectl drain "${kname}" \
       --ignore-daemonsets \
       --delete-emptydir-data \
       --timeout="${DRAIN_TIMEOUT_SECS}s" \
       --force 2>&1; then
    warn "  kubectl drain returned non-zero for ${kname} — continuing"
  fi
  pass "  Drain complete: ${kname}"

  # Step 2 (UiPath docs): stop the Kubernetes process + Step 3: killall
  log "  Running on ${node}: systemctl stop rke2-agent + rke2-killall.sh"
  remote "${node}" "
export PATH=\"\$PATH:/usr/local/bin:/var/lib/rancher/rke2/bin\"
MYHOST=\$(hostname -s)
echo \"  Running: systemctl stop rke2-agent  (timeout: ${STOP_TIMEOUT_SECS}s)\"
if timeout ${STOP_TIMEOUT_SECS} systemctl stop rke2-agent 2>&1; then
  echo '[PASS]  rke2-agent stopped'
else
  echo '[WARN]  rke2-agent stop returned non-zero — continuing to killall'
fi
echo \"  Running: rke2-killall.sh  (timeout: ${KILLALL_TIMEOUT_SECS}s)\"
timeout ${KILLALL_TIMEOUT_SECS} rke2-killall.sh 2>&1 || echo '[WARN]  rke2-killall.sh returned non-zero'
echo '[PASS]  rke2-killall.sh complete'
residual=\$(ps aux 2>/dev/null | grep -E 'containerd|kubelet|rke2' | grep -v grep | grep -v patch-orchestrate || true)
if [[ -n \"\${residual}\" ]]; then
  echo \"[WARN]  Residual processes remain on \${MYHOST}:\"
  echo \"\${residual}\" | sed 's/^/    /'
else
  echo \"[PASS]  No residual rke2/containerd/kubelet processes on \${MYHOST}\"
fi
" || warn "  SSH stop command returned non-zero for ${node}"

  state_log "AGENT_STOPPED  ${node}  k8s=${kname}  (orchestrated)"
  pass "  Agent node ${node} (${kname}): stopped"
}

stop_server_node() {
  local node="$1"
  echo -e "\n${BOLD}--- Stop Server Node: ${node} ---${RESET}"

  # Step 1 (UiPath docs): stop node-drain.service — ExecStop=/opt/node-drain.sh does
  # the actual kubectl drain; timeout must cover full drain time, not just service startup
  log "  Running on ${node}: systemctl stop node-drain.service"
  remote "${node}" "
if systemctl is-active --quiet node-drain.service 2>/dev/null \
   || systemctl is-enabled --quiet node-drain.service 2>/dev/null; then
  echo '  node-drain.service found — stopping (timeout: ${DRAIN_TIMEOUT_SECS}s)'
  if timeout ${DRAIN_TIMEOUT_SECS} systemctl stop node-drain.service 2>&1; then
    echo '[PASS]  node-drain.service stopped'
  else
    echo \"[WARN]  systemctl stop node-drain.service exited \$? — continuing with kubectl drain\"
  fi
else
  echo '[WARN]  node-drain.service not found or disabled — will kubectl drain directly'
fi
" || warn "  node-drain remote check returned non-zero for ${node}"

  # Step 1b: Kubernetes-level pod eviction (local kubectl — uses k8s node name)
  local kname; kname=$(k8s_name "${node}")
  log "  Running: kubectl drain ${kname} --ignore-daemonsets --delete-emptydir-data --timeout=${DRAIN_TIMEOUT_SECS}s --force"
  if ! kubectl drain "${kname}" \
       --ignore-daemonsets \
       --delete-emptydir-data \
       --timeout="${DRAIN_TIMEOUT_SECS}s" \
       --force 2>&1; then
    warn "  kubectl drain returned non-zero for ${kname} — continuing"
  fi
  pass "  Drain complete: ${kname}"

  # Step 2 (UiPath docs): stop the Kubernetes process + Step 3: killall
  log "  Running on ${node}: systemctl stop rke2-server + rke2-killall.sh"
  remote "${node}" "
export PATH=\"\$PATH:/usr/local/bin:/var/lib/rancher/rke2/bin\"
MYHOST=\$(hostname -s)
echo \"  Running: systemctl stop rke2-server  (timeout: ${STOP_TIMEOUT_SECS}s)\"
if timeout ${STOP_TIMEOUT_SECS} systemctl stop rke2-server 2>&1; then
  echo '[PASS]  rke2-server stopped'
else
  echo '[WARN]  rke2-server stop returned non-zero — continuing to killall'
fi
echo \"  Running: rke2-killall.sh  (timeout: ${KILLALL_TIMEOUT_SECS}s)\"
timeout ${KILLALL_TIMEOUT_SECS} rke2-killall.sh 2>&1 || echo '[WARN]  rke2-killall.sh returned non-zero'
echo '[PASS]  rke2-killall.sh complete'
residual=\$(ps aux 2>/dev/null | grep -E 'containerd|kubelet|rke2' | grep -v grep | grep -v patch-orchestrate || true)
if [[ -n \"\${residual}\" ]]; then
  echo \"[WARN]  Residual processes remain on \${MYHOST}:\"
  echo \"\${residual}\" | sed 's/^/    /'
else
  echo \"[PASS]  No residual rke2/containerd/kubelet processes on \${MYHOST}\"
fi
" || warn "  SSH stop command returned non-zero for ${node}"

  state_log "SERVER_STOPPED  ${node}  k8s=${kname}  (orchestrated)"
  pass "  Server node ${node} (${kname}): stopped"
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

  # Auto-enable sudo when SSH user is not root
  if [[ "${SSH_USER}" != "root" ]]; then
    USE_SUDO=true
    log "${CYAN}[INFO]${RESET}  Non-root SSH user '${SSH_USER}' — sudo mode enabled (same password used for sudo)"
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

  # Populate global SERVER_NODES / AGENT_NODES (used by init_etcd_access, build_node_name_map, detect_leader)
  SERVER_NODES=()
  AGENT_NODES=()
  while IFS= read -r n; do
    [[ -n "${n}" ]] && SERVER_NODES+=("${n}")
  done < /tmp/patch-orchestrate-servers.$$
  while IFS= read -r n; do
    [[ -n "${n}" ]] && AGENT_NODES+=("${n}")
  done < /tmp/patch-orchestrate-agents.$$
  rm -f /tmp/patch-orchestrate-servers.$$ /tmp/patch-orchestrate-agents.$$

  # Step 4a: Build IP → k8s node name map (SSH addrs may be IPs; kubectl needs node names)
  build_node_name_map

  # Step 4b: Detect etcd leader + split server nodes
  detect_leader

  local non_leaders=()
  for node in "${SERVER_NODES[@]}"; do
    if [[ "${node}" != "${LEADER_NODE}" ]]; then
      non_leaders+=("${node}")
    fi
  done

  # Step 5: Print topology
  echo -e "${BOLD}--- Cluster Topology ---${RESET}"
  echo "  Server nodes (SSH): ${SERVER_NODES[*]:-none}"
  echo "  etcd leader:        ${LEADER_NODE:-unknown} (stop last, reboot first)"
  echo "  Non-leaders:        ${non_leaders[*]:-none}"
  echo "  Agent nodes (SSH):  ${AGENT_NODES[*]:-none}"
  echo ""
  echo "  Stop order:     agents → non-leader servers → ${LEADER_NODE:-leader} (last)"
  echo "  Reboot order:   ${LEADER_NODE:-leader} (first) → other servers → agents"
  echo ""

  # Step 6: Test SSH connectivity to all nodes
  local all_nodes=("${SERVER_NODES[@]}" "${AGENT_NODES[@]}")
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
  if [[ ${#SERVER_NODES[@]} -gt 0 ]]; then
    backup_server_nodes "${SERVER_NODES[@]}"
  fi

  # Step 11: Stop agent nodes (sequential)
  if [[ ${#AGENT_NODES[@]} -gt 0 ]]; then
    echo -e "\n${BOLD}--- Stopping Agent Nodes (sequential) ---${RESET}"
    for node in "${AGENT_NODES[@]}"; do
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
