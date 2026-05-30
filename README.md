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

## Prerequisites

### Environment setup — automatic (no manual export needed)

All three scripts auto-detect node type and self-export `KUBECONFIG` and `PATH` at startup:

| Node type | Detection | `KUBECONFIG` set to |
|---|---|---|
| Server | `/etc/rancher/rke2/rke2.yaml` exists | `/etc/rancher/rke2/rke2.yaml` |
| Agent | above file absent | `/var/lib/rancher/rke2/agent/kubelet.kubeconfig` |

Both node types: `PATH` extended with `/usr/local/bin:/var/lib/rancher/rke2/bin`

**You do not need to export `KUBECONFIG` before running any script.** Just ensure the file is present (it is created automatically by RKE2 on first start).

### On the primary server node

```bash
# Confirm kubectl and uipathctl are accessible
kubectl get nodes
uipathctl health check --namespace uipath --timeout 2m
```

```bash
# Make scripts executable (one-time)
chmod +x /path/to/scripts/01-preflight.sh \
         /path/to/scripts/02-backup.sh \
         /path/to/scripts/03-prepatch.sh
```

### On every node

- `bash` 4+ (standard on RHEL / Rocky Linux)
- `python3` (used for JSON parsing in preflight — standard on RHEL 8+)
- RKE2 package pin must be present (verified by `01-preflight.sh` PF-06):
  ```
  /etc/yum.conf or /etc/yum.repos.d/*.repo must contain:  exclude=rke2-*
  ```
- Minimum free disk space: `/var/lib/rancher` ≥5 GB · `/var/lib/kubelet` ≥2 GB · `/var` ≥3 GB · `/opt` ≥2 GB

### Cluster topology detection

Node counts are **not hardcoded**. Scripts discover the topology at runtime:
- **Server nodes** = nodes labelled `node-role.kubernetes.io/control-plane=true`
- **Agent nodes** = all remaining nodes
- Server count **must be odd** (etcd quorum requirement: 1, 3, 5, 7 …)

This means the same scripts work for any cluster shape: `3+1`, `3+3`, `5+2`, `7+0`, etc.

---

## Execution order

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1  Pre-flight checks                                  │
│  STEP 2  Enable maintenance mode + cordon all nodes         │
│  STEP 3  Backups (etcd snapshots + rke2 config)             │
│  STEP 4  Stop agent nodes  (one at a time)                  │
│  STEP 5  Stop server nodes (non-leader first, leader last)  │
└─────────────────────────────────────────────────────────────┘
```

---

## Step-by-step instructions

### STEP 1 — Pre-flight checks

Run from the **primary server node**. Checks PF-01 through PF-09.  
Also run on **every other node** for local disk and package-pin checks (PF-05, PF-06).

```bash
# --- Primary server node (full check: all 9 PF checks) ---
./01-preflight.sh
```

```bash
# --- Every other node (local checks only: PF-05, PF-06) ---
# (orchestrator invokes this on each node)
./01-preflight.sh
```

**Expected output (primary server):**
```
[PASS]  TOPOLOGY: 6 nodes — 3 server + 3 agent
[PASS]  PF-01: All 6 nodes Ready, none pre-cordoned
[PASS]  PF-02: etcd OK — 3 members, leader elected, no alarms, DB ~X GB
[PASS]  PF-03: API server /readyz clean
[PASS]  PF-04: No pods in CrashLoopBackOff / ImagePullBackOff / stuck Terminating
[PASS]  PF-05: Disk space OK on <hostname>
[PASS]  PF-06: RKE2 package pin (exclude=rke2-*) confirmed on <hostname>
[PASS]  PF-07: UiPath health check passed
[PASS]  PF-08: Maintenance mode not set; no concurrent uipathctl operation
[PASS]  PF-09: etcd snapshots OK on <hostname>
```

> **Stop here if any check fails.** The script exits with code 1 and writes the failure to  
> `/opt/UiPathAutomationSuite/prepatch-state.log`. Do not proceed until resolved.

---

### STEP 2 — Enable maintenance mode and cordon all nodes

Run from the **primary server node** only (once).

```bash
./03-prepatch.sh --global
```

This does:
1. **Phase A** — `uipathctl cluster maintenance enable` (quiesces UiPath product workloads)
2. **Phase C** — Labels every node `nodejanitor/skip=true` then cordons it (prevents nodejanitor from auto-uncordoning during the patch window)
3. **Identifies the etcd leader** — prints which server node must be stopped **last**. Note this hostname before proceeding to Step 5.

**Expected output (abridged):**
```
[PASS]  Phase A: Maintenance mode enabled
[INFO]  Cordoned: node1  node2  node3  node4  node5  node6
[PASS]  Phase C: All 6 nodes cordoned and labelled nodejanitor/skip=true

--- etcd Leader Identification ---
  ENDPOINT          IS LEADER
  192.168.x.x:2379  true      <<< LEADER — stop this server LAST
  192.168.x.y:2379  false
  192.168.x.z:2379  false
```

> **Record the leader node hostname now** — you need it in Step 5.

---

### STEP 3 — Backup etcd snapshots and RKE2 config

Run **locally on each of the 3 server nodes** (in any order; all must complete before Step 4).

```bash
# Run on server-1, server-2, server-3 (each separately):
./02-backup.sh
```

What it backs up (per server node):
- Last 2 etcd snapshots → `/opt/UiPathAutomationSuite/backup_patch/<hostname>-<timestamp>/etcd/`
- `/etc/rancher/rke2/config.yaml` → `.../rke2-config/config.yaml`
- sha256 checksums + `.meta.json` per snapshot

**Expected output (abridged):**
```
[PASS]  Snapshot copied and verified: etcd-snapshot-<hostname>-<epoch>
[PASS]  Snapshot copied and verified: etcd-snapshot-<hostname>-<epoch>
[PASS]  RKE2 config backed up
[PASS]  BACKUP COMPLETE — <hostname>
         Backup dir: /opt/UiPathAutomationSuite/backup_patch/<hostname>-<timestamp>
```

> If backup fails, the script exits and cluster remains **fully up**. Investigate before continuing.

---

### STEP 4 — Stop agent nodes (one at a time)

Run **locally on each agent node**. The orchestrator must invoke these **sequentially** — wait for each to complete before starting the next.

```bash
# Run on agent-1, then agent-2, then agent-3 (sequential — not parallel):
./03-prepatch.sh --stop-agent
```

Sequence per node:
1. `systemctl stop node-drain.service` (10 min timeout)
2. `systemctl stop rke2-agent`
3. `rke2-killall.sh` (clears residual containerd/kubelet processes)
4. Verifies no residual processes remain

After each agent stops, verify from the primary server (while API is still up):
```bash
kubectl get node <agent-hostname>
# Expected: NotReady,SchedulingDisabled
```

> A failure on any agent **aborts the run**. Do not proceed to the next agent or to Step 5 without human triage.

---

### STEP 5 — Stop server nodes (non-leader first, leader last)

Run **locally on each server node**. Sequential. The server identified as leader in Step 2 must be **stopped last**.

```bash
# Non-leader server 1:
./03-prepatch.sh --stop-server

# Non-leader server 2:
./03-prepatch.sh --stop-server

# Leader server (LAST — kubectl API will be gone after this):
./03-prepatch.sh --stop-server
```

Sequence per node:
1. Checks etcd quorum for remaining members (auto-skipped on the final/leader server)
2. `systemctl stop node-drain.service`
3. `systemctl stop rke2-server`
4. `rke2-killall.sh`
5. Verifies no residual processes remain
6. On the **final server** (leader): writes `PREPATCH_COMPLETE_<timestamp>` marker to `/opt/UiPathAutomationSuite/`

> After the leader stops, the kubectl API is gone — this is expected. Verify locally on the last server:
> ```bash
> ps aux | grep -E 'containerd|kubelet|rke2' | grep -v grep
> # Expected: no output
> cat /opt/UiPathAutomationSuite/PREPATCH_COMPLETE_*
> ```

---

### Cluster is now ready for OS patch + reboot

All nodes are powered on, OS running, but all RKE2 processes stopped. The OS patch tool can now apply patches and reboot each node.

---

## Backup location

| Node | Path |
|---|---|
| Each server | `/opt/UiPathAutomationSuite/backup_patch/<hostname>-<YYYYMMDD-HHMMSS>/` |

Contents:
```
<hostname>-<timestamp>/
├── etcd/
│   ├── etcd-snapshot-<hostname>-<epoch>          # snapshot copy
│   ├── etcd-snapshot-<hostname>-<epoch>.meta.json
│   ├── etcd-snapshot-<hostname>-<epoch-2>
│   └── etcd-snapshot-<hostname>-<epoch-2>.meta.json
└── rke2-config/
    └── config.yaml
```

**Purpose of the etcd snapshot copies:** safety net only. If the cluster comes back in a bad state after patching, creates new snapshots that overwrite the pre-patch ones, and then cannot self-recover — these copies ensure at least two pre-patch-era snapshots are still available. Full backup & restore procedure is a separate document.

---

## State log

All phases write timestamped entries to `/opt/UiPathAutomationSuite/prepatch-state.log` on each node:

```
2026-05-28T...  PREFLIGHT_PASS      <hostname>
2026-05-28T...  MAINTENANCE_ENABLED <hostname>
2026-05-28T...  ALL_NODES_CORDONED  <hostname>  count=6  nodejanitor_skip=true
2026-05-28T...  SNAPSHOTS_COPIED    <hostname>  dest=/opt/...
2026-05-28T...  AGENT_STOPPED       <hostname>
2026-05-28T...  SERVER_STOPPED      <hostname>
2026-05-28T...  PREPATCH_COMPLETE   <leader-hostname>
```

---

## Abort behavior

**No automatic rollback.** If any script exits with code 1, the cluster is left in whatever state it reached. Do not continue without triage.

| Where it failed | Cluster state | What to check |
|---|---|---|
| Step 1 (preflight) | Unchanged — fully serving | Fix the failing check, re-run `01-preflight.sh` |
| Step 2 (maintenance/cordon) | Partial — may be in maintenance mode | Check `uipathctl cluster maintenance is-enabled`; check `kubectl get nodes` for cordon state |
| Step 3 (backup) | Unchanged — fully up, maintenance mode active | Check disk space; re-run `02-backup.sh` (idempotent — creates new timestamped dir) |
| Step 4 (agent stop) | Partial — some agents stopped | Check which agents have `AGENT_STOPPED` in state log; remaining agents still running |
| Step 5 (server stop) | Partial — some servers stopped | Check which servers have `SERVER_STOPPED` in state log; etcd may have lost quorum |

---

## Post-patch checklist (after cluster restart)

After OS patches are applied and all nodes have rebooted, bring the cluster back up in reverse order (leader server first, then non-leader servers, then agents). Then:

```bash
# 1. Verify all nodes have rejoined
kubectl get nodes

# 2. Verify etcd health
/var/lib/rancher/rke2/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  endpoint health --cluster

# 3. Disable UiPath maintenance mode
uipathctl cluster maintenance disable --namespace uipath

# 4. Remove nodejanitor/skip label BEFORE uncordoning
#    (so nodejanitor doesn't re-cordon nodes after uncordon)
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl label node "${node}" nodejanitor/skip-
done

# 5. Uncordon all nodes
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl uncordon "${node}"
done

# 6. Run product health check
uipathctl health check --namespace uipath --timeout 10m

# 7. Run preflight again to confirm baseline is restored
./01-preflight.sh
```

---

## Quick reference — command summary

```bash
# Full pre-flight (primary server)
./01-preflight.sh

# Enable maintenance mode + cordon all nodes (primary server)
./03-prepatch.sh --global

# Backup snapshots + config (each server node, locally)
./02-backup.sh

# Stop each agent (locally on each agent, sequential)
./03-prepatch.sh --stop-agent

# Identify etcd leader at any time (any server node)
./03-prepatch.sh --identify-leader

# Stop each server (locally on each server, non-leader first, leader last)
./03-prepatch.sh --stop-server
```

---

## Files

```
AutomationSuite_scripts/
├── README.md              ← this file
├── 01-preflight.sh        ← pre-flight health gate (9 checks)
├── 02-backup.sh           ← etcd snapshot + rke2 config backup (server nodes)
└── 03-prepatch.sh         ← maintenance mode, cordon, and per-node stop
```

---

*Plan document: [Confluence v1.1](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90751108300/Cluster+nodes+Pre-Patch+Tasks)*
