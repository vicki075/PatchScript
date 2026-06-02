# UiPath Automation Suite — OS Pre-Patch Scripts

**Product:** UiPath Automation Suite 24.10.4 (offline / air-gapped)  
**Cluster:** RKE2 — any odd number of server (control-plane) nodes + any number of agent nodes  
**Plan doc:** [Cluster nodes Pre-Patch Tasks (Confluence v1.1)](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90751108300/Cluster+nodes+Pre-Patch+Tasks)

---

## Three execution flavors

| Flavor | When to use | Scripts |
|---|---|---|
| **1 — Manual** | Full control, step-by-step, operator at the keyboard | `01-preflight.sh` → `02-backup.sh` → `03-prepatch.sh` |
| **2 — Per-node cron** | Unattended; schedule each node individually; good when SSH to all nodes from one place is not possible | `patch-node.sh` (cron on each node) |
| **3 — SSH Orchestrator** | Fully autonomous from a single jump host or primary server; one command controls the whole cluster | `patch-orchestrate.sh` |

All three flavors run the same underlying sequence:  
health check → maintenance mode → cordon → backup → drain → stop (leader last).

---

## Download (always latest `main`)

```bash
for f in 01-preflight.sh 02-backup.sh 03-prepatch.sh patch-node.sh patch-orchestrate.sh; do
  curl -fsSL "https://raw.githubusercontent.com/vicki075/PatchScript/main/${f}" -o "${f}"
done
chmod +x 01-preflight.sh 02-backup.sh 03-prepatch.sh patch-node.sh patch-orchestrate.sh
```

---

## Prerequisites (all flavors)

### Environment — automatic, no manual export needed

All scripts self-export `KUBECONFIG` and `PATH` at startup:

| Node type | `KUBECONFIG` |
|---|---|
| Server | `/etc/rancher/rke2/rke2.yaml` |
| Agent | `/var/lib/rancher/rke2/agent/kubelet.kubeconfig` |

`PATH` extended with `/usr/local/bin:/var/lib/rancher/rke2/bin` on all nodes.

### uipathctl — auto-discovered (priority order)

1. `PATH`
2. `--installer-dir` flag → `<version-folder>/installer/bin/uipathctl`
3. `/opt/UiPathAutomationSuite/latest/installer/bin/uipathctl` (symlink fallback)

**Path depth is tolerant** — any of these resolve correctly:

```bash
--installer-dir=/opt/UiPathAutomationSuite/2024.10.4           # canonical
--installer-dir=/opt/UiPathAutomationSuite/2024.10.4/          # trailing slash OK
--installer-dir=/opt/UiPathAutomationSuite/2024.10.4/installer # extra depth OK
--installer-dir=/opt/UiPathAutomationSuite/2024.10.4/installer/ # both OK
```

Both spellings accepted: `--installer-dir` and `--install-dir`.

### etcdctl — auto-discovered (priority order)

1. Host binary: `/var/lib/rancher/rke2/bin/etcdctl`
2. Container exec via `crictl` (clusters where etcdctl lives inside the etcd container)

`patch-orchestrate.sh` adds a third fallback: SSH into the first server node.

### On every node

- `bash` 4+, `python3` 3.6+
- RKE2 package pin: `exclude=rke2-*` in `/etc/yum.conf` or `/etc/yum.repos.d/*.repo`
- Minimum free disk: `/var/lib/rancher` ≥5 GB · `/var/lib/kubelet` ≥2 GB · `/var` ≥3 GB · `/opt` ≥2 GB

### Flavor 3 additional requirements

- `sshpass` installed on the orchestrator node: `yum install sshpass`
- SSH access (password auth) from orchestrator to all cluster nodes
- `kubectl` access from the orchestrator node

---

## Output verbosity

All scripts default to **quiet mode** — only `[PASS]`, `[WARN]`, `[FAIL]`, and step progress lines are printed.  
Add `--verbose` to see full detail: `[INFO]` lines, etcd tables, kubectl output.

| Level | Colour | Exit | Meaning |
|---|---|---|---|
| `[PASS]` | Green | 0 | Check passed |
| `[WARN]` | Yellow | 0 | Advisory — review before patching, does not block |
| `[FAIL]` | Red | 1 | Hard blocker — must resolve before proceeding |

---

## Flavor 1 — Manual (step-by-step)

**Confluence guide:** [Cluster Patch Instructions](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90768867477/Cluster+Patch+Instructions)

### PHASE 1 — Pre-flight checks
**Where:** Primary server node · **Once only**

```bash
./01-preflight.sh --installer-dir=/opt/UiPathAutomationSuite/2024.10.4
./01-preflight.sh --installer-dir=/opt/UiPathAutomationSuite/2024.10.4 --verbose
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

> **Stop here if any `[FAIL]` appears.** Exit code 1. Resolve all failures and re-run.

### PHASE 2 — Enable maintenance mode + cordon all nodes
**Where:** Primary server node · **Once only**

```bash
./03-prepatch.sh --global --installer-dir=/opt/UiPathAutomationSuite/2024.10.4
```

1. Enables `uipathctl cluster maintenance` — UiPath product pods scale to 0 gracefully
2. Cordons all nodes + labels `nodejanitor/skip=true`
3. Identifies and prints the etcd leader — **record it**

`--global` is idempotent — safe to re-run if interrupted.

### PHASE 3 — Backup etcd snapshots and RKE2 config
**Where:** Each server node locally · **ALL servers before any stop**

```bash
./02-backup.sh --installer-dir=/opt/UiPathAutomationSuite/2024.10.4
```

Backs up last 2 etcd snapshots + `/etc/rancher/rke2/config.yaml` with sha256 verification.  
Destination: `/opt/UiPathAutomationSuite/backup_patch/<hostname>-<timestamp>/`

> **Back up ALL server nodes before running any stop command.**  
> Once a server is stopped its snapshots are inaccessible.

### PHASE 4 — Stop nodes
**Where:** Each node locally · **One at a time**

```bash
# Agent nodes first (skip if none):
./03-prepatch.sh --stop-agent --installer-dir=/opt/UiPathAutomationSuite/2024.10.4

# Non-leader server nodes:
./03-prepatch.sh --stop-server --installer-dir=/opt/UiPathAutomationSuite/2024.10.4

# Leader server — LAST:
./03-prepatch.sh --stop-server --installer-dir=/opt/UiPathAutomationSuite/2024.10.4
```

Stop sequence per node (matches UiPath docs):
1. `systemctl stop node-drain.service` (up to 600s — runs `/opt/node-drain.sh` ExecStop)
2. `systemctl stop rke2-server` or `rke2-agent` (up to 300s)
3. `rke2-killall.sh` (clears residual processes and pod mounts)

---

## Flavor 2 — Per-node cron (`patch-node.sh`)

**Confluence guide:** [patch-node.sh Usage Guide](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90768998637/patch-node.sh+Usage+Guide+amp+Post-Patch+Commands)

Runs the full sequence unattended on each node via cron. Stagger by 5 minutes; leader runs last.

### Step 1 — Identify the leader (before scheduling crons)

```bash
./patch-node.sh --identify-leader --installer-dir=/opt/UiPathAutomationSuite/2024.10.4
```

### Step 2 — Schedule crons (staggered 5 min apart)

| Node | Role | Example cron time |
|---|---|---|
| `agent-1` | Agent | `0 22 * * *` |
| `server-a` | Non-leader server | `5 22 * * *` |
| `server-c` | Non-leader server | `10 22 * * *` |
| `server-b` | **LEADER (last)** | `15 22 * * *` |

```bash
# Crontab entry on each node (adjust path and time):
5 22 * * * root /path/to/patch-node.sh --installer-dir=/opt/UiPathAutomationSuite/2024.10.4 >> /var/log/patch-node.log 2>&1
```

### Skip-hc options

```bash
# Skip specific components:
./patch-node.sh --installer-dir=/opt/UiPathAutomationSuite/2024.10.4 --skip-hc=SYNC,DOCUMENTUNDERSTANDING

# Skip all health check failures:
./patch-node.sh --installer-dir=/opt/UiPathAutomationSuite/2024.10.4 --skip-hc=all
```

---

## Flavor 3 — SSH Orchestrator (`patch-orchestrate.sh`)

**Confluence guide:** *(see patch-orchestrate.sh Usage Guide — subpage of Cluster Patch Instructions)*

Single command from the primary server node or a jump host. Automates the entire cluster stop sequence over SSH — no crons, no per-node logins.

### Prerequisites

```bash
yum install sshpass   # on the orchestrator node only
```

### Basic usage

```bash
./patch-orchestrate.sh \
  --installer-dir=/opt/UiPathAutomationSuite/2024.10.4 \
  --ssh-password=<password> \
  --servers=10.0.0.4,10.0.0.5,10.0.0.6 \
  --agents=10.0.0.7,10.0.0.8
```

### Non-root SSH user (sudo escalation auto-enabled)

```bash
./patch-orchestrate.sh \
  --installer-dir=/opt/UiPathAutomationSuite/2024.10.4 \
  --ssh-user=admin \
  --ssh-password=<password> \
  --servers=10.0.0.4,10.0.0.5,10.0.0.6
```

Sudo is auto-enabled when `--ssh-user` is not `root`. Same password is used for SSH and sudo.

### Skip health check failures

```bash
--skip-hc=all
--skip-hc=SYNC,DOCUMENTUNDERSTANDING
```

### What it does end-to-end

1. Resolves uipathctl locally
2. Discovers nodes (from kubectl or `--servers`/`--agents`)
3. Builds IP → k8s node name map (`kubectl get nodes -o wide`)
4. Detects etcd leader via etcdctl (host binary → crictl → SSH fallback)
5. Tests SSH connectivity + sudo to all nodes
6. Runs health check + enables maintenance mode (local uipathctl)
7. Cordons all nodes (local kubectl, using k8s node names)
8. Backs up all server nodes in parallel (SSH)
9. Stops agent nodes sequentially (SSH)
10. Stops non-leader server nodes sequentially (SSH)
11. Stops etcd leader last (SSH)

---

## Stop and reboot order (all flavors)

| Phase | Order | Why |
|---|---|---|
| **Stop** | Agents → non-leader servers → **leader last** | Keeps etcd quorum and kubectl API alive through each drain |
| **OS patch** | Any order | RKE2 is fully stopped; patch is independent |
| **Reboot** | **Leader first** → other servers → agents | Leader re-establishes etcd quorum before other nodes rejoin |

RKE2 restarts automatically after reboot via systemd. No manual `systemctl start` needed.

---

## Post-patch cluster restore (all flavors)

After all nodes reboot and rejoin:

```bash
# 1. Confirm all nodes Ready
kubectl get nodes

# 2. Remove nodejanitor/skip label BEFORE uncordoning
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl label node "${node}" nodejanitor/skip-
done

# 3. Uncordon all nodes
for node in $(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name'); do
  kubectl uncordon "${node}"
done

# 4. Disable maintenance mode
/opt/UiPathAutomationSuite/2024.10.4/installer/bin/uipathctl cluster maintenance disable

# 5. Wait 2-3 min for UiPath pods to come back, then run health check
/opt/UiPathAutomationSuite/2024.10.4/installer/bin/uipathctl health check --timeout 10m

# 6. Re-run preflight to confirm baseline restored
./01-preflight.sh --installer-dir=/opt/UiPathAutomationSuite/2024.10.4
```

---

## Abort behaviour

No automatic rollback on failure. Investigate before continuing or re-running.

| Phase failed | Cluster state | Recovery |
|---|---|---|
| 1 — Preflight | Unchanged, fully serving | Fix the failing check, re-run `01-preflight.sh` |
| 2 — Maintenance/cordon | Partial — may be in maintenance | Re-run `./03-prepatch.sh --global` — idempotent |
| 3 — Backup | Unchanged, maintenance active | Check disk; re-run `02-backup.sh` — new timestamped dir each run |
| 4 — Agent stop | Partial — some agents stopped | Re-run `./03-prepatch.sh --stop-agent` on failed node |
| 4 — Server stop | Partial — some servers stopped | Re-run `./03-prepatch.sh --stop-server` on failed node |

---

## State log

All phases append to `/opt/UiPathAutomationSuite/prepatch-state.log`:

```
PREFLIGHT_PASS              <hostname>
MAINTENANCE_ENABLED         <hostname>
ALL_NODES_CORDONED          <hostname>
SNAPSHOTS_COPIED            <hostname>  dest=/opt/...
AGENT_STOPPED               <hostname>
SERVER_STOPPED              <hostname>
PREPATCH_COMPLETE           <leader-hostname>
```

---

## Files

```
├── README.md               ← this file
├── 01-preflight.sh         ← Flavor 1 Phase 1: cluster health gate (primary server, once)
├── 02-backup.sh            ← Flavor 1 Phase 3: etcd snapshot + rke2 config backup (each server)
├── 03-prepatch.sh          ← Flavor 1 Phase 2+4: maintenance mode, cordon, drain, stop
├── patch-node.sh           ← Flavor 2: unattended per-node cron script
├── patch-orchestrate.sh    ← Flavor 3: SSH orchestrator (single command, full cluster)
└── validate-proxy-config.sh
```

---

*Plan document: [Confluence v1.1](https://uipath.atlassian.net/wiki/spaces/~5ae87e891b0caa2d33fa16b0/pages/90751108300/Cluster+nodes+Pre-Patch+Tasks)*
