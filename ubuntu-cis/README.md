# `ubuntu-cis/` — Agent-mode on CIS L2 Hardened Ubuntu

Reference deliverable for **[PE-8774 — Agent mode on CIS L2 Hardened OS Image](https://spectrocloud.atlassian.net/browse/PE-8774)**.

Two scripts per Ubuntu version (22.04 + 24.04):

| Script | When to run | What it does |
|---|---|---|
| `cis-l2-agent-prep.sh` | **Before** `palette-agent-install.sh` (after CIS L2 hardening is applied) | Layers the K8s carve-outs CIS doesn't include — kernel modules, sysctls, swap-off, ulimits, AppArmor, sudo, AIDE/audit exclusions, firewall rules per cluster type + CNI + CSI |
| `cis-l2-post-install-verify.sh` | **After** `palette-agent-install.sh` succeeds | Smoke-tests: stylus systemd unit hardening, kubelet/containerd state, sysctl/module survival, `kubectl exec` (proves ptrace policy works), pod-to-pod ping (proves CNI), AppArmor profile states |

Per the ticket AC: this is a **sample** shared with the customer; not committed to public docs; not a supported Spectrocloud product surface.

## Where to put the scripts on the host

**Do NOT use `/tmp`, `/var/tmp`, or `/dev/shm`.** CIS L2 rule `1.1.2.4` (and the `/var/tmp` + `/dev/shm` equivalents) remounts these with `noexec` *if* they are separate partitions. Trying to execute the prep script there will fail with `Permission denied` on a fully-hardened host. On hosts where `/tmp` is not a separate partition the rule no-ops, which is why it sometimes appears to "work" — but the customer's prod images will partition `/tmp`, so build the runbook for the strict case.

**Use `/root/` for the prep + verify scripts** — it's root's home, root-only, never `noexec`. The prep script itself creates `/opt/palette-agent/` (exec-OK) for the agent install binary in section [4/12].

```bash
# As root (or via sudo -i):
mkdir -p /root/canvos-prep
cd /root/canvos-prep

# Copy or curl the two scripts into here
curl -fsSLO https://raw.githubusercontent.com/spectrocloud/agent-mode/PE-8774/ubuntu-cis/24.04/cis-l2-agent-prep.sh
curl -fsSLO https://raw.githubusercontent.com/spectrocloud/agent-mode/PE-8774/ubuntu-cis/24.04/cis-l2-post-install-verify.sh
chmod +x cis-l2-agent-prep.sh cis-l2-post-install-verify.sh

# Run prep
./cis-l2-agent-prep.sh --cluster kubeadm --role both --cni calico --csi longhorn
```

If `curl` from github isn't allowed on the host, `scp` from the workstation:
```bash
# from your workstation:
scp ubuntu-cis/24.04/*.sh root@<host>:/root/canvos-prep/
```

Quick safe-location reference:

| Path | Safe to run from? | Why |
|---|---|---|
| `/root/`            | ✓ Yes  | Root home, always exec, root-only readable |
| `/opt/palette-agent/` | ✓ Yes  | Created by prep script section 4 explicitly for this purpose |
| `/usr/local/sbin/`  | ✓ Yes  | Standard exec path, root-write |
| `/tmp/`             | ✗ No (when separate partition) | CIS 1.1.2.4 — `noexec` |
| `/var/tmp/`         | ✗ No (when separate partition) | CIS 1.1.3.4 — `noexec` |
| `/dev/shm/`         | ✗ No                          | CIS 1.1.4.4 — `noexec` |
| `/home/<user>/`     | ⚠ Maybe                       | Some CIS profiles set `nodev,nosuid` on `/home`; usually exec-OK but check `findmnt /home` |

Verify your `/tmp` status before assuming:
```bash
findmnt -no OPTIONS /tmp /var/tmp /dev/shm /home /root 2>/dev/null
```
If any line for `/tmp`/`/var/tmp`/`/dev/shm` contains `noexec`, do NOT put executables there.

## Lifecycle — where these run

```
┌────────────────────────────────────────────────────────────┐
│ 1. Provision Ubuntu 22.04 or 24.04 VM                       │
├────────────────────────────────────────────────────────────┤
│ 2. Apply CIS L2 hardening (customer's process)              │
│    sudo pro enable usg && sudo usg fix cis_level2_server    │
│    (takes 30-60 min; aide --init alone is 15-30 min)        │
│    sudo reboot                                              │
├────────────────────────────────────────────────────────────┤
│ 3. Copy scripts to /root/canvos-prep (NOT /tmp - noexec)    │
│    ▶ cis-l2-agent-prep.sh ◀                                 │
│    cd /root/canvos-prep                                     │
│    sudo ./cis-l2-agent-prep.sh \                            │
│      --cluster {kubeadm|k3s|rke2} \                         │
│      --role    {server|worker|both} \                       │
│      --cni     {calico|flannel|cilium|weave|none} \         │
│      --csi     longhorn,nfs                                 │
│    sudo reboot                                              │
│    sudo ./cis-l2-agent-prep.sh --verify ...                 │
├────────────────────────────────────────────────────────────┤
│ 4. Download palette-agent-install.sh to /opt/palette-agent  │
│    (prep script section 4 created this exec-OK directory)   │
│    cd /opt/palette-agent && sudo ./palette-agent-install.sh │
├────────────────────────────────────────────────────────────┤
│ 5. ▶ cis-l2-post-install-verify.sh ◀                        │
│    cd /root/canvos-prep                                     │
│    sudo ./cis-l2-post-install-verify.sh                     │
│    Confirms stylus unit + kubelet + CNI + kubectl exec all  │
│    work under CIS L2 carve-outs.                            │
└────────────────────────────────────────────────────────────┘
```

## What `cis-l2-agent-prep.sh` does (12 sections + a packages pre-step)

| # | Section | Why CIS L2 blocks K8s | Carve-out applied |
|---|---|---|---|
| 0 | Required packages | Minimal Ubuntu Server images omit `rsync`, `jq`, `nfs-common`, etc. that `palette-agent-install.sh` and kubelet/CNI/CSI plugins need — install otherwise aborts with e.g. `rsync is not installed`. | Installs the base set (`rsync curl ca-certificates jq tar gzip openssl iproute2 ethtool socat conntrack ipset`) plus CSI-specific (`open-iscsi`, `nfs-common`, `lvm2`, `ceph-common`) and CNI-specific (`wireguard-tools`, `libelf1`, `libcap2-bin`) based on `--csi` / `--cni` flags. Enables `iscsid` for Longhorn/OpenEBS. |
| 1 | Kernel modules | `kernel.modules_disabled=1` blocks `modprobe` after boot | Lists `overlay br_netfilter nf_conntrack ip_vs* vxlan iptable_nat nf_nat xt_* dm_mod` in `/etc/modules-load.d/canvos-k8s-agent.conf`, plus CNI-specific (`ipip` for Calico) and CSI-specific (`iscsi_tcp`, `rbd`, `nfs`, `fuse`). Loaded by `systemd-modules-load.service` before the lockdown sysctl fires. |
| 2 | Sysctl | CIS sets `ip_forward=0`, `bpf_disabled=1`, `ptrace_scope=3`, etc. | Single drop-in `99-zzz-k8s-agent.conf` overrides for forwarding, bridge-nf-call, rp_filter, eBPF, ptrace, perf_event, conntrack/inotify/file-max ceilings, tcp keepalives, port-range, pid_max, vm.max_map_count, neigh GC thresholds. |
| 3 | Swap | K8s (kubeadm) refuses to start with swap on | `swapoff -a`, comments out swap lines in `/etc/fstab`, masks zram-generator. |
| 4 | Mount safety | CIS L2 may mount `/var` or `/var/lib` with `noexec` — containers won't run | Warns the operator and instructs how to remount. Creates `/opt/palette-agent` exec-OK working directory. Sets `/var/lib/kubelet` rshared for CSI mount propagation. |
| 5 | Limits | `nofile`, `nproc`, `memlock` defaults too low for K8s scale | `/etc/security/limits.d/99-k8s-agent.conf` plus systemd drop-ins for `containerd`, `kubelet`, `stylus-agent`, `palette-agent` units (LimitNOFILE=1048576, LimitMEMLOCK=infinity, TasksMax=infinity, Delegate=yes, KillMode=process). |
| 6 | cgroup v2 | Modern kubelet expects unified hierarchy | Checks `/sys/fs/cgroup` is `cgroup2`; warns + instructs on grub change if not. |
| 7 | Time sync | x509 cert validation needs synced clock | Verifies chrony or systemd-timesyncd active; enables timesyncd if neither. |
| 8 | AppArmor | Enforcing profiles deny container runtime ops | Sets `runc`, `containerd`, `docker`, `kubelet` profiles to **complain** mode. |
| 9 | sudo | `Defaults requiretty` blocks automated install | Narrow `!requiretty` exception in `/etc/sudoers.d/99-canvos-agent` for the install binaries. Validated via `visudo`. |
| 10 | AIDE exclusions | Kubelet/containerd churn floods AIDE diff reports | Adds `!/var/lib/containerd`, `!/var/lib/kubelet`, `!/var/lib/etcd`, `!/var/lib/spectro`, `!/var/log/pods`, `!/run/containerd`, `!/etc/cni`, `!/etc/kubernetes`, etc. to `/etc/aide/aide.conf.d/99-canvos-k8s-exclusions.conf`. |
| 11 | Auditd exclusions | Same paths overrun the audit buffer at kubelet write rate | `-a never,exit -F dir=…` rules in `/etc/audit/rules.d/99-zzz-k8s-exclusions.rules`. `augenrules --load` to apply live. |
| 12 | Firewall | CIS L2 default-deny egress + ingress | Egress for DNS/HTTP/HTTPS/NTP + cluster control-plane peering. Ingress per cluster type / role / CNI / CSI — see matrices below. **Auto-detects ufw, firewalld, or nftables**; falls back to installing ufw only when no manager is present *and* nftables isn't already active. For nftables, writes its own `inet canvos_k8s` table at priority `filter-10` so it composes with whatever ruleset CIS L2 / the operator has already established. |

## Flag reference

```
--cluster {kubeadm|k3s|rke2|canonical}   # K8s distribution (default: kubeadm)
                                          # canonical = Canonical Kubernetes (k8s-snap)
--role    {server|worker|both}            # Node role (default: both)
--cni     {calico|flannel|cilium|weave|none}   # CNI (default: calico)
--csi     <list>                          # Comma-separated CSIs: longhorn,rook-ceph,openebs,nfs,none
--apply (default) | --verify | --dry-run | --show-ports
```

`--show-ports` prints the full ingress/egress rule list for the chosen flags without modifying the firewall — useful for review or pasting into a hardware firewall.

## Port matrix

### Cluster type — control plane (`--role server`)

| Port      | Proto | kubeadm | k3s     | RKE2  | canonical | Notes |
|-----------|-------|---------|---------|-------|-----------|-------|
| 6400      | tcp   | —       | —       | —     | ✓         | k8sd cluster API (Canonical Kubernetes) |
| 6443      | tcp   | ✓       | ✓       | ✓     | ✓         | K8s API |
| 9345      | tcp   | —       | —       | ✓     | —         | RKE2 supervisor (agent registration) |
| 2379-2380 | tcp   | ✓       | HA only | ✓     | ✓         | etcd server + peer (k8s-dqlite for canonical) |
| 2379-2381 | tcp   | —       | —       | ✓     | ✓         | RKE2 etcd learner / canonical extra dqlite |
| 10250     | tcp   | ✓       | ✓       | ✓     | ✓         | kubelet |
| 10257     | tcp   | ✓       | —       | —     | ✓         | kube-controller-manager |
| 10259     | tcp   | ✓       | —       | —     | ✓         | kube-scheduler |
| 51820-1   | udp   | —       | opt     | —     | —         | k3s WireGuard backend |

### Cluster type — worker (`--role worker`)

| Port        | Proto    | kubeadm | k3s     | RKE2   | canonical | Notes |
|-------------|----------|---------|---------|--------|-----------|-------|
| 10250       | tcp      | ✓       | ✓       | ✓      | ✓         | kubelet API |
| 10256       | tcp      | ✓       | —       | —      | ✓         | kube-proxy health |
| 30000-32767 | tcp+udp  | ✓       | ✓       | ✓      | ✓         | NodePort services |

### CNI (`--cni …`)

| CNI     | Port(s)            | Proto      | Why |
|---------|--------------------|------------|-----|
| Calico  | 4789               | udp        | VXLAN overlay |
| Calico  | 179                | tcp        | BGP (optional) |
| Calico  | 5473               | tcp        | Typha (optional) |
| Calico  | —                  | ip proto 4 | IPIP — added via raw iptables (ufw can't express) |
| Flannel | 8472               | udp        | VXLAN |
| Flannel | 51820              | udp        | WireGuard (optional) |
| Cilium  | 8472               | udp        | VXLAN tunnel |
| Cilium  | 6081               | udp        | GENEVE (optional) |
| Cilium  | 4240               | tcp        | health |
| Cilium  | 4244               | tcp        | Hubble relay |
| Cilium  | 51871              | udp        | WireGuard (optional) |
| Weave   | 6783               | tcp+udp    | control + datapath |
| Weave   | 6784               | udp        | datapath alt |

### CSI (`--csi …`)

| CSI       | Port(s)              | Proto    | Notes |
|-----------|----------------------|----------|-------|
| Longhorn  | 9500-9504            | tcp      | engine + replicas |
| Longhorn  | 8500                 | tcp      | instance manager |
| Longhorn  | 30001                | tcp      | WebUI (optional) |
| Rook-Ceph | 3300                 | tcp      | msgr v2 |
| Rook-Ceph | 6789                 | tcp      | msgr v1 |
| Rook-Ceph | 6800-7300            | tcp      | OSDs |
| OpenEBS   | 3260                 | tcp      | iSCSI |
| OpenEBS   | 9500                 | tcp      | cstor |
| OpenEBS   | 7676                 | tcp      | mayastor |
| NFS       | 2049                 | tcp+udp  | NFS |
| NFS       | 111                  | tcp+udp  | rpcbind |
| NFS       | 20048                | tcp+udp  | mountd |

`--csi` accepts a comma-separated list, e.g. `--csi longhorn,nfs` opens the union.

### Egress (always — needed for install + cluster ops)

| Port  | Proto | Reason |
|-------|-------|--------|
| 53    | udp+tcp | DNS |
| 80    | tcp   | HTTP — apt + agent install + non-TLS registries |
| 443   | tcp   | HTTPS — api.spectrocloud.com + github + container registries |
| 123   | udp   | NTP |
| 6443  | tcp   | inter-CP API |
| 2379-2380 | tcp | etcd peering |

For production deployments with a strict outbound proxy, replace these with FQDN-based allow rules instead of port-only.

## What `cis-l2-post-install-verify.sh` checks

| # | Check | Why it matters |
|---|---|---|
| 1 | Stylus / palette-agent systemd unit is active + enabled | Install actually completed |
| 1 | Unit's `NoNewPrivileges` ≠ yes | setuid for container processes |
| 1 | Unit's `RestrictNamespaces` ≠ yes | container namespace creation |
| 1 | Unit's `ProtectKernelModules` ≠ yes | runtime modprobe by CNI |
| 1 | Unit's `ProtectKernelTunables` ≠ yes | kubelet writes to /proc/sys/* |
| 1 | Unit's `MountFlags` ≠ private | volume mount propagation |
| 1 | Unit's `LimitNOFILE` ≥ 1048576 | scale |
| 2 | containerd active; kubelet active | Cluster runtime up |
| 3 | overlay / br_netfilter / nf_conntrack / ip_vs modules loaded | CNI / kube-proxy |
| 4 | Sysctls survived: ip_forward, bridge-nf-call, bpf_disabled, ptrace_scope, max_map_count | Reboot didn't undo them |
| 5 | /var, /var/lib, /var/lib/{containerd,kubelet} not noexec; swap off | Runtime can execute containers |
| 6 | `kubectl exec` on a Running pod | Proves `ptrace_scope=0`, AppArmor, runtime caps OK |
| 7 | Pod-to-pod connectivity (ping / wget / nc) | CNI is actually wiring traffic |
| 8 | AppArmor: runc, containerd, kubelet not enforcing | Won't deny ops |

The script exits non-zero if any check fails; useful as a CI gate in pipelines that provision CIS-L2 K8s nodes.

## Re-verifying CIS compliance post-prep

After this prep, a `usg audit cis_level2_server` or `oscap` scan against the **CIS Ubuntu Linux 22.04/24.04 LTS Benchmark, Level 2** will report deviations on these expected items — document them in your compliance attestation:

| CIS rule pattern | Our setting | Reason |
|---|---|---|
| `sysctl_net_ipv4_ip_forward_*` | 1 | K8s pod networking |
| `sysctl_kernel_unprivileged_bpf_disabled` | 0 | Cilium / kube-proxy bpf |
| `sysctl_kernel_yama_ptrace_scope` | 0 | kubectl exec |
| `sysctl_net_core_bpf_jit_harden` | 0 | Cilium perf |
| `kernel_module_*_disabled` for overlay/br_netfilter/etc | loaded | K8s requires |
| `ufw_default_deny_outgoing` | allow | Install + registry access |
| `ufw_default_deny_incoming` | allow on specific K8s ports | Cluster comms |
| `sudo_require_authentication` for `!requiretty` line | exception | Agent install path only |
| AppArmor enforcing on `runc` / `containerd` | complain | Container runtime ops |
| `mount_option_*_noexec_*` for /var or /var/lib (if applied) | exec | Containers run from here |
| `service_swap_enabled` | swap off | K8s requirement |

These are all documented expected carve-outs from the CIS Kubernetes Benchmark.

## Layout

```
ubuntu-cis/
├── README.md                              # this file
├── 22.04/
│   ├── README.md                          # 22.04-specific notes
│   ├── cis-l2-agent-prep.sh               # prep (676 lines)
│   └── cis-l2-post-install-verify.sh      # post-install verify (254 lines)
└── 24.04/
    ├── README.md
    ├── cis-l2-agent-prep.sh
    └── cis-l2-post-install-verify.sh
```

Both versions are functionally identical with version-string headers; minor AppArmor profile filename differences are handled by file-existence checks inside the script.

## Differences vs `ubuntu-stig/24.04/` (on the `PE-8774` branch)

| | This folder | `ubuntu-stig/24.04/` |
|---|---|---|
| Benchmark | CIS Ubuntu LTS Level 2 | DISA STIG |
| Deliverable | Two operator scripts | Full base OCI image + ISO build |
| OS variants | 22.04 + 24.04 | 24.04 only |
| Use case | Customer-owned host + agent-mode install | Spectrocloud-built base image, BYOI |
| Ticket AC fit | Direct match | Adjacent — overlap on hardening but different scope |
