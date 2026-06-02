# UiPath Automation Suite — OS Pre-Patch Scripts

**Product:** UiPath Automation Suite 24.10.4 (offline / air-gapped)  
**Cluster:** RKE2 — any odd number of server (control-plane) nodes + any number of agent nodes  
**Plan doc:** [Cluster nodes Pre-Patch Tasks (Confluence v1.1)](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90751108300/Cluster+nodes+Pre-Patch+Tasks)

---

## The four phases — at a glance

```
PHASE 1  Pre-flight          01-preflight.sh          PRIMARY SERVER — once
         Comprehensive cluster health gate. Verifies everything is healthy
         before touching anything. If any [FAIL] appears, stop here.

PHASE 2  Maintenance mode    03-prepatch.sh --global  PRIMARY SERVER — once
         Brings UiPath products down gracefully (maintenance enable),
         then cordons all nodes cluster-wide. Identifies etcd leader.

PHASE 3  Backup              02-backup.sh             EACH SERVER — all before any stop
         Copies etcd snapshots + RKE2 config to a local dir. Pure file
         copy — no cluster state changes.

PHASE 4  Stop nodes          03-prepatch.sh           EACH NODE locally, one at a time
         Drains, stops RKE2, runs rke2-killall.sh. Agent nodes first
         (if any), then server nodes non-leader-first, leader last.
```

**What these scripts do NOT do:** OS patch, reboot, upgrade RKE2 binaries, bring the cluster back up.

---

## Why this order matters

| Phase | Why it must be in this position |
|---|---|
| Preflight first | Checks cluster health before any change is made. Once maintenance mode is on and nodes start stopping, the cluster is intentionally degraded — preflight would produce false failures if run later. |
| Maintenance mode before backup/stop | Gracefully quiesces UiPath product pods before any node goes down. Ensures a clean application state in the etcd snapshots. |
| Backup before any stop | Etcd snapshots only exist on running server nodes. Once a server is stopped, its snapshots are gone. All servers must be backed up before any stop command runs. |
| Stop order: agents → non-leader servers → leader last | Keeps etcd quorum (and the Kubernetes API) stable through each drain. Leader stops last so the API is available for draining non-leaders. |

---

## Prerequisites

### Environment — automatic, no manual export needed

All scripts self-export `KUBECONFIG` and `PATH` at startup:

| Node type | Detection | `KUBECONFIG` |
|---|---|---|
| Server | `/etc/rancher/rke2/rke2.yaml` exists | `/etc/rancher/rke2/rke2.yaml` |
| Agent | above file absent | `/var/lib/rancher/rke2/agent/kubelet.kubeconfig` |

Both node types: `PATH` extended with `/usr/local/bin:/var/lib/rancher/rke2/bin`

### uipathctl — auto-discovered (in priority order)

1. `PATH`
2. `UIPATH_INSTALLER_DIR` env var → `<dir>/bin/uipathctl`
3. `/opt/UiPathAutomationSuite/latest/installer/bin/uipathctl`
4. `find /opt/UiPathAutomationSuite -name uipathctl` (depth-limited)

If auto-discovery fails:
```bash
UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./01-preflight.sh
```

### etcdctl — auto-discovered (in priority order)

1. Host binary: `/var/lib/rancher/rke2/bin/etcdctl`
2. Container exec via `crictl` (clusters where etcdctl lives only inside the etcd container)

### On every node

- `bash` 4+, `python3` 3.6+
- RKE2 package pin: `exclude=rke2-*` in `/etc/yum.conf` or `/etc/yum.repos.d/*.repo`
- Minimum free disk: `/var/lib/rancher` ≥5 GB · `/var/lib/kubelet` ≥2 GB · `/var` ≥3 GB · `/opt` ≥2 GB

### Make scripts executable (one-time, on each node)

```bash
chmod +x 01-preflight.sh 02-backup.sh 03-prepatch.sh
```

---

## Output verbosity

All three scripts default to **quiet mode** — only `[PASS]`, `[WARN]`, `[FAIL]`, and step progress lines are printed.  
Add `--verbose` to see full detail: `[INFO]` lines, etcd tables, kubectl output.

```bash
./01-preflight.sh --verbose
./02-backup.sh --verbose
./03-prepatch.sh --global --verbose
```

| Level | Colour | Exit | Meaning |
|---|---|---|---|
| `[PASS]` | Green | 0 | Check passed |
| `[WARN]` | Yellow | 0 | Advisory — review before patching, does not block |
| `[FAIL]` | Red | 1 | Hard blocker — must resolve before proceeding |

---

## Step-by-step instructions

### PHASE 1 — Pre-flight checks
**Where:** Primary server node · **How many times:** Once · **When:** Before anything else

```bash
./01-preflight.sh
```

Runs 9 checks. All execute regardless of individual failures; consolidated summary at the end.

| Check | What it verifies |
|---|---|
| PF-01 | All nodes Ready; none pre-cordoned |
| PF-02 | etcd: all members started, leader elected, no alarms, DB size sane |
| PF-03 | API server `/readyz` clean |
| PF-04 | No pods CrashLoopBackOff / ImagePullBackOff / stuck Terminating |
| PF-05 | Disk space on this node (FAIL if critical mounts low) |
| PF-06 | RKE2 package pin (`exclude=rke2-*`) present |
| PF-07 | `uipathctl health check` passes |
| PF-08 | Maintenance mode not already set; no concurrent `uipathctl` process |
| PF-09 | etcd snapshots configured and fresh (<24h) |

**Expected result:**
```
  RESULT: ALL CHECKS PASSED ✓
```
or:
```
  RESULT: PASSED WITH N WARNING(S)   ← review warnings; does not block
```

> **Stop here if any `[FAIL]` appears.** Exit code 1. Resolve all failures and re-run before continuing.  
> Failures written to `/opt/UiPathAutomationSuite/prepatch-state.log`.

---

### PHASE 2 — Enable maintenance mode + cordon all nodes
**Where:** Primary server node · **How many times:** Once · **When:** After preflight passes

```bash
./03-prepatch.sh --global
```

What this does:
1. **Maintenance enable** — `uipathctl cluster maintenance enable` — UiPath product pods scale to 0 gracefully
2. **Cordon all nodes** — labels every node `nodejanitor/skip=true` then cordons it (scheduler disabled cluster-wide; nodejanitor cannot auto-uncordon during the patch window)
3. **Identifies etcd leader** — prints which server must be stopped **last** and started **first**

`--global` is **idempotent** — if a prior run completed maintenance enable but failed during cordon, re-running skips the enable and retries cordon.

**Expected output:**
```
[PASS]  Phase A: Maintenance mode enabled
[PASS]  Phase C: All 3 nodes cordoned and labelled nodejanitor/skip=true

--- etcd Leader Identification ---
  autosuiteb  (https://10.0.0.5:2379)  <<< LEADER — stop this server LAST
  autosuitea  (https://10.0.0.4:2379)
  autosuitec  (https://10.0.0.6:2379)
```

> **Record the leader hostname** — needed for Phase 4 stop order and Phase 5 restart order.

---

### PHASE 3 — Backup etcd snapshots and RKE2 config
**Where:** Each server node locally · **How many times:** Once per server · **When:** After Phase 2, BEFORE any stop

> **Back up ALL server nodes before running any stop command.**  
> Once a server is stopped its snapshots are inaccessible. Run `02-backup.sh` on every server first — order among servers does not matter.

```bash
./02-backup.sh
```

What it backs up per server node:
- Last 2 etcd snapshots → `/opt/UiPathAutomationSuite/backup_patch/<hostname>-<timestamp>/etcd/`
- `/etc/rancher/rke2/config.yaml` → `.../rke2-config/config.yaml`
- sha256 checksum + `.meta.json` per snapshot

Server role is detected from config/data directory presence — not from `rke2-server` being active. Snapshot files are on disk regardless of service state.

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

> If backup fails, the script exits. No cluster state has changed. Investigate before continuing.

---

### PHASE 4 — Stop nodes (drain + stop RKE2)
**Where:** Each node locally · **How many times:** Once per node · **When:** After ALL nodes are backed up

#### Agent nodes first (skip if no agents)

Run on each agent node, one at a time. Wait for each to complete before starting the next.

```bash
./03-prepatch.sh --stop-agent
```

Steps per agent:
1. `systemctl stop node-drain.service` (10 min timeout)
2. `systemctl stop rke2-agent` (5 min timeout)
3. `rke2-killall.sh` — clears residual containerd/kubelet, unmounts pod mounts
4. Verifies no residual processes remain

#### Server nodes next — non-leader first, leader last

```bash
# Non-leader server(s) first (any order among non-leaders):
./03-prepatch.sh --stop-server

# Leader server — LAST:
./03-prepatch.sh --stop-server
```

Steps per server:
1. etcd quorum check (auto-skipped on final server)
2. `systemctl stop node-drain.service`
3. `systemctl stop rke2-server` (5 min timeout)
4. `rke2-killall.sh` — clears residual processes and unmounts
5. Verifies no residual processes remain
6. **On the final/leader server:** writes `PREPATCH_COMPLETE_<timestamp>` marker

**Re-runnable after interruption:** If the script failed mid-way (e.g. rke2-server already stopped but killall hadn't run), re-running auto-detects the stopped service, runs `rke2-killall.sh` if residual processes exist, and completes cleanly.

**Expected output (final server):**
```
  Running: systemctl stop node-drain.service  (timeout: 600s)
[PASS]  node-drain.service stopped  ✓
  Running: systemctl stop rke2-server  (timeout: 300s)
[PASS]  rke2-server stopped  ✓
  Running: rke2-killall.sh  (timeout: 120s)
[PASS]  rke2-killall.sh complete  ✓
[PASS]  No residual rke2/containerd/kubelet processes on <hostname>  ✓

================================================================
  PRE-PATCH PHASE COMPLETE
  Last server stopped (etcd leader): <leader-hostname>
================================================================
  *** RESTART ORDER ***
  1. START <leader-hostname> FIRST
  2. Start remaining server nodes (one at a time, wait for Ready)
  3. Start agent nodes
```

---

### Cluster is ready for OS patch + reboot

All nodes: OS running, RKE2 fully stopped, no residual processes. Apply OS patches and reboot.

---

### PHASE 5 — Restart cluster (reverse stop order)

**Leader server first** — re-establishes etcd quorum before other nodes rejoin.

```bash
# On the leader server:
systemctl start rke2-server
# Wait until: kubectl get node <leader-hostname>  →  Ready

# Then each remaining server (one at a time, wait for Ready before starting next):
systemctl start rke2-server

# Then each agent (if any):
systemctl start rke2-agent
```

The leader hostname is recorded in the `PREPATCH_COMPLETE_*` marker:
```bash
cat /opt/UiPathAutomationSuite/PREPATCH_COMPLETE_*
```

---

## Why leader last / leader first?

etcd requires `floor(N/2)+1` nodes for quorum. Stopping non-leaders first keeps the leader (and the Kubernetes API) stable through each drain. Stopping the leader first triggers an unnecessary election while drains are still in progress.

The same logic applies on restart: starting the leader first re-establishes quorum before other nodes try to rejoin.

---

## Backup location

```
/opt/UiPathAutomationSuite/backup_patch/
└── <hostname>-<YYYYMMDD-HHMMSS>/
    ├── etcd/
    │   ├── etcd-snapshot-<hostname>-<epoch>
    │   ├── etcd-snapshot-<hostname>-<epoch>.meta.json
    │   ├── etcd-snapshot-<hostname>-<epoch-2>
    │   └── etcd-snapshot-<hostname>-<epoch-2>.meta.json
    └── rke2-config/
        └── config.yaml
```

---

## State log

All phases append to `/opt/UiPathAutomationSuite/prepatch-state.log`:

```
PREFLIGHT_PASS                <hostname>
MAINTENANCE_ENABLED           <hostname>
ALL_NODES_CORDONED            <hostname>  count=3  nodejanitor_skip=true
SNAPSHOTS_COPIED              <hostname>  dest=/opt/...
AGENT_STOPPED                 <hostname>
SERVER_STOPPED                <hostname>
PREPATCH_COMPLETE             <leader-hostname>  leader=<leader-hostname>
```

---

## Abort behaviour

No automatic rollback. If any script exits with code 1, investigate before continuing.

| Phase failed | Cluster state | Recovery |
|---|---|---|
| 1 — Preflight | Unchanged, fully serving | Fix the failing check, re-run `01-preflight.sh` |
| 2 — Maintenance/cordon | Partial — may be in maintenance | Re-run `./03-prepatch.sh --global` — idempotent, skips Phase A if already on |
| 3 — Backup | Unchanged, maintenance active | Check disk; re-run `02-backup.sh` — creates a new timestamped dir each run |
| 4 — Agent stop | Partial — some agents stopped | Re-run `./03-prepatch.sh --stop-agent` on the failed node — auto-handles residuals |
| 4 — Server stop | Partial — some servers stopped | Re-run `./03-prepatch.sh --stop-server` on the failed node — auto-handles residuals |

---

## Post-patch checklist (after all nodes restarted)

```bash
# 1. All nodes rejoined
kubectl get nodes

# 2. etcd healthy
etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  endpoint health --cluster

# 3. Disable maintenance mode
uipathctl cluster maintenance disable --namespace uipath

# 4. Remove nodejanitor/skip label BEFORE uncordoning
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl label node "${node}" nodejanitor/skip-
done

# 5. Uncordon all nodes
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl uncordon "${node}"
done

# 6. Re-run preflight to confirm baseline restored
./01-preflight.sh

# 7. Product health check
uipathctl health check --namespace uipath --timeout 10m
```

---

## Quick reference

```bash
# PHASE 1 — Preflight (primary server, once)
./01-preflight.sh
./01-preflight.sh --verbose

# PHASE 2 — Maintenance mode + cordon (primary server, once)
./03-prepatch.sh --global

# PHASE 3 — Backup (each server, locally — ALL before any stop)
./02-backup.sh

# PHASE 4 — Stop agents (each agent, locally, sequential — skip if none)
./03-prepatch.sh --stop-agent

# Identify etcd leader at any time
./03-prepatch.sh --identify-leader

# PHASE 4 — Stop servers (each server, locally — non-leader first, leader last)
./03-prepatch.sh --stop-server

# Override uipathctl path if not auto-discovered
UIPATH_INSTALLER_DIR=/opt/UiPathAutomationSuite/latest/installer ./01-preflight.sh
```

---

## Files

```
├── README.md              ← this file
├── 01-preflight.sh        ← Phase 1: cluster health gate (primary server, once)
├── 02-backup.sh           ← Phase 3: etcd snapshot + rke2 config backup (each server)
└── 03-prepatch.sh         ← Phase 2+4: maintenance mode, cordon, drain, stop
```

---

*Plan document: [Confluence v1.1](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90751108300/Cluster+nodes+Pre-Patch+Tasks)*
