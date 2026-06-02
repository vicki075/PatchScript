#!/usr/bin/env bash
# =============================================================================
# patch-node.sh — UiPath AS 24.10.4 / RKE2 Per-Node Unattended Pre-Patch
#
# Runs as a cron job on each node, staggered 5 minutes apart.
# Recommended order: agent nodes first → non-leader servers → etcd leader last.
#
# Node coordination uses Kubernetes annotations (prepatch.uipath.io/phase).
# The leader polls annotations and waits for all other nodes to reach
# ready-to-stop before stopping itself.
#
# chmod +x patch-node.sh
#
# Usage:
#   patch-node.sh [OPTIONS]
#
# Options:
#   --installer-dir=<path>   UiPath version folder; binary at <dir>/installer/bin/uipathctl
#   --skip-hc=comp1,comp2   Comma-separated health check component names to skip on failure
#   --identify-leader        Print leader name and scheduling advice, then exit (no changes)
#   --verbose                Show INFO lines
#   --help                   Show this help
#
# Exit codes:
#   0  — completed successfully
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

LEADER_WAIT_TIMEOUT_MINS=90
INSTALLER_DIR=""
SKIP_HC_COMPONENTS=()
IDENTIFY_LEADER_ONLY=false
VERBOSE=false

UIPATHCTL_BIN=""
MY_NODE=""
IS_SERVER=false
IS_LEADER=false
LEADER_NODE=""
KUBECTL_AVAILABLE=false

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
  echo "$(ts)  FAIL  $(hostname -s)  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
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
  echo "  --installer-dir=<path>   UiPath version folder; binary at <dir>/installer/bin/uipathctl"
  echo "  --skip-hc=all           Skip health check failures entirely"
  echo "  --skip-hc=comp1,comp2   Skip specific failing components by name"
  echo "  --identify-leader        Print leader name and scheduling advice, then exit"
  echo "  --verbose                Show INFO lines"
  echo "  --help                   Show this help"
  echo ""
}

# =============================================================================
# LOCKING — flock on /var/run/patch-node.lock
# =============================================================================
LOCK_FD=200
LOCK_FILE="/var/run/patch-node.lock"

acquire_lock() {
  exec 200>"${LOCK_FILE}"
  if ! flock -n ${LOCK_FD}; then
    abort "Another instance of patch-node.sh is already running (lock: ${LOCK_FILE})"
  fi
  info "Lock acquired: ${LOCK_FILE}"
}

# =============================================================================
# ETCDCTL
# =============================================================================
etcdctl_cmd() {
  "${ETCDCTL}" \
    --endpoints="${ETCD_ENDPOINT}" \
    --cacert="${ETCD_CACERT}" \
    --cert="${ETCD_CERT}" \
    --key="${ETCD_KEY}" \
    "$@"
}

# =============================================================================
# uipathctl resolution
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
# ROLE + LEADER DETECTION
# =============================================================================
detect_role() {
  # IS_SERVER: directory/file presence, not systemctl
  if [[ -f /etc/rancher/rke2/rke2.yaml ]] \
     || [[ -d /var/lib/rancher/rke2/server/db/snapshots ]] \
     || [[ -d /var/lib/rancher/rke2/server/tls ]]; then
    IS_SERVER=true
  else
    IS_SERVER=false
  fi
  info "Role: $( [[ "${IS_SERVER}" == "true" ]] && echo "server" || echo "agent" )"
}

detect_my_node() {
  local short_host
  short_host=$(hostname -s)

  if [[ "${KUBECTL_AVAILABLE}" == "true" ]]; then
    MY_NODE=$(kubectl get nodes --no-headers \
      -o custom-columns='NAME:.metadata.name' 2>/dev/null \
      | grep -F "${short_host}" | head -1 || true)

    if [[ -z "${MY_NODE}" ]]; then
      MY_NODE=$(kubectl get nodes --no-headers \
        -o custom-columns='NAME:.metadata.name' 2>/dev/null \
        | awk -v h="${short_host}" '$1 == h' | head -1 || true)
    fi
  fi

  # kubectl unavailable or node not found — fall back to local hostname.
  # Expected on the last server node when the other 2 are already stopped
  # (etcd quorum lost → API server unreachable).
  if [[ -z "${MY_NODE}" ]]; then
    MY_NODE="${short_host}"
    info "Node name resolved from hostname (kubectl unavailable): ${MY_NODE}"
  else
    info "My node name: ${MY_NODE}"
  fi
}

detect_leader() {
  if [[ "${IS_SERVER}" != "true" ]]; then
    IS_LEADER=false
    LEADER_NODE=""
    return 0
  fi

  if [[ ! -x "${ETCDCTL}" ]]; then
    warn "etcdctl not found at ${ETCDCTL} — skipping leader detection"
    IS_LEADER=false
    LEADER_NODE=""
    return 0
  fi

  # Local endpoint status — compare member_id == leader
  local local_status
  local_status=$(etcdctl_cmd endpoint status \
    --endpoints=127.0.0.1:2379 -w json 2>/dev/null || true)

  if [[ -z "${local_status}" ]]; then
    warn "etcdctl endpoint status returned empty — skipping leader detection"
    IS_LEADER=false
    LEADER_NODE=""
    return 0
  fi

  IS_LEADER=$(echo "${local_status}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list):
    e = data[0]
else:
    e = data
st = e.get('Status', {})
member_id = st.get('header', {}).get('member_id', -1)
leader_id = st.get('leader', -2)
print('true' if member_id == leader_id else 'false')
" 2>/dev/null || echo "false")

  # Resolve LEADER_NODE name via cluster-wide status + node IP map
  local cluster_status
  cluster_status=$(etcdctl_cmd endpoint status \
    --cluster -w json 2>/dev/null || true)

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

  info "IS_LEADER=${IS_LEADER}  LEADER_NODE=${LEADER_NODE:-unknown}"
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
# MODE: --identify-leader
# =============================================================================
mode_identify_leader() {
  echo -e "\n${BOLD}--- Identifying etcd leader ---${RESET}"

  detect_role
  detect_leader

  if [[ -z "${LEADER_NODE}" ]]; then
    warn "Could not resolve leader node name — etcdctl may not be available on this node"
  else
    log "${CYAN}[INFO]${RESET}  etcd leader: ${LEADER_NODE}"
    echo ""
    echo -e "${BOLD}Scheduling advice:${RESET}"
    echo "  Stop order:  agents first → non-leader servers → ${LEADER_NODE} LAST"
    echo "  Reboot order: ${LEADER_NODE} FIRST → other servers → agents"
  fi

  echo ""
}

# =============================================================================
# PHASE 1 — Health check
# =============================================================================
phase_health_check() {
  echo -e "\n${BOLD}--- Phase 1: Health Check ---${RESET}"

  # Check if maintenance mode is already enabled — if so, skip HC entirely
  local mm_raw
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled \
    --namespace "${UIPATH_NS}" 2>/dev/null || true)

  if maintenance_is_enabled "${mm_raw}"; then
    pass "Phase 1: Maintenance mode already enabled — skipping health check"
    return 0
  fi

  info "Running: ${UIPATHCTL_BIN} health check --timeout 10m"
  local hc_output hc_exit=0
  hc_output=$("${UIPATHCTL_BIN}" health check --timeout 10m 2>&1) || hc_exit=$?

  # Strip logrus lines
  local cleaned
  cleaned=$(echo "${hc_output}" | grep -vE '^(INFO|WARN|ERRO|DEBU)\[[0-9]' || true)

  echo ""
  echo "${cleaned}" | sed 's/^/  /'
  echo ""

  if [[ ${hc_exit} -eq 0 ]]; then
    pass "Phase 1: Health check passed"
    return 0
  fi

  # Parse failed component names from ❌ lines.
  # uipathctl output format:  ❌ [COMPONENTNAME]  or  ❌ [COMPONENTNAME_SUBCHECK] detail text
  # Extract only the ALL-CAPS bracket token (strips brackets, ignores namespace/kind detail lines).
  # Example: "  ❌ [DOCUMENTUNDERSTANDING_HEALTH] health status is Progressing"
  #       →  "DOCUMENTUNDERSTANDING_HEALTH"
  local failed_components=()
  while IFS= read -r line; do
    if echo "${line}" | grep -qE '❌'; then
      local comp
      comp=$(echo "${line}" | grep -oE '\[[A-Z_]+\]' | head -1 | tr -d '[]')
      [[ -n "${comp}" ]] && failed_components+=("${comp}")
    fi
  done <<< "${cleaned}"

  if [[ ${#failed_components[@]} -eq 0 ]]; then
    # hc_exit != 0 but no ❌ lines parsed — command-level error
    abort "Phase 1: Health check command failed — check binary version/path (use --installer-dir)"
  fi

  # --skip-hc=all  →  ignore every failure
  for skip_comp in "${SKIP_HC_COMPONENTS[@]:-}"; do
    if [[ "${skip_comp,,}" == "all" ]]; then
      warn "Phase 1: Health check had failures — skipped via --skip-hc=all: ${failed_components[*]}"
      return 0
    fi
  done

  # Check each failed component against the explicit skip list.
  # Prefix match: --skip-hc=DOCUMENTUNDERSTANDING covers both
  # DOCUMENTUNDERSTANDING and DOCUMENTUNDERSTANDING_HEALTH.
  local unresolved=()
  for comp in "${failed_components[@]}"; do
    local skip=false
    for skip_comp in "${SKIP_HC_COMPONENTS[@]:-}"; do
      # prefix match (case-insensitive): skip_comp matches comp if comp starts with skip_comp
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
    abort "Phase 1: Health check failed — unresolved: ${unresolved_str}
  Use --skip-hc=all to bypass everything, or --skip-hc=SYNC,DOCUMENTUNDERSTANDING for specific ones."
  fi

  warn "Phase 1: Health check had failures — all covered by --skip-hc: ${failed_components[*]} — continuing"
}

# =============================================================================
# PHASE 2 — Maintenance mode
# =============================================================================
phase_maintenance_mode() {
  echo -e "\n${BOLD}--- Phase 2: Enable Maintenance Mode ---${RESET}"

  local mm_raw
  mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled 2>/dev/null || true)

  if maintenance_is_enabled "${mm_raw}"; then
    pass "Phase 2: Maintenance mode already enabled — skipping"
    return 0
  fi

  log "  Enabling maintenance mode..."
  local enable_out enable_exit=0
  enable_out=$("${UIPATHCTL_BIN}" cluster maintenance enable \
    --timeout 30m --force 2>&1) || enable_exit=$?

  if [[ "${enable_exit}" -ne 0 ]]; then
    local enable_clean
    enable_clean=$(echo "${enable_out}" | grep -vE '^(INFO|WARN|ERRO|DEBU)\[[0-9]' || true)
    log "${RED}[FAIL]${RESET}  uipathctl cluster maintenance enable failed:"
    echo "${enable_clean}" | sed 's/^/    /'
    abort "Phase 2: maintenance enable failed — see output above"
  fi

  # Wait up to 3 min for UiPath pods to scale to 0
  log "  Waiting for UiPath pods to scale down (up to 3 min)..."
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
    log "  ${running_count} pod(s) still Running — waiting..."
    sleep 15
  done

  running_count=$(kubectl get pods -n "${UIPATH_NS}" \
    --no-headers 2>/dev/null \
    | grep -v -E 'Completed|Terminating' \
    | grep -c 'Running' || echo "0")

  if [[ "${running_count}" -gt 0 ]]; then
    warn "Phase 2: ${running_count} Running UiPath pod(s) still present after 3m — continuing"
  fi

  pass "Phase 2: Maintenance mode enabled"
  state_log "MAINTENANCE_ENABLED  $(hostname -s)"
}

# =============================================================================
# PHASE 3 — Cordon + label
# =============================================================================
phase_cordon() {
  echo -e "\n${BOLD}--- Phase 3: Cordon + Label ---${RESET}"

  kubectl label node "${MY_NODE}" nodejanitor/skip=true --overwrite 2>/dev/null \
    || warn "Phase 3: kubectl label nodejanitor/skip=true failed (non-fatal)"
  kubectl cordon "${MY_NODE}" 2>/dev/null \
    || warn "Phase 3: kubectl cordon failed (non-fatal)"
  kubectl annotate node "${MY_NODE}" \
    prepatch.uipath.io/phase=cordoned --overwrite 2>/dev/null \
    || warn "Phase 3: annotate cordoned failed (non-fatal)"

  pass "Phase 3: Node cordoned and labelled"
}

# =============================================================================
# PHASE 4 — Print leader info
# =============================================================================
phase_leader_info() {
  echo -e "\n${BOLD}--- Phase 4: Leader Info ---${RESET}"

  if [[ "${IS_LEADER}" == "true" ]]; then
    log "${YELLOW}${BOLD}  ★ THIS NODE (${MY_NODE}) IS THE ETCD LEADER${RESET}"
    log "${YELLOW}${BOLD}    → Stop this node LAST among servers${RESET}"
    log "${YELLOW}${BOLD}    → Reboot this node FIRST after OS patch${RESET}"
  else
    if [[ -n "${LEADER_NODE}" ]]; then
      log "${CYAN}[INFO]${RESET}  etcd leader: ${BOLD}${LEADER_NODE}${RESET}"
      log "${CYAN}[INFO]${RESET}  This node (${MY_NODE}) is a non-leader — stops before the leader"
      log "${CYAN}[INFO]${RESET}  Stop order:  agents → non-leaders → ${LEADER_NODE} LAST"
      log "${CYAN}[INFO]${RESET}  Reboot order: ${LEADER_NODE} FIRST → other servers → agents"
    else
      log "${YELLOW}[WARN]${RESET}  Could not detect etcd leader (etcdctl unavailable or not a server node)"
      log "${YELLOW}[WARN]${RESET}  Identify leader manually before sequencing server stops"
    fi
  fi
}

# =============================================================================
# PHASE 5 — Drain
# =============================================================================
phase_drain() {
  echo -e "\n${BOLD}--- Phase 5: Drain ---${RESET}"

  systemctl stop node-drain.service 2>/dev/null || true

  info "Running: kubectl drain ${MY_NODE} --ignore-daemonsets --delete-emptydir-data --timeout=${DRAIN_TIMEOUT_SECS}s --force"
  if ! kubectl drain "${MY_NODE}" \
       --ignore-daemonsets \
       --delete-emptydir-data \
       --timeout="${DRAIN_TIMEOUT_SECS}s" \
       --force 2>&1; then
    warn "Phase 5: kubectl drain returned non-zero (daemonsets may cause warnings) — continuing"
  fi

  kubectl annotate node "${MY_NODE}" \
    prepatch.uipath.io/phase=drained --overwrite 2>/dev/null \
    || warn "Phase 5: annotate drained failed (non-fatal)"

  pass "Phase 5: Drain complete"
}

# =============================================================================
# PHASE 6 — Backup (server nodes only)
# =============================================================================
phase_backup() {
  if [[ "${IS_SERVER}" != "true" ]]; then
    info "Phase 6: Agent node — skipping etcd backup"
    return 0
  fi

  echo -e "\n${BOLD}--- Phase 6: etcd Snapshot Backup ---${RESET}"

  local snap_src="/var/lib/rancher/rke2/server/db/snapshots"
  local backup_dir="${BACKUP_BASE}/$(hostname -s)-$(date +%Y%m%d-%H%M%S)"
  local etcd_dir="${backup_dir}/etcd"
  local cfg_dir="${backup_dir}/rke2-config"

  mkdir -p "${etcd_dir}" "${cfg_dir}" \
    || abort "Phase 6: Could not create backup directory ${backup_dir}"

  # Collect last 2 snapshots (exclude .meta.json, sort by mtime)
  local snapshots=()
  while IFS= read -r snap; do
    snapshots+=("${snap}")
  done < <(find "${snap_src}" -maxdepth 1 -type f ! -name '*.meta.json' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -2 | awk '{print $2}')

  if [[ ${#snapshots[@]} -eq 0 ]]; then
    abort "Phase 6: No etcd snapshots found in ${snap_src}"
  fi

  for snap in "${snapshots[@]}"; do
    local dest="${etcd_dir}/$(basename "${snap}")"
    cp "${snap}" "${dest}" || abort "Phase 6: Failed to copy ${snap}"
    sha256sum "${dest}" | tee -a "${backup_dir}/sha256sums.txt" >/dev/null
    pass "Phase 6: Backed up $(basename "${snap}")"

    # Copy .meta.json if present
    local meta="${snap}.meta.json"
    if [[ -f "${meta}" ]]; then
      cp "${meta}" "${etcd_dir}/$(basename "${meta}")" \
        || warn "Phase 6: Failed to copy meta file $(basename "${meta}")"
      pass "Phase 6: Backed up $(basename "${meta}")"
    fi
  done

  # Copy rke2 config
  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    cp /etc/rancher/rke2/config.yaml "${cfg_dir}/config.yaml" \
      || warn "Phase 6: Failed to copy rke2 config.yaml"
    pass "Phase 6: Backed up rke2 config.yaml"
  fi

  kubectl annotate node "${MY_NODE}" \
    prepatch.uipath.io/phase=backed-up --overwrite 2>/dev/null \
    || warn "Phase 6: annotate backed-up failed (non-fatal)"

  pass "Phase 6: Backup complete — ${backup_dir}"
  state_log "BACKUP_COMPLETE  $(hostname -s)  dir=${backup_dir}"
}

# =============================================================================
# PHASE 7 — Signal ready-to-stop
# =============================================================================
phase_signal_ready() {
  echo -e "\n${BOLD}--- Phase 7: Signal Ready-to-Stop ---${RESET}"

  kubectl annotate node "${MY_NODE}" \
    prepatch.uipath.io/phase=ready-to-stop --overwrite 2>/dev/null \
    || warn "Phase 7: annotate ready-to-stop failed (non-fatal)"

  pass "Phase 7: Node signalled ready-to-stop"
}

# =============================================================================
# PHASE 8 — Leader wait (leader only)
# =============================================================================
phase_leader_wait() {
  if [[ "${IS_LEADER}" != "true" ]] || [[ "${IS_SERVER}" != "true" ]]; then
    info "Phase 8: Not leader or not server — skipping leader wait"
    return 0
  fi

  echo -e "\n${BOLD}--- Phase 8: Leader Wait (polling for all other nodes ready-to-stop) ---${RESET}"

  local deadline=$(( $(date +%s) + LEADER_WAIT_TIMEOUT_MINS * 60 ))

  while [[ $(date +%s) -lt ${deadline} ]]; do
    local pending
    pending=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys, os
my_node = os.environ.get('MY_NODE', '')
data = json.load(sys.stdin)
pending = []
for n in data.get('items', []):
    name = n['metadata']['name']
    if name == my_node:
        continue
    phase = n.get('metadata', {}).get('annotations', {}).get('prepatch.uipath.io/phase', '')
    if phase != 'ready-to-stop':
        pending.append(f'{name} (phase={phase!r})')
for p in pending:
    print(p)
" MY_NODE="${MY_NODE}" 2>/dev/null || true)

    if [[ -z "${pending}" ]]; then
      pass "Phase 8: All other nodes have signalled ready-to-stop"
      return 0
    fi

    warn "Phase 8: Waiting for nodes to reach ready-to-stop:"
    echo "${pending}" | sed 's/^/  /'
    sleep 30
  done

  abort "Phase 8: Timed out after ${LEADER_WAIT_TIMEOUT_MINS}m waiting for all other nodes to reach ready-to-stop"
}

# =============================================================================
# PHASE 9 — Stop RKE2
# =============================================================================
phase_stop_rke2() {
  echo -e "\n${BOLD}--- Phase 9: Stop RKE2 ---${RESET}"

  if [[ "${IS_SERVER}" == "true" ]]; then
    info "Stopping rke2-server (timeout: ${STOP_TIMEOUT_SECS}s)..."
    if ! timeout "${STOP_TIMEOUT_SECS}" systemctl stop rke2-server 2>&1; then
      warn "Phase 9: rke2-server did not stop within ${STOP_TIMEOUT_SECS}s — continuing"
    else
      pass "Phase 9: rke2-server stopped"
    fi
  else
    info "Stopping rke2-agent (timeout: ${STOP_TIMEOUT_SECS}s)..."
    if ! timeout "${STOP_TIMEOUT_SECS}" systemctl stop rke2-agent 2>&1; then
      warn "Phase 9: rke2-agent did not stop within ${STOP_TIMEOUT_SECS}s — continuing"
    else
      pass "Phase 9: rke2-agent stopped"
    fi
  fi

  info "Running rke2-killall.sh (timeout: ${KILLALL_TIMEOUT_SECS}s)..."
  timeout "${KILLALL_TIMEOUT_SECS}" rke2-killall.sh 2>&1 || warn "Phase 9: rke2-killall.sh returned non-zero"

  # Verify no residuals
  local residual
  residual=$(ps aux 2>/dev/null \
    | grep -E 'containerd|kubelet|rke2' \
    | grep -v grep \
    | grep -v "patch-node" || true)

  if [[ -n "${residual}" ]]; then
    warn "Phase 9: Residual processes remain — manual cleanup may be needed:"
    echo "${residual}" | sed 's/^/  /'
  else
    pass "Phase 9: No residual rke2/containerd/kubelet processes"
  fi

  # Annotate best-effort (API may be going down)
  kubectl annotate node "${MY_NODE}" \
    prepatch.uipath.io/phase=stopped --overwrite 2>/dev/null || true

  if [[ "${IS_SERVER}" == "true" ]]; then
    state_log "SERVER_STOPPED  $(hostname -s)"
  else
    state_log "AGENT_STOPPED  $(hostname -s)"
  fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  # Parse arguments
  for arg in "$@"; do
    case "${arg}" in
      --installer-dir=*) INSTALLER_DIR="${arg#*=}" ;;
      --skip-hc=*)
        IFS=',' read -ra SKIP_HC_COMPONENTS <<< "${arg#*=}"
        ;;
      --identify-leader) IDENTIFY_LEADER_ONLY=true ;;
      --verbose|-v) VERBOSE=true ;;
      --help|-h) usage; exit 0 ;;
      *) echo -e "${RED}Unknown argument: ${arg}${RESET}"; usage; exit 1 ;;
    esac
  done

  # Acquire flock
  acquire_lock

  # Identify-leader mode — print and exit, no changes
  if [[ "${IDENTIFY_LEADER_ONLY}" == "true" ]]; then
    mode_identify_leader
    exit 0
  fi

  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  patch-node.sh — UiPath AS 24.10.4 / RKE2 Pre-Patch${RESET}"
  echo -e "${BOLD}  Node: $(hostname -s)   |   $(ts)${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  # Check kubectl availability once — used to gate cluster-dependent phases
  if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
    KUBECTL_AVAILABLE=true
  else
    KUBECTL_AVAILABLE=false
  fi

  # Detect role and node name
  detect_role
  detect_my_node
  detect_leader

  if [[ "${KUBECTL_AVAILABLE}" == "false" ]]; then
    # ── DEGRADED MODE ──────────────────────────────────────────────────────
    # kubectl API is unreachable — expected on the LAST server node when the
    # other servers are already stopped (etcd quorum lost).
    # Skip all kubectl-dependent phases; run backup + stop only.
    log "${YELLOW}[WARN]${RESET}  kubectl API unreachable — etcd quorum likely lost (other servers already stopped)"
    log "${YELLOW}[WARN]${RESET}  Skipping: health check, maintenance, cordon, drain, leader wait"
    log "${YELLOW}[WARN]${RESET}  Running: backup (if server) + rke2 stop"
    echo ""
    phase_leader_info
    phase_backup
    phase_stop_rke2
  else
    # ── NORMAL MODE ────────────────────────────────────────────────────────
    # Idempotency: if already stopped, exit cleanly
    local current_phase
    current_phase=$(kubectl get node "${MY_NODE}" \
      -o jsonpath='{.metadata.annotations.prepatch\.uipath\.io/phase}' \
      2>/dev/null || true)

    if [[ "${current_phase}" == "stopped" ]]; then
      pass "Node ${MY_NODE} already has phase=stopped — nothing to do"
      exit 0
    fi

    info "Current phase annotation: ${current_phase:-<none>}"

    # Resolve uipathctl
    if ! resolve_uipathctl; then
      abort "uipathctl not found — set --installer-dir=<path> or ensure uipathctl is in PATH"
    fi

    phase_health_check
    phase_maintenance_mode
    phase_cordon
    phase_leader_info
    phase_drain
    phase_backup
    phase_signal_ready
    phase_leader_wait
    phase_stop_rke2
  fi

  # Final banner
  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  if [[ "${IS_LEADER}" == "true" ]]; then
    echo -e "${GREEN}${BOLD}  ★ THIS WAS THE ETCD LEADER — REBOOT THIS NODE FIRST after OS patch${RESET}"
  else
    echo -e "${GREEN}${BOLD}  PRE-PATCH COMPLETE: $(hostname -s)${RESET}"
  fi
  echo -e "${BOLD}  State log: ${STATE_LOG}${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"
}

main "$@"
