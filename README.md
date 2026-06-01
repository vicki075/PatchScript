# UiPath Automation Suite — OS Pre-Patch Scripts

**Product:** UiPath Automation Suite 24.10.4 (offline / air-gapped)  
**Cluster:** RKE2 — any odd number of server (control-plane) nodes + any number of agent nodes  
**Plan doc:** [Cluster nodes Pre-Patch Tasks (Confluence v1.1)](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90751108300/Cluster+nodes+Pre-Patch+Tasks)

---

## What these scripts do

| Script | Purpose | Run on |
|---|---|---|
| `01-preflight.sh` | Validates cluster is healthy before anything is touched | Primary server (full) + every node (local checks) |
| `02-backup.sh` | Copies last 2 etcd snapshots + RKE2 config to a local backup dir | Each server node |
| `03-prepatch.sh` | Enables maintenance mode, cordons nodes, then shuts down each node cleanly | Mode-dependent — see below |

**What they do NOT do:** OS patch, reboot, upgrade RKE2 binaries, bring the cluster back up.

---

## Output verbosity

All three scripts default to **quiet mode** — only `[PASS]`, `[WARN]`, `[FAIL]`, and summary lines are printed.
Add `--verbose` (or `--debug`) to see full detail: `[INFO]` lines, etcd tables, kubectl output, command results.

```bash
./01-preflight.sh --verbose
./02-backup.sh --verbose
./03-prepatch.sh --global --verbose
```

### Preflight outcome levels

| Level | Colour | Exit code | Meaning |
|---|---|---|---|
| `[PASS]` | Green | 0 | Check passed |
| `[WARN]` | Yellow | 0 | Advisory — review before patching, but does not block |
| `[FAIL]` | Red | 1 | Hard blocker — must resolve before proceeding |

**FAIL checks:** nodes not Ready, etcd unhealthy/no leader/alarms, API server down, critical disk space (`/var/lib/rancher` <5 GB, `/var/lib/kubelet` <2 GB), `uipathctl` binary not found, maintenance mode already set.

**WARN checks:** pods in CrashLoopBackOff or stuck Terminating (pre-existing app issues), `/var` or `/opt` disk low, RKE2 package pin absent, `uipathctl` health check failures, etcd snapshots stale or missing.

---

## Prerequisites

### Environment setup — automatic (no manual export needed)

All three scripts auto-detect node type and self-export `KUBECONFIG` and `PATH` at startup:

| Node type | Detection | `KUBECONFIG` set to |
|---|---|---|
| Server | `/etc/rancher/rke2/rke2.yaml` exists | `/etc/rancher/rke2/rke2.yaml` |
| Agent | above file absent | `/var/lib/rancher/rke2/agent/kubelet.kubeconfig` |

Both node types: `PATH` extended with `/usr/local/bin:/var/lib/rancher/rke2/bin`

**You do not need to export `KUBECONFIG` before running any script.**

### uipathctl auto-discovery

Scripts locate `uipathctl` automatically (in priority order):

1. `PATH`
2. `UIPATH_INSTALLER_DIR` env var — `<dir>/bin/uipathctl`
3. `/opt/UiPathAutomationSuite/latest/installer/bin/uipathctl`
4. `find /opt/UiPathAutomationSuite -name uipathctl` (depth-limited)

If auto-discovery fails, set the env var explicitly:

```bash
UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./01-preflight.sh
```

### etcdctl auto-discovery

Scripts locate `etcdctl` automatically:

1. Host binary: `/var/lib/rancher/rke2/bin/etcdctl`
2. Container exec via `crictl` — for clusters where `etcdctl` lives only inside the etcd container image (distroless builds)

No configuration required — detection is automatic at runtime.

### On every node

- `bash` 4+ (standard on RHEL / Rocky Linux)
- `python3` 3.6+ (used for JSON parsing — standard on RHEL 8+)
- RKE2 package pin must be present (verified by `01-preflight.sh` PF-06):
  ```
  /etc/yum.conf or /etc/yum.repos.d/*.repo must contain:  exclude=rke2-*
  ```
- Minimum free disk space: `/var/lib/rancher` ≥5 GB · `/var/lib/kubelet` ≥2 GB · `/var` ≥3 GB · `/opt` ≥2 GB

### Make scripts executable (one-time)

```bash
chmod +x 01-preflight.sh 02-backup.sh 03-prepatch.sh
```

### Cluster topology detection

Node counts are **not hardcoded**. Scripts discover the topology at runtime:
- **Server nodes** = nodes labelled `node-role.kubernetes.io/control-plane=true`
- **Agent nodes** = all remaining nodes
- Server count **must be odd** (etcd quorum requirement: 1, 3, 5, 7 …)

Works for any cluster shape: `3+0`, `3+1`, `3+3`, `5+2`, `7+0`, etc.

---

## Execution order

```
┌─────────────────────────────────────────────────────────────────┐
│  STEP 1  Pre-flight checks                                      │
│  STEP 2  Enable maintenance mode + cordon all nodes             │
│  STEP 3  Backups (etcd snapshots + rke2 config)                 │
│  STEP 4  Stop agent nodes  (one at a time, if any agents exist) │
│  STEP 5  Stop server nodes (non-leader first, leader last)      │
│                                                                 │
│  → OS patch + reboot each node ←                               │
│                                                                 │
│  STEP 6  Start leader server FIRST, then other servers, agents  │
└─────────────────────────────────────────────────────────────────┘
```

### Why leader last / leader first?

etcd requires `(n/2)+1` nodes for quorum. Stopping non-leaders first keeps the leader (and the Kubernetes API) stable throughout the drain sequence. Stopping the leader first triggers an unnecessary leader election while drains are still in progress.

The same logic applies in reverse on restart: starting the leader first re-establishes etcd quorum before other nodes try to rejoin.

---

## Step-by-step instructions

### STEP 1 — Pre-flight checks

Run from the **primary server node**. All 9 checks run regardless of individual failures; a consolidated summary is printed at the end.

```bash
./01-preflight.sh
```

**Expected output (primary server, clean cluster):**
```
[PASS]  TOPOLOGY: 3 nodes — 3 server + 0 agent
[PASS]  PF-01: All 3 nodes Ready, none pre-cordoned
[PASS]  PF-02: etcd OK — 3 members, leader elected, no alarms, DB ~X GB
[PASS]  PF-03: API server /readyz clean
[PASS]  PF-04: No pods in CrashLoopBackOff / ImagePullBackOff / stuck Terminating
[PASS]  PF-05: Disk space OK on <hostname>
[PASS]  PF-06: RKE2 package pin (exclude=rke2-*) confirmed on <hostname>
[PASS]  PF-07: UiPath health check passed
[PASS]  PF-08: Maintenance mode not set; no concurrent uipathctl operation
[PASS]  PF-09: etcd snapshots OK on <hostname>

================================================================
  PRE-FLIGHT SUMMARY — <hostname>
================================================================
  RESULT: ALL CHECKS PASSED ✓
```

If only warnings are present (pre-existing app issues, advisory disk):
```
  RESULT: PASSED WITH N WARNING(S)
  Review warnings above before starting the patch window.
```

> **Stop here if any `[FAIL]` appears.** Exit code 1, failures written to  
> `/opt/UiPathAutomationSuite/prepatch-state.log`. Resolve all failures and re-run before proceeding.

Also run on every non-primary node for local checks (PF-05 disk, PF-06 package pin):
```bash
./01-preflight.sh          # on each remaining node
```

---

### STEP 2 — Enable maintenance mode and cordon all nodes

Run from the **primary server node** only (once).

```bash
./03-prepatch.sh --global
```

This does:
1. **Phase A** — `uipathctl cluster maintenance enable` (quiesces UiPath product workloads)
2. **Phase C** — Labels every node `nodejanitor/skip=true` then cordons it (prevents nodejanitor from auto-uncordoning during the patch window)
3. **Identifies the etcd leader** — prints hostname of the server that must be stopped **last** (and started **first** after patching)

**`--global` is idempotent.** If a previous run completed Phase A but failed during Phase C, re-running detects maintenance mode is already on, skips the enable step, and proceeds directly to Phase C.

**Expected output:**
```
[PASS]  Phase A: Maintenance mode enabled
[PASS]  Phase C: All 3 nodes cordoned and labelled nodejanitor/skip=true

--- etcd Leader Identification ---
[INFO]  Leader summary (IP → hostname):
  autosuiteb  (https://10.0.0.5:2379)  <<< LEADER — stop this server LAST
  autosuitea  (https://10.0.0.4:2379)
  autosuitec  (https://10.0.0.6:2379)
```

> **Record the leader hostname now** — you need it in Steps 5 and 6.

---

### STEP 3 — Backup etcd snapshots and RKE2 config

Run **locally on each server node** (in any order; all must complete before Step 4/5).

```bash
./02-backup.sh
```

What it backs up (per server node):
- Last 2 etcd snapshots → `/opt/UiPathAutomationSuite/backup_patch/<hostname>-<timestamp>/etcd/`
- `/etc/rancher/rke2/config.yaml` → `.../rke2-config/config.yaml`
- sha256 checksum + `.meta.json` per snapshot

**Expected output:**
```
[PASS]  Snapshot copied and verified: etcd-snapshot-<hostname>-<epoch>
[PASS]  Snapshot copied and verified: etcd-snapshot-<hostname>-<epoch>
[PASS]  RKE2 config backed up to .../rke2-config/

================================================================
  BACKUP COMPLETE — <hostname>
  Backup dir: /opt/UiPathAutomationSuite/backup_patch/<hostname>-<timestamp>
================================================================
```

> If backup fails, the script exits and the cluster remains **fully up**. Investigate before continuing.

---

### STEP 4 — Stop agent nodes (one at a time)

> **Skip this step if your cluster has no agent nodes** (e.g. 3+0 topology).

Run **locally on each agent node**. Sequential — wait for each to complete before starting the next.

```bash
./03-prepatch.sh --stop-agent
```

Sequence per node:
1. `systemctl stop node-drain.service` (10 min timeout)
2. `systemctl stop rke2-agent`
3. `rke2-killall.sh` (clears residual containerd/kubelet processes and unmounts pod mounts)
4. Verifies no residual processes remain

After each agent stops, verify from a server node (while API is still up):
```bash
kubectl get node <agent-hostname>
# Expected: NotReady,SchedulingDisabled
```

> A failure on any agent **aborts that run**. Do not proceed to the next agent or to Step 5 without human triage.

---

### STEP 5 — Stop server nodes (non-leader first, leader last)

Run **locally on each server node**. Sequential. The leader identified in Step 2 must be **stopped last**.

```bash
# Non-leader server(s) first (any order among non-leaders):
./03-prepatch.sh --stop-server

# Leader server — LAST (kubectl API will be gone after this):
./03-prepatch.sh --stop-server
```

Sequence per node:
1. Checks etcd quorum for remaining members (auto-skipped when only 1 member left)
2. `systemctl stop node-drain.service`
3. `systemctl stop rke2-server`
4. `rke2-killall.sh`
5. Verifies no residual processes remain
6. On the **final/leader server**: writes `PREPATCH_COMPLETE_<timestamp>` marker to `/opt/UiPathAutomationSuite/` with restart order

After the leader stops, verify locally:
```bash
ps aux | grep -E 'containerd|kubelet|rke2' | grep -v grep
# Expected: no output

cat /opt/UiPathAutomationSuite/PREPATCH_COMPLETE_*
# Shows: restart order, leader hostname, post-patch checklist
```

---

### Cluster is now ready for OS patch + reboot

All nodes are powered on, OS running, all RKE2 processes stopped. Apply OS patches and reboot each node.

---

### STEP 6 — Restart cluster (reverse stop order)

**Leader server first** — this re-establishes etcd quorum before other nodes rejoin.

```bash
# On the leader server (stopped last in Step 5):
systemctl start rke2-server
# Wait until: kubectl get node <leader-hostname>  →  Ready

# Then each remaining server (one at a time, wait for Ready each time):
systemctl start rke2-server

# Then each agent node (if any):
systemctl start rke2-agent
```

The `PREPATCH_COMPLETE_*` marker file records the leader hostname. If in doubt:
```bash
cat /opt/UiPathAutomationSuite/PREPATCH_COMPLETE_*
```

---

## Backup location

| Node | Path |
|---|---|
| Each server | `/opt/UiPathAutomationSuite/backup_patch/<hostname>-<YYYYMMDD-HHMMSS>/` |

```
<hostname>-<timestamp>/
├── etcd/
│   ├── etcd-snapshot-<hostname>-<epoch>
│   ├── etcd-snapshot-<hostname>-<epoch>.meta.json
│   ├── etcd-snapshot-<hostname>-<epoch-2>
│   └── etcd-snapshot-<hostname>-<epoch-2>.meta.json
└── rke2-config/
    └── config.yaml
```

**Purpose:** safety net only. If the cluster returns in a bad state after patching and new snapshots overwrite the pre-patch ones, these copies ensure at least two pre-patch-era snapshots remain. Full restore procedure is a separate document.

---

## State log

All phases write timestamped entries to `/opt/UiPathAutomationSuite/prepatch-state.log`:

```
2026-06-01T...  PREFLIGHT_PASS                <hostname>
2026-06-01T...  PREFLIGHT_PASS_WITH_WARNINGS  <hostname>  warned=PF-07
2026-06-01T...  MAINTENANCE_ENABLED           <hostname>
2026-06-01T...  MAINTENANCE_ALREADY_ENABLED   <hostname>  (skip re-enable)
2026-06-01T...  ALL_NODES_CORDONED            <hostname>  count=3  nodejanitor_skip=true
2026-06-01T...  SNAPSHOTS_COPIED              <hostname>  dest=/opt/...
2026-06-01T...  AGENT_STOPPED                 <hostname>
2026-06-01T...  SERVER_STOPPED                <hostname>
2026-06-01T...  PREPATCH_COMPLETE             <leader-hostname>  leader=<leader-hostname>
```

---

## Abort behavior

**No automatic rollback.** If any script exits with code 1, the cluster is left in whatever state it reached. Do not continue without triage.

| Where it failed | Cluster state | What to check |
|---|---|---|
| Step 1 (preflight) | Unchanged — fully serving | Fix the failing check, re-run `01-preflight.sh` |
| Step 2 (maintenance/cordon) | Partial — may be in maintenance mode | Re-run `./03-prepatch.sh --global` — it is idempotent; if maintenance mode is already on it skips Phase A and retries Phase C |
| Step 3 (backup) | Unchanged — fully up, maintenance mode active | Check disk space; re-run `02-backup.sh` (idempotent — creates a new timestamped dir) |
| Step 4 (agent stop) | Partial — some agents stopped | Check state log for `AGENT_STOPPED` entries; remaining agents still running |
| Step 5 (server stop) | Partial — some servers stopped | Check state log for `SERVER_STOPPED` entries; etcd may have lost quorum if 2+ servers are down |

---

## Post-patch checklist (after cluster restart)

Run from the primary server after all nodes are back up.

```bash
# 1. Verify all nodes have rejoined
kubectl get nodes

# 2. Verify etcd health
#    (if etcdctl is not on the host, use: crictl exec -i <etcd-container-id> etcdctl ...)
etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  endpoint health --cluster

# 3. Disable UiPath maintenance mode
uipathctl cluster maintenance disable --namespace uipath

# 4. Remove nodejanitor/skip label BEFORE uncordoning
#    (prevents nodejanitor from re-cordoning nodes immediately after uncordon)
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl label node "${node}" nodejanitor/skip-
done

# 5. Uncordon all nodes
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl uncordon "${node}"
done

# 6. Run preflight again to confirm baseline is restored
./01-preflight.sh

# 7. Run product health check
uipathctl health check --namespace uipath --timeout 10m
```

---

## Quick reference — command summary

```bash
# Full pre-flight (primary server)
./01-preflight.sh

# Full pre-flight with verbose output
./01-preflight.sh --verbose

# Enable maintenance mode + cordon all nodes (primary server; idempotent)
./03-prepatch.sh --global

# Backup snapshots + config (each server node, locally)
./02-backup.sh

# Stop each agent (locally on each agent, sequential — skip if no agents)
./03-prepatch.sh --stop-agent

# Identify etcd leader at any time (any server node)
./03-prepatch.sh --identify-leader

# Stop each server (locally on each server, non-leader first, leader last)
./03-prepatch.sh --stop-server

# Override uipathctl path if not auto-discovered
UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./01-preflight.sh
```

---

## Files

```
AutomationSuite_scripts/
├── README.md              ← this file
├── 01-preflight.sh        ← pre-flight health gate (9 checks, FAIL/WARN/PASS)
├── 02-backup.sh           ← etcd snapshot + rke2 config backup (server nodes)
└── 03-prepatch.sh         ← maintenance mode, cordon, and per-node stop
```

---

*Plan document: [Confluence v1.1](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90751108300/Cluster+nodes+Pre-Patch+Tasks)*
