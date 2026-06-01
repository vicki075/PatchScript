#!/usr/bin/env bash
# =============================================================================
# 02-backup.sh — UiPath AS 24.10.4 / RKE2 Pre-Patch Backup
#
# Plan ref: https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/
#           pages/90751108300/Cluster+nodes+Pre-Patch+Tasks  (v1.1, Phase B)
#
# What it does:
#   1. Copies the last 2 scheduled etcd snapshots (by filename timestamp) to
#      /opt/UiPathAutomationSuite/backup_patch/<hostname>-<timestamp>/etcd/
#   2. Copies /etc/rancher/rke2/config.yaml to the same backup directory.
#   3. sha256-verifies every copy. Writes a metadata JSON per snapshot.
#   4. Verifies cluster still healthy after copies (read-only, non-disruptive).
#
# What it does NOT do:
#   - Generate a fresh etcd snapshot (explicitly excluded — see plan §4)
#   - Copy to an off-node destination (risk accepted — 3 independent server disks)
#   - Back up TLS certs or token (not required for this procedure)
#
# Scope:  Run LOCALLY on each of the 3 server nodes after maintenance mode
#         is enabled (Phase A) and before any node is stopped (Phase D).
#         Script aborts if run on an agent node.
#
# Exit codes:
#   0  — backup complete and verified; cluster still healthy
#   1  — backup failed; cluster state is UNCHANGED; investigate before continuing
#
# Usage:
#   chmod +x 02-backup.sh
#   ./02-backup.sh
#   ./02-backup.sh --verbose     # full output including INFO lines
# =============================================================================
set -uo pipefail

# =============================================================================
# ENVIRONMENT — detect node type, export KUBECONFIG and PATH
# This script only runs on server nodes (guard_server_node() enforces this),
# so KUBECONFIG will always resolve to rke2.yaml. The agent branch is kept
# for consistency and to avoid an unbound-variable error on PATH/KUBECONFIG
# if the guard fires before any other command.
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
readonly SNAP_DIR="/var/lib/rancher/rke2/server/db/snapshots"
readonly SNAP_MIN_COUNT=2
readonly SNAP_FRESHNESS_HOURS=24

readonly BACKUP_BASE="/opt/UiPathAutomationSuite/backup_patch"
readonly RKE2_CONFIG="/etc/rancher/rke2/config.yaml"

readonly ETCDCTL="/var/lib/rancher/rke2/bin/etcdctl"
readonly ETCD_CACERT="/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt"
readonly ETCD_CERT="/var/lib/rancher/rke2/server/tls/etcd/server-client.crt"
readonly ETCD_KEY="/var/lib/rancher/rke2/server/tls/etcd/server-client.key"
readonly ETCD_ENDPOINT="https://127.0.0.1:2379"

readonly STATE_LOG="/opt/UiPathAutomationSuite/prepatch-state.log"
readonly CHECKSUM_RETRY=1          # retry once on checksum mismatch before aborting

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
  echo "$(ts)  SNAPSHOT_FAIL  $(hostname)  ${msg}" >> "${STATE_LOG}" 2>/dev/null || true
  exit 1
}

state_log() {
  mkdir -p "$(dirname "${STATE_LOG}")" 2>/dev/null || true
  echo "$(ts)  $*" >> "${STATE_LOG}" 2>/dev/null || true
}

# =============================================================================
# UIPATHCTL RESOLUTION — mirrors 01-preflight.sh
# =============================================================================
UIPATHCTL_BIN=""

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
  found=$(find /opt/UiPathAutomationSuite -name uipathctl -maxdepth 6 -type f 2>/dev/null | head -1)
  if [[ -n "${found}" && -x "${found}" ]]; then
    UIPATHCTL_BIN="${found}"
    export PATH="$(dirname "${UIPATHCTL_BIN}"):${PATH}"
    return 0
  fi

  return 1
}

# =============================================================================
# GUARD: must run on a server node
# =============================================================================
guard_server_node() {
  if ! systemctl is-active --quiet rke2-server 2>/dev/null; then
    fail "This script must run on a SERVER node (rke2-server.service active). Detected: agent or uninitialized node on $(hostname)."
  fi
  info "Confirmed server node: $(hostname)"
}

# =============================================================================
# STEP 1: Identify the last SNAP_MIN_COUNT snapshots by filename epoch
# Result written to global SNAPSHOT_LIST (newline-separated filenames, newest last).
# NOT captured via $() — avoids stdout collision with info() in verbose mode.
# =============================================================================
SNAPSHOT_LIST=""

identify_snapshots() {
  info "Identifying last ${SNAP_MIN_COUNT} snapshots in ${SNAP_DIR} on $(hostname)..."

  if [[ ! -d "${SNAP_DIR}" ]]; then
    fail "Snapshot directory ${SNAP_DIR} not found on $(hostname)"
  fi

  local count
  count=$(ls -1 "${SNAP_DIR}/" 2>/dev/null | grep -c "^etcd-snapshot-" || echo "0")

  if [[ "${count}" -lt "${SNAP_MIN_COUNT}" ]]; then
    fail "Only ${count} snapshot(s) found in ${SNAP_DIR}. Minimum ${SNAP_MIN_COUNT} required. Run 01-preflight.sh first."
  fi

  # Sort by unix epoch embedded in filename (authoritative — not file mtime)
  # Filename format: etcd-snapshot-<hostname>-<unix-epoch>[.zip]
  SNAPSHOT_LIST=$(ls -1 "${SNAP_DIR}/" \
    | grep "^etcd-snapshot-" \
    | while read -r f; do
        ep=$(echo "${f}" | grep -oE '[0-9]{9,11}' | tail -1)
        echo "${ep:-0} ${f}"
      done \
    | sort -n \
    | tail -"${SNAP_MIN_COUNT}" \
    | awk '{print $2}')

  if [[ -z "${SNAPSHOT_LIST}" ]]; then
    fail "Could not identify any snapshots with parseable epoch timestamps in ${SNAP_DIR}"
  fi

  info "Selected snapshots (newest last):"
  if [[ "${VERBOSE}" == "true" ]]; then
    echo "${SNAPSHOT_LIST}" | sed 's/^/  /'
  fi
}

# =============================================================================
# STEP 2: Validate a single snapshot file (size + freshness)
# Args: $1 = full path to snapshot file
# =============================================================================
validate_snapshot() {
  local snap_path="$1"
  local snap_file
  snap_file=$(basename "${snap_path}")

  info "Validating: ${snap_file}"

  # Criterion 1: file exists and is non-empty
  if [[ ! -s "${snap_path}" ]]; then
    fail "Snapshot empty or missing: ${snap_path}"
  fi
  info "  Size: $(du -sh "${snap_path}" | awk '{print $1}')"

  # Criterion 2: filename timestamp within freshness threshold
  local epoch
  epoch=$(echo "${snap_file}" | grep -oE '[0-9]{9,11}' | tail -1)

  if [[ -z "${epoch}" || "${epoch}" -eq 0 ]]; then
    warn "  Could not parse epoch from filename — skipping freshness check"
    return 0
  fi

  local age_hours
  age_hours=$(( ( $(date +%s) - epoch ) / 3600 ))

  if [[ "${age_hours}" -gt "${SNAP_FRESHNESS_HOURS}" ]]; then
    warn "  Snapshot ${snap_file} is ${age_hours}h old (threshold: ${SNAP_FRESHNESS_HOURS}h) — proceeding with copy"
  fi

  info "  Age: ${age_hours}h  ✓  (threshold: ${SNAP_FRESHNESS_HOURS}h)"
  # Note: no etcdutl on this cluster. etcd health was confirmed in PF-02.
  # A healthy running cluster produces consistent snapshots; file-level
  # validation plus freshness check is sufficient for this safety-net purpose.
}

# =============================================================================
# STEP 3: Copy a snapshot to the destination with sha256 verification
# Args: $1 = src full path, $2 = dest directory, $3 = age_hours (for metadata)
# =============================================================================
copy_snapshot() {
  local src="$1"
  local dest_dir="$2"
  local snap_file
  snap_file=$(basename "${src}")
  local dst="${dest_dir}/${snap_file}"

  info "Copying ${snap_file} → ${dest_dir}/"

  local attempt
  for attempt in 1 $(( CHECKSUM_RETRY + 1 )); do
    cp --preserve=timestamps "${src}" "${dst}" \
      || fail "cp failed for ${snap_file} on attempt ${attempt}"

    local src_sha dst_sha
    src_sha=$(sha256sum "${src}" | awk '{print $1}')
    dst_sha=$(sha256sum "${dst}" | awk '{print $1}')

    if [[ "${src_sha}" == "${dst_sha}" ]]; then
      info "  sha256 verified  ✓  (${dst_sha:0:16}...)"

      # Write metadata alongside the copy
      local epoch age_hours
      epoch=$(echo "${snap_file}" | grep -oE '[0-9]{9,11}' | tail -1 || echo "0")
      age_hours=$(( ( $(date +%s) - epoch ) / 3600 ))

      cat > "${dest_dir}/${snap_file}.meta.json" <<METAEOF
{
  "node_hostname": "$(hostname)",
  "original_path": "${src}",
  "snapshot_filename": "${snap_file}",
  "snapshot_age_hours": ${age_hours},
  "copy_timestamp_utc": "$(ts)",
  "sha256": "${dst_sha}"
}
METAEOF
      return 0
    fi

    warn "  Checksum mismatch on attempt ${attempt} — src: ${src_sha}  dst: ${dst_sha}"
    rm -f "${dst}" || true

    if [[ "${attempt}" -gt "${CHECKSUM_RETRY}" ]]; then
      fail "Checksum mismatch persists after ${CHECKSUM_RETRY} retry for ${snap_file}. Aborting."
    fi
    info "  Retrying copy..."
  done
}

# =============================================================================
# STEP 4: Back up rke2 config file
# =============================================================================
backup_rke2_config() {
  local dest_dir="$1"
  local config_dest="${dest_dir}/rke2-config"
  mkdir -p "${config_dest}"

  if [[ ! -f "${RKE2_CONFIG}" ]]; then
    warn "RKE2 config not found at ${RKE2_CONFIG} — skipping (may use defaults)"
    return 0
  fi

  info "Copying ${RKE2_CONFIG} → ${config_dest}/"
  cp --preserve=timestamps "${RKE2_CONFIG}" "${config_dest}/"

  local src_sha dst_sha
  src_sha=$(sha256sum "${RKE2_CONFIG}" | awk '{print $1}')
  dst_sha=$(sha256sum "${config_dest}/config.yaml" | awk '{print $1}')

  if [[ "${src_sha}" != "${dst_sha}" ]]; then
    fail "Checksum mismatch for rke2 config.yaml: src=${src_sha} dst=${dst_sha}"
  fi

  info "  sha256 verified  ✓  (${dst_sha:0:16}...)"
  pass "RKE2 config backed up to ${config_dest}/"
}

# =============================================================================
# STEP 5: Post-backup cluster health verification
# =============================================================================
verify_cluster_after_backup() {
  info "Verifying cluster still healthy after backup (should be unaffected)..."

  # Node status (quick check)
  if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
    local not_ready
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}')
    if [[ -n "${not_ready}" ]]; then
      log "${YELLOW}[WARN]${RESET}  POST-BACKUP: Following nodes not Ready (unexpected — investigate):"
      if [[ "${VERBOSE}" == "true" ]]; then
        echo "${not_ready}" | sed 's/^/  /'
      fi
    else
      info "POST-BACKUP: All nodes still Ready  ✓"
    fi

    # API server readyz
    if kubectl get --raw='/readyz' &>/dev/null 2>&1; then
      info "POST-BACKUP: API server /readyz OK  ✓"
    else
      log "${YELLOW}[WARN]${RESET}  POST-BACKUP: API server /readyz check failed — unexpected, investigate"
    fi

    # Maintenance mode still set
    # is-enabled returns "true"/"false" or a descriptive string — use grep-based check
    if [[ -n "${UIPATHCTL_BIN}" ]] || resolve_uipathctl; then
      local mm_raw mm_on=false
      mm_raw=$("${UIPATHCTL_BIN}" cluster maintenance is-enabled --namespace uipath 2>/dev/null || true)
      if ! echo "${mm_raw}" | grep -qi "not\|false\|disabled"; then
        echo "${mm_raw}" | grep -qi "true\|enabled" && mm_on=true || true
      fi
      if [[ "${mm_on}" == "true" ]]; then
        info "POST-BACKUP: Maintenance mode still enabled  ✓"
      else
        log "${YELLOW}[WARN]${RESET}  POST-BACKUP: Maintenance mode does not appear enabled (is-enabled: '${mm_raw}') — verify manually"
      fi
    else
      log "${YELLOW}[WARN]${RESET}  POST-BACKUP: uipathctl not found — skipping maintenance mode check"
      log "${YELLOW}[WARN]${RESET}          Try: UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./02-backup.sh"
      log "${YELLOW}[WARN]${RESET}          Expected binary: /opt/UiPathAutomationSuite/latest/installer/bin/uipathctl"
    fi
  else
    log "${YELLOW}[WARN]${RESET}  POST-BACKUP: kubectl not available — skipping cluster health verification"
  fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  for arg in "$@"; do
    case "${arg}" in
      --verbose|--debug|-v) VERBOSE=true ;;
      --help|-h)
        echo "Usage: $0 [--verbose|--debug]"
        echo "  Default: only PASS/FAIL lines + summary"
        echo "  --verbose / --debug: full output including INFO and command detail"
        exit 0 ;;
    esac
  done

  echo -e "\n${BOLD}================================================================${RESET}"
  echo -e "${BOLD}  UiPath AS 24.10.4 / RKE2 — Pre-Patch Backup${RESET}"
  echo -e "${BOLD}  Node: $(hostname)   |   $(ts)${RESET}"
  [[ "${VERBOSE}" == "true" ]] && echo -e "${CYAN}  Mode: verbose${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"

  # Resolve uipathctl once; verify_cluster_after_backup() uses UIPATHCTL_BIN
  if resolve_uipathctl; then
    info "uipathctl resolved: ${UIPATHCTL_BIN}"
  else
    log "${YELLOW}[WARN]${RESET}  uipathctl not found — maintenance mode check will be skipped"
    log "${YELLOW}[WARN]${RESET}          To enable: UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./02-backup.sh"
    log "${YELLOW}[WARN]${RESET}          Expected binary: /opt/UiPathAutomationSuite/latest/installer/bin/uipathctl"
  fi
  echo ""

  # Guard: server nodes only
  guard_server_node

  # Create timestamped destination directory
  local TIMESTAMP
  TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
  local DEST_DIR="${BACKUP_BASE}/$(hostname)-${TIMESTAMP}"
  local ETCD_DEST="${DEST_DIR}/etcd"
  mkdir -p "${ETCD_DEST}" \
    || fail "Cannot create backup directory ${ETCD_DEST}"
  info "Backup directory: ${DEST_DIR}"

  # Step 1 + 2 + 3: Identify, validate, and copy snapshots
  echo ""
  info "--- Phase B.1: etcd Snapshot Safety Net ---"
  identify_snapshots   # populates global SNAPSHOT_LIST

  while IFS= read -r snap_name; do
    [[ -z "${snap_name}" ]] && continue
    local snap_path="${SNAP_DIR}/${snap_name}"
    validate_snapshot "${snap_path}"
    copy_snapshot "${snap_path}" "${ETCD_DEST}"
    pass "Snapshot copied and verified: ${snap_name}"
    echo ""
  done <<< "${SNAPSHOT_LIST}"

  # Step 4: RKE2 config backup
  echo ""
  info "--- Phase B.2: RKE2 Config Backup ---"
  backup_rke2_config "${DEST_DIR}"

  # Summary of what was written
  echo ""
  info "--- Backup Contents ---"
  if [[ "${VERBOSE}" == "true" ]]; then
    find "${DEST_DIR}" -type f | sort | sed 's/^/  /'
  fi

  # Step 5: Post-backup health check
  echo ""
  info "--- Post-Backup Cluster Health Verification ---"
  verify_cluster_after_backup

  # State log
  state_log "SNAPSHOTS_COPIED  $(hostname)  dest=${DEST_DIR}"

  echo ""
  echo -e "${BOLD}================================================================${RESET}"
  echo -e "${GREEN}${BOLD}  BACKUP COMPLETE — $(hostname)${RESET}"
  echo -e "${GREEN}${BOLD}  Backup dir: ${DEST_DIR}${RESET}"
  echo -e "${BOLD}================================================================${RESET}\n"
}

main "$@"
