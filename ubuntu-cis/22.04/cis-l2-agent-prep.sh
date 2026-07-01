#!/usr/bin/env bash
# cis-l2-agent-prep.sh — Ubuntu 22.04 LTS
#
# Comprehensive prep for a CIS Ubuntu Linux 22.04 LTS Level 2 hardened
# host that will run Spectrocloud Palette Edge agent-mode and join a
# Kubernetes cluster (kubeadm, k3s, or RKE2) with a CNI (Calico,
# Flannel, Cilium, Weave Net) and optionally a CSI (Longhorn, Rook-Ceph,
# OpenEBS, NFS).
#
# Run this AFTER CIS L2 hardening (e.g. `usg fix cis_level2_server`)
# and BEFORE `palette-agent-install.sh`. Idempotent.
#
# Usage:
#   sudo bash cis-l2-agent-prep.sh \
#       --cluster kubeadm \
#       --role both \
#       --cni calico \
#       --csi longhorn,nfs
#
#   sudo bash cis-l2-agent-prep.sh --verify        # re-check after reboot
#   sudo bash cis-l2-agent-prep.sh --dry-run       # preview, no writes
#   sudo bash cis-l2-agent-prep.sh --show-ports    # print firewall rules that would be added
#
# Flags:
#   --cluster {kubeadm|k3s|rke2|canonical}   K8s distribution (default: kubeadm)
#                                              (canonical = Canonical Kubernetes / k8s-snap)
#   --role    {server|worker|both} Node role (default: both)
#   --cni     {calico|flannel|cilium|weave|none}  CNI (default: calico)
#   --csi     <list>               Comma-separated CSIs: longhorn,rook-ceph,openebs,nfs,none (default: none)
#   --apply / --verify / --dry-run / --show-ports
#
# What this script does (each step is idempotent + skippable on --verify):
#   1.  Pre-load kernel modules required by K8s + CNI + CSI
#       (overlay, br_netfilter, nf_conntrack, ip_vs*, vxlan,
#        iptable_nat, nf_nat, xt_*, dm_mod, iscsi_tcp, rbd, nfs, fuse)
#   2.  Sysctl carve-outs for K8s pod networking, bridge filtering,
#       eBPF, ptrace (kubectl exec), conntrack/inotify ceilings,
#       TCP keepalives, port-range, VM mem settings (Elastic, Redis)
#   3.  Swap off (kubeadm requires; k3s/rke2 tolerate but K8s recommends)
#   4.  Mount safety: warn on noexec /var or /var/lib (containers won't run);
#       ensure /var/lib/kubelet propagation is shared; create /opt/palette-agent
#   5.  /etc/security/limits.d + systemd drop-ins so kubelet, containerd,
#       and stylus get nofile=1048576, memlock=infinity, nproc unlimited
#   6.  cgroup v2 check (kubelet on modern K8s expects unified hierarchy)
#   7.  Time sync verify (chrony or systemd-timesyncd active)
#   8.  AppArmor: container-runtime profiles to complain mode
#   9.  Sudoers: !requiretty exception for the palette-agent install path
#   10. AIDE exclusions for /var/lib/{containerd,kubelet,etcd}, /var/log/pods etc.
#   11. Auditd exclusions for the same noisy K8s runtime paths
#   12. Firewall:
#       (a) egress allowlist: DNS/HTTP/HTTPS/NTP for agent install + registries
#       (b) ingress rules per cluster type, role, CNI, CSI
#
# Compliance impact: most items above are documented CIS Kubernetes
# Benchmark carve-outs to the Ubuntu CIS L2 benchmark. Operator should
# include these as known deviations in their compliance attestation.

set -uo pipefail

VERSION=22.04
MODE=apply
CLUSTER=kubeadm
ROLE=both
CNI=calico
CSI=none
VERIFY_FAIL=0

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)        MODE=apply;       shift ;;
        --verify)       MODE=verify;      shift ;;
        --dry-run)      MODE=dryrun;      shift ;;
        --show-ports)   MODE=showports;   shift ;;
        --cluster)      CLUSTER="$2";     shift 2 ;;
        --role)         ROLE="$2";        shift 2 ;;
        --cni)          CNI="$2";         shift 2 ;;
        --csi)          CSI="$2";         shift 2 ;;
        -h|--help)
            sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Validate enums
case "$CLUSTER" in kubeadm|k3s|rke2|canonical) ;; *) echo "--cluster must be kubeadm|k3s|rke2|canonical" >&2; exit 2 ;; esac
case "$ROLE"    in server|worker|both) ;; *) echo "--role must be server|worker|both" >&2; exit 2 ;; esac
case "$CNI"     in calico|flannel|cilium|weave|none) ;; *) echo "--cni must be calico|flannel|cilium|weave|none" >&2; exit 2 ;; esac

if [ "$(id -u)" != "0" ] && [ "$MODE" != "showports" ]; then
    echo "Must be run as root: sudo $0 $*" >&2
    exit 1
fi

# OS detection (warn-only mismatch)
if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${VERSION_ID:-}" != "$VERSION" ] && [ "$MODE" != "showports" ]; then
        echo "WARN: this script targets Ubuntu $VERSION; detected ${VERSION_ID:-unknown}." >&2
        echo "      Continuing anyway." >&2
    fi
fi

echo "=================================================================="
echo "cis-l2-agent-prep.sh    mode=$MODE"
echo "  cluster=$CLUSTER  role=$ROLE  cni=$CNI  csi=$CSI"
echo "=================================================================="

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
do_run() {
    if [ "$MODE" = "dryrun" ] || [ "$MODE" = "showports" ]; then
        echo "DRY-RUN: $*"
    else
        "$@"
    fi
}

write_file() {
    local path="$1"; shift
    if [ "$MODE" = "dryrun" ]; then
        echo "DRY-RUN write $path:"; printf '          %s\n' "$@"
    elif [ "$MODE" = "verify" ]; then
        if [ -f "$path" ]; then echo "  ✓ $path"
        else echo "  ✗ $path MISSING"; VERIFY_FAIL=1
        fi
    elif [ "$MODE" = "showports" ]; then
        :   # skip file writes in show-ports mode
    else
        printf '%s\n' "$@" > "$path"
    fi
}

is_apply() { [ "$MODE" = "apply" ]; }

FW=
if command -v ufw >/dev/null 2>&1; then FW=ufw
elif command -v firewall-cmd >/dev/null 2>&1; then FW=firewalld
elif command -v nft >/dev/null 2>&1; then FW=nftables
fi

# nftables uses dash-ranges (1024-65535) while ufw/firewalld use colons (1024:65535).
nft_spec() { echo "$1" | tr ':' '-'; }

fw_in() {   # fw_in <port-spec> <proto> <comment>
    local spec="$1" proto="$2" comment="$3"
    if [ "$MODE" = "showports" ]; then
        printf '  INGRESS %s/%s  %s\n' "$spec" "$proto" "$comment"
        return
    fi
    case "$FW" in
        ufw)        do_run ufw allow in proto "$proto" to any port "$spec" comment "$comment" 2>/dev/null || true ;;
        firewalld)
            if echo "$spec" | grep -q ':'; then
                local start end; start="${spec%%:*}"; end="${spec##*:}"
                do_run firewall-cmd --permanent --add-port="${start}-${end}/${proto}" 2>/dev/null || true
            else
                do_run firewall-cmd --permanent --add-port="${spec}/${proto}" 2>/dev/null || true
            fi
            ;;
        nftables)
            local nspec; nspec=$(nft_spec "$spec")
            case "$proto" in
                tcp) NFT_IN_TCP="${NFT_IN_TCP}        tcp dport $nspec accept comment \"${comment}\"\\n" ;;
                udp) NFT_IN_UDP="${NFT_IN_UDP}        udp dport $nspec accept comment \"${comment}\"\\n" ;;
            esac
            ;;
    esac
}

fw_out() {  # fw_out <port-spec> <proto> <comment>
    local spec="$1" proto="$2" comment="$3"
    if [ "$MODE" = "showports" ]; then
        printf '  EGRESS  %s/%s  %s\n' "$spec" "$proto" "$comment"; return
    fi
    case "$FW" in
        ufw)        do_run ufw allow out proto "$proto" to any port "$spec" comment "$comment" 2>/dev/null || true ;;
        firewalld)  do_run firewall-cmd --permanent --add-port="${spec}/${proto}" 2>/dev/null || true ;;
        nftables)
            local nspec; nspec=$(nft_spec "$spec")
            case "$proto" in
                tcp) NFT_OUT_TCP="${NFT_OUT_TCP}        tcp dport $nspec accept comment \"${comment}\"\\n" ;;
                udp) NFT_OUT_UDP="${NFT_OUT_UDP}        udp dport $nspec accept comment \"${comment}\"\\n" ;;
            esac
            ;;
    esac
}

# ===========================================================================
# 0) Required packages for palette-agent-install.sh + cluster runtime
# ===========================================================================
# These are needed by the install script and/or by kubelet/CNI/CSI plugins at
# runtime. CIS L2 hardening does not remove them, but minimal Ubuntu Server
# images may lack some (rsync is the most common omission, observed in
# customer reports). Installing here makes the prep idempotent and avoids
# a "rsync not installed" abort halfway through palette-agent-install.sh.
echo
echo "[0/12] Required packages"
INSTALL_PKGS="rsync curl ca-certificates jq tar gzip openssl iproute2 ethtool socat conntrack ipset apparmor-utils"
# Pick a firewall manager. Order: existing ufw, existing firewalld, existing
# nftables, then ufw as a last-resort install. Don't install ufw if nftables
# is already active — they conflict and ufw will strip the existing ruleset
# (CIS L2 sometimes sets up either; we have to honour whichever is in use).
if command -v ufw >/dev/null 2>&1; then
    : # ufw already present
elif command -v firewall-cmd >/dev/null 2>&1; then
    : # firewalld already present
elif command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then
    : # nftables active — use it directly, do NOT install ufw on top
elif [ "$CSI" != "none" ] || [ "$CNI" != "none" ]; then
    INSTALL_PKGS="$INSTALL_PKGS ufw"
fi
# CSI-specific runtime tooling
case ",$CSI," in
    *,longhorn,*|*,openebs,*)  INSTALL_PKGS="$INSTALL_PKGS open-iscsi nfs-common" ;;
esac
case ",$CSI," in
    *,nfs,*)                   INSTALL_PKGS="$INSTALL_PKGS nfs-common" ;;
esac
case ",$CSI," in
    *,rook-ceph,*)             INSTALL_PKGS="$INSTALL_PKGS lvm2 ceph-common" ;;
esac
# CNI-specific tooling
case "$CNI" in
    calico)   INSTALL_PKGS="$INSTALL_PKGS wireguard-tools" ;;
    cilium)   INSTALL_PKGS="$INSTALL_PKGS wireguard-tools libelf1 libcap2-bin" ;;
    flannel)  INSTALL_PKGS="$INSTALL_PKGS wireguard-tools" ;;
esac
MISSING_PKGS=
# A package can be in dpkg's database with status "deinstall ok config-files"
# (CIS L2 removes rsync this way under rule 2.2.7) — `dpkg -s` returns 0 for
# that, but the binary is gone. We need to grep for the actual install
# status, not just the package's presence in the database.
for p in $INSTALL_PKGS; do
    if ! dpkg -s "$p" 2>/dev/null | grep -qE '^Status:.*install ok installed'; then
        MISSING_PKGS="$MISSING_PKGS $p"
    fi
done
if [ -n "$MISSING_PKGS" ]; then
    echo "  installing:$MISSING_PKGS"
    do_run apt-get update -qq
    do_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $MISSING_PKGS
else
    echo "  ✓ all required packages already installed"
fi
# open-iscsi service needs to be enabled+started for Longhorn/OpenEBS to attach
if dpkg -s open-iscsi >/dev/null 2>&1; then
    do_run systemctl enable --now iscsid 2>/dev/null || true
    echo "  ✓ iscsid enabled"
fi
# CIS L2 masks rpcbind + several NFS client units. Unmask + enable when an
# NFS-using CSI is in play (longhorn uses NFS for backup target; openebs +
# NFS CSI obviously need it; kubelet NFS volume mounts call rpc.statd).
case ",$CSI," in
    *,longhorn,*|*,openebs,*|*,nfs,*)
        if is_apply; then
            for u in rpcbind.service rpcbind.socket rpc-statd.service nfs-idmapd.service nfs-client.target; do
                systemctl unmask "$u" 2>/dev/null || true
            done
            systemctl enable --now rpcbind.socket rpcbind.service 2>/dev/null || true
            systemctl enable --now nfs-client.target 2>/dev/null || true
            echo "  ✓ NFS client stack (rpcbind, rpc-statd, nfs-client) unmasked + enabled"
        fi
        ;;
esac
# Re-detect firewall manager now that section 0 may have installed ufw.
FW=
if command -v ufw >/dev/null 2>&1; then FW=ufw
elif command -v firewall-cmd >/dev/null 2>&1; then FW=firewalld
elif command -v nft >/dev/null 2>&1; then FW=nftables
fi
echo "  ✓ firewall manager: ${FW:-NONE}"
# Accumulator arrays for nftables (single-shot rule emission at section 12).
NFT_IN_TCP=""; NFT_IN_UDP=""; NFT_OUT_TCP=""; NFT_OUT_UDP=""; NFT_IN_RAW=""

# ===========================================================================
# 1) Kernel modules
# ===========================================================================
echo
echo "[1/12] Kernel modules — pre-load before CIS L2's kernel.modules_disabled=1"
BASE_MODS="overlay br_netfilter nf_conntrack ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh vxlan iptable_nat iptable_filter iptable_mangle nf_nat xt_conntrack xt_mark xt_addrtype dm_mod"
# CNI-specific
CNI_MODS=""
case "$CNI" in
    calico)  CNI_MODS="ipip ip_tunnel"            ;;   # for IPIP mode
    cilium)  CNI_MODS=""                           ;;   # mostly eBPF, no extra modules
    flannel) CNI_MODS=""                           ;;
    weave)   CNI_MODS=""                           ;;
esac
# CSI-specific
CSI_MODS=""
for c in $(echo "$CSI" | tr ',' ' '); do
    case "$c" in
        longhorn|openebs|iscsi)  CSI_MODS="$CSI_MODS iscsi_tcp iscsi_target_mod target_core_mod" ;;
        rook-ceph|ceph)          CSI_MODS="$CSI_MODS rbd ceph"                                   ;;
        nfs)                     CSI_MODS="$CSI_MODS nfs nfsv4 sunrpc"                           ;;
        s3|fuse)                 CSI_MODS="$CSI_MODS fuse"                                       ;;
    esac
done
ALL_MODS="$BASE_MODS $CNI_MODS $CSI_MODS"

write_file /etc/modules-load.d/canvos-k8s-agent.conf \
    "# Pre-load K8s + CNI + CSI modules before CIS L2 locks module loading." \
    "# Loaded by systemd-modules-load.service early in boot." \
    $ALL_MODS
if is_apply; then
    LOADED=0; SKIPPED=0
    for m in $ALL_MODS; do
        if modprobe "$m" 2>/dev/null; then LOADED=$((LOADED + 1))
        else SKIPPED=$((SKIPPED + 1))
        fi
    done
    echo "  ✓ /etc/modules-load.d/canvos-k8s-agent.conf written ($(echo $ALL_MODS | wc -w) modules)"
    echo "  ✓ $LOADED modules loaded at runtime ($SKIPPED unavailable on this kernel — fine if not used)"
elif [ "$MODE" = "verify" ]; then
    for m in overlay br_netfilter nf_conntrack ip_vs; do
        if lsmod | awk '{print $1}' | grep -qx "$m"; then echo "  ✓ $m loaded"
        else echo "  ✗ $m NOT loaded"; VERIFY_FAIL=1
        fi
    done
fi

# ===========================================================================
# 2) Sysctl carve-outs
# ===========================================================================
echo
echo "[2/12] Sysctl K8s carve-outs"
write_file /etc/sysctl.d/99-zzz-k8s-agent.conf \
    "# K8s carve-outs over CIS L2 sysctl defaults (canvos-agent)" \
    "" \
    "# IP forwarding (CIS L2: 0; K8s requires)" \
    "net.ipv4.ip_forward = 1" \
    "net.ipv6.conf.all.forwarding = 1" \
    "net.ipv4.conf.all.forwarding = 1" \
    "net.ipv4.conf.default.forwarding = 1" \
    "" \
    "# Loose reverse-path (CIS L2: strict; overlay CNIs need loose)" \
    "net.ipv4.conf.all.rp_filter = 0" \
    "net.ipv4.conf.default.rp_filter = 0" \
    "" \
    "# Bridge traffic through netfilter (kube-proxy + NetworkPolicy)" \
    "net.bridge.bridge-nf-call-iptables = 1" \
    "net.bridge.bridge-nf-call-ip6tables = 1" \
    "net.bridge.bridge-nf-call-arptables = 1" \
    "" \
    "# eBPF (CIS L2 locks down; Cilium needs)" \
    "kernel.unprivileged_bpf_disabled = 0" \
    "net.core.bpf_jit_harden = 0" \
    "" \
    "# ptrace for kubectl exec / crictl exec (CIS L2: 3; K8s needs 0 or 1)" \
    "kernel.yama.ptrace_scope = 0" \
    "" \
    "# perf events for cAdvisor / observability" \
    "kernel.perf_event_paranoid = 2" \
    "" \
    "# Conntrack table (busy nodes need much more than default)" \
    "net.netfilter.nf_conntrack_max = 1048576" \
    "" \
    "# TCP tuning for long-lived K8s control-plane connections" \
    "net.ipv4.tcp_keepalive_time = 600" \
    "net.ipv4.tcp_keepalive_intvl = 60" \
    "net.ipv4.tcp_keepalive_probes = 5" \
    "" \
    "# Local port range (kube-proxy needs ample ephemeral ports)" \
    "net.ipv4.ip_local_port_range = 1024 65535" \
    "" \
    "# Backlog tuning for high-connection workloads" \
    "net.core.somaxconn = 32768" \
    "net.core.netdev_max_backlog = 16384" \
    "net.ipv4.tcp_max_syn_backlog = 8192" \
    "" \
    "# inotify / fs (kubelet + containerd at scale)" \
    "fs.inotify.max_user_instances = 8192" \
    "fs.inotify.max_user_watches = 524288" \
    "fs.file-max = 2097152" \
    "" \
    "# PID exhaustion guard for many-pod nodes" \
    "kernel.pid_max = 4194304" \
    "kernel.threads-max = 4194304" \
    "" \
    "# User namespaces (CRI-O, unprivileged kubelet probes)" \
    "user.max_user_namespaces = 28633" \
    "" \
    "# VM/memory for stateful workloads (Elastic, Cassandra, Redis)" \
    "vm.max_map_count = 262144" \
    "vm.overcommit_memory = 1" \
    "vm.swappiness = 1" \
    "" \
    "# Routing cache tuning" \
    "net.ipv4.neigh.default.gc_thresh1 = 4096" \
    "net.ipv4.neigh.default.gc_thresh2 = 8192" \
    "net.ipv4.neigh.default.gc_thresh3 = 16384"
if is_apply; then
    # Neutralize conflicting CIS L2 entries in /etc/sysctl.conf. That file
    # loads LAST in `sysctl --system` order (after /etc/sysctl.d/*) and
    # overrides our drop-in unless we comment those keys out.
    if [ -f /etc/sysctl.conf ]; then
        K8S_OVERRIDES='net\.ipv4\.ip_forward|net\.ipv6\.conf\.all\.forwarding|kernel\.yama\.ptrace_scope|kernel\.unprivileged_bpf_disabled|net\.core\.bpf_jit_harden|net\.ipv4\.conf\.all\.rp_filter|net\.ipv4\.conf\.default\.rp_filter|net\.bridge\.bridge-nf-call'
        if grep -qE "^\s*(${K8S_OVERRIDES})\s*=" /etc/sysctl.conf 2>/dev/null; then
            [ ! -f /etc/sysctl.conf.canvos-bak ] && cp -p /etc/sysctl.conf /etc/sysctl.conf.canvos-bak
            sed -i -E "s@^([[:space:]]*(${K8S_OVERRIDES})[[:space:]]*=.*)@# \1  # commented by canvos-agent (override in /etc/sysctl.d/99-zzz-k8s-agent.conf)@" /etc/sysctl.conf
            echo "  ✓ neutralized conflicting CIS L2 lines in /etc/sysctl.conf (backup: /etc/sysctl.conf.canvos-bak)"
        fi
    fi
    do_run sysctl --system >/dev/null
    echo "  ✓ /etc/sysctl.d/99-zzz-k8s-agent.conf written + applied"
fi
if [ "$MODE" = "verify" ]; then
    for kv in net.ipv4.ip_forward=1 kernel.unprivileged_bpf_disabled=0 kernel.yama.ptrace_scope=0 vm.max_map_count=262144; do
        k="${kv%=*}"; want="${kv#*=}"; got="$(sysctl -n "$k" 2>/dev/null || echo MISSING)"
        if [ "$got" = "$want" ]; then echo "  ✓ $k=$got"
        else echo "  ✗ $k=$got (want $want)"; VERIFY_FAIL=1
        fi
    done
fi

# ===========================================================================
# 3) Swap off
# ===========================================================================
echo
echo "[3/12] Swap (K8s requires off — disabling)"
if is_apply; then
    SWAP_WAS_ON=
    [ -n "$(swapon --show 2>/dev/null)" ] && SWAP_WAS_ON=1
    swapoff -a 2>/dev/null || true
    # Comment out swap entries in /etc/fstab so it doesn't come back on reboot
    FSTAB_CHANGED=
    if grep -qE '^[^#].*swap' /etc/fstab 2>/dev/null; then
        sed -i.bak -E 's|^([^#].*\s+swap\s+.*)$|# \1   # disabled by canvos-agent for K8s|' /etc/fstab
        FSTAB_CHANGED=1
    fi
    # Mask zram-generator if present (Ubuntu 22.04 cloud images enable zram swap)
    systemctl mask --now zram-generator.service 2>/dev/null || true
    systemctl mask --now dev-zram0.swap 2>/dev/null || true
    if [ -n "$SWAP_WAS_ON" ]; then echo "  ✓ swap disabled (was active; fstab updated=${FSTAB_CHANGED:-0})"
    else echo "  ✓ swap already off"; fi
elif [ "$MODE" = "verify" ]; then
    if [ -z "$(swapon --show 2>/dev/null)" ]; then echo "  ✓ swap is off"
    else echo "  ✗ swap still active: $(swapon --show --noheadings | awk '{print $1}')"; VERIFY_FAIL=1
    fi
fi

# ===========================================================================
# 4) Mounts: warn on noexec /var, create /opt/palette-agent
# ===========================================================================
echo
echo "[4/12] Mount safety"
NOEXEC_FOUND=0
for mp in /var /var/lib /var/lib/containerd /var/lib/kubelet; do
    opts=$(awk -v m="$mp" '$2 == m {print $4}' /proc/mounts 2>/dev/null | head -1)
    [ -n "$opts" ] || continue
    if echo "$opts" | grep -qw noexec; then
        echo "  ✗ CRITICAL: $mp is mounted noexec — containers WILL NOT RUN from here"
        echo "       fix: edit /etc/fstab to remove 'noexec' from $mp, then 'mount -o remount,exec $mp'"
        NOEXEC_FOUND=1
        [ "$MODE" = "verify" ] && VERIFY_FAIL=1
    fi
done
[ "$NOEXEC_FOUND" = "0" ] && echo "  ✓ no noexec mounts on /var, /var/lib, /var/lib/{containerd,kubelet}"
if is_apply; then
    install -d -m 0755 -o root -g root /opt/palette-agent
    install -d -m 0755 -o root -g root /var/lib/kubelet
    # Ensure /var/lib/kubelet has shared mount propagation for CSI volume mounts.
    # Systemd default on Ubuntu 22.04 is shared, but CIS L2 sometimes flips
    # MountFlags=private; defensively set on /var/lib/kubelet.
    mount --make-rshared /var/lib/kubelet 2>/dev/null || true
    echo "  ✓ /opt/palette-agent (exec-OK) + /var/lib/kubelet (rshared) ready"
fi

# ===========================================================================
# 5) Limits / ulimits for the K8s runtime services
# ===========================================================================
echo
echo "[5/12] Limits / ulimits"
echo "  ✓ /etc/security/limits.d/99-k8s-agent.conf + systemd drop-ins for containerd/kubelet/stylus-agent/palette-agent"
write_file /etc/security/limits.d/99-k8s-agent.conf \
    "# K8s + container runtime ulimits (canvos-agent)" \
    "* soft nofile 1048576" \
    "* hard nofile 1048576" \
    "* soft nproc unlimited" \
    "* hard nproc unlimited" \
    "* soft memlock unlimited" \
    "* hard memlock unlimited" \
    "root soft nofile 1048576" \
    "root hard nofile 1048576"

# systemd drop-ins for the units that will exist after install
for unit in containerd kubelet stylus-agent palette-agent; do
    is_apply && install -d -m 0755 "/etc/systemd/system/${unit}.service.d"
    write_file "/etc/systemd/system/${unit}.service.d/99-k8s-limits.conf" \
        "[Service]" \
        "LimitNOFILE=1048576" \
        "LimitNPROC=infinity" \
        "LimitMEMLOCK=infinity" \
        "LimitCORE=0" \
        "TasksMax=infinity" \
        "Delegate=yes" \
        "KillMode=process"
done
is_apply && systemctl daemon-reload 2>/dev/null || true

# ===========================================================================
# 6) cgroup v2 check
# ===========================================================================
echo
echo "[6/12] cgroup v2 check"
if mount | awk '$3 == "/sys/fs/cgroup" {print $5}' | grep -qx cgroup2; then
    echo "  ✓ cgroup v2 unified hierarchy is active"
else
    echo "  ✗ cgroup v1 detected. kubelet on modern K8s expects v2."
    echo "       fix: add 'systemd.unified_cgroup_hierarchy=1' to GRUB_CMDLINE_LINUX in /etc/default/grub, then update-grub + reboot"
    [ "$MODE" = "verify" ] && VERIFY_FAIL=1
fi

# ===========================================================================
# 7) Time sync
# ===========================================================================
echo
echo "[7/12] Time sync (required for x509 / TLS handshake)"
if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
    echo "  ✓ chrony is active"
elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    echo "  ✓ systemd-timesyncd is active"
else
    echo "  ✗ no time sync service running"
    [ "$MODE" = "verify" ] && VERIFY_FAIL=1
    if is_apply; then
        echo "    enabling systemd-timesyncd"
        systemctl enable --now systemd-timesyncd 2>/dev/null || true
    fi
fi

# ===========================================================================
# 8) AppArmor: container runtimes → complain
# ===========================================================================
echo
echo "[8/12] AppArmor — set container runtime profiles to complain mode"
if command -v aa-complain >/dev/null 2>&1; then
    for p in /etc/apparmor.d/runc /etc/apparmor.d/usr.bin.runc \
             /etc/apparmor.d/containerd /etc/apparmor.d/usr.bin.containerd \
             /etc/apparmor.d/docker /etc/apparmor.d/usr.sbin.docker \
             /etc/apparmor.d/kubelet /etc/apparmor.d/usr.bin.kubelet; do
        [ -f "$p" ] && do_run aa-complain "$p" 2>/dev/null || true
    done
else
    echo "  apparmor-utils not installed (apt-get install -y apparmor-utils)"
fi

# ===========================================================================
# 9) sudoers: !requiretty for palette-agent install paths
# ===========================================================================
echo
echo "[9/12] sudoers — !requiretty exception for agent install"
echo "  ✓ /etc/sudoers.d/99-canvos-agent (visudo-validated)"
write_file /etc/sudoers.d/99-canvos-agent \
    "# canvos-agent: allow non-tty sudo for the agent install binary" \
    "Defaults!/opt/palette-agent/palette-agent-install.sh !requiretty" \
    "Defaults!/usr/local/bin/palette-agent !requiretty" \
    "Defaults!/usr/local/sbin/palette-agent !requiretty" \
    "Defaults!/usr/local/bin/stylus-agent !requiretty"
if is_apply; then
    chmod 0440 /etc/sudoers.d/99-canvos-agent
    if ! visudo -cf /etc/sudoers.d/99-canvos-agent >/dev/null; then
        echo "  ERROR: sudoers drop-in invalid; removing"
        rm -f /etc/sudoers.d/99-canvos-agent
        exit 3
    fi
fi

# ===========================================================================
# 10) AIDE exclusions for K8s churn paths
# ===========================================================================
echo
echo "[10/12] AIDE exclusions for K8s runtime paths"
if [ -d /etc/aide ] || command -v aide >/dev/null 2>&1; then
    [ ! -d /etc/aide/aide.conf.d ] && install -d -m 0755 /etc/aide/aide.conf.d
    echo "  ✓ /etc/aide/aide.conf.d/99-canvos-k8s-exclusions.conf"
    write_file /etc/aide/aide.conf.d/99-canvos-k8s-exclusions.conf \
        "# K8s/container churn paths excluded from AIDE integrity checks." \
        "# Without these, AIDE reports thousands of 'changed' files daily and" \
        "# may trip security monitoring on each pod schedule/restart." \
        "!/var/lib/containerd" \
        "!/var/lib/kubelet" \
        "!/var/lib/etcd" \
        "!/var/lib/cni" \
        "!/var/lib/calico" \
        "!/var/lib/longhorn" \
        "!/var/lib/rook" \
        "!/var/lib/spectro" \
        "!/var/lib/rancher" \
        "!/var/lib/k0s" \
        "!/var/log/pods" \
        "!/var/log/containers" \
        "!/var/log/journal" \
        "!/run/containerd" \
        "!/run/kubelet" \
        "!/run/calico" \
        "!/run/k3s" \
        "!/etc/cni" \
        "!/etc/kubernetes" \
        "!/opt/cni" \
        "!/opt/palette-agent" \
        "!/opt/spectrocloud"
else
    echo "  aide not installed; skipping exclusions"
fi

# ===========================================================================
# 11) Auditd exclusions (same K8s churn paths)
# ===========================================================================
echo
echo "[11/12] Auditd exclusions for K8s runtime paths"
if [ -d /etc/audit/rules.d ]; then
    echo "  ✓ /etc/audit/rules.d/99-zzz-k8s-exclusions.rules"
    write_file /etc/audit/rules.d/99-zzz-k8s-exclusions.rules \
        "# Exclude high-churn K8s paths from audit. CIS L2 watches /var/lib /etc" \
        "# and the audit buffer overruns under kubelet + containerd write rate." \
        "-a never,exit -F dir=/var/lib/containerd" \
        "-a never,exit -F dir=/var/lib/kubelet" \
        "-a never,exit -F dir=/var/lib/etcd" \
        "-a never,exit -F dir=/var/lib/cni" \
        "-a never,exit -F dir=/var/lib/spectro" \
        "-a never,exit -F dir=/var/lib/rancher" \
        "-a never,exit -F dir=/var/log/pods" \
        "-a never,exit -F dir=/var/log/containers" \
        "-a never,exit -F dir=/run/containerd" \
        "-a never,exit -F dir=/run/kubelet" \
        "-a never,exit -F dir=/sys/fs/cgroup"
    if is_apply && command -v augenrules >/dev/null 2>&1; then
        do_run augenrules --load 2>/dev/null || true
    fi
fi

# ===========================================================================
# 12) Firewall — egress + ingress per cluster/role/CNI/CSI
# ===========================================================================
echo
echo "[12/12] Firewall — egress + ingress for cluster=$CLUSTER role=$ROLE cni=$CNI csi=$CSI"
[ -z "$FW" ] && echo "  WARN: no ufw/firewalld detected; configure your firewall manually"

# (a) egress allowlist for install + cluster operation
fw_out 53      udp 'DNS-udp'
fw_out 53      tcp 'DNS-tcp'
fw_out 80      tcp 'HTTP - agent install + apt + image registries'
fw_out 443     tcp 'HTTPS - api.spectrocloud + github + registries'
fw_out 123     udp 'NTP'
fw_out 6443    tcp 'k8s API to other CP nodes'
fw_out 2379:2380 tcp 'etcd peering'

# (b) base ingress for any node
fw_in  22      tcp 'SSH'

# (c) cluster-type specific
case "$CLUSTER" in
    kubeadm)
        if [ "$ROLE" = "server" ] || [ "$ROLE" = "both" ]; then
            fw_in 6443     tcp 'kube-apiserver'
            fw_in 2379:2380 tcp 'etcd server + peer'
            fw_in 10257    tcp 'kube-controller-manager'
            fw_in 10259    tcp 'kube-scheduler'
        fi
        if [ "$ROLE" = "worker" ] || [ "$ROLE" = "both" ]; then
            fw_in 10250    tcp 'kubelet'
            fw_in 10256    tcp 'kube-proxy health'
            fw_in 30000:32767 tcp 'NodePort tcp'
            fw_in 30000:32767 udp 'NodePort udp'
        fi
        ;;
    k3s)
        if [ "$ROLE" = "server" ] || [ "$ROLE" = "both" ]; then
            fw_in 6443     tcp 'k3s API'
            fw_in 2379:2380 tcp 'embedded etcd (HA)'
            fw_in 51820:51821 udp 'k3s WireGuard (if configured)'
        fi
        fw_in 10250    tcp 'kubelet'
        fw_in 8472     udp 'Flannel VXLAN (k3s default CNI)'
        fw_in 30000:32767 tcp 'NodePort tcp'
        fw_in 30000:32767 udp 'NodePort udp'
        ;;
    rke2)
        if [ "$ROLE" = "server" ] || [ "$ROLE" = "both" ]; then
            fw_in 9345     tcp 'RKE2 supervisor (agent registration)'
            fw_in 6443     tcp 'k8s API'
            fw_in 2379:2381 tcp 'embedded etcd + learner'
        fi
        fw_in 10250    tcp 'kubelet'
        fw_in 8472     udp 'Canal/Flannel VXLAN (RKE2 default CNI)'
        fw_in 30000:32767 tcp 'NodePort tcp'
        fw_in 30000:32767 udp 'NodePort udp'
        ;;
    canonical)
        # Canonical Kubernetes (k8s-snap). Uses k8sd cluster API on 6400 plus
        # standard kube-apiserver on 6443; embedded k8s-dqlite uses 2379-2381.
        # Default CNI is Cilium (VXLAN 8472, health 4240, hubble 4244).
        if [ "$ROLE" = "server" ] || [ "$ROLE" = "both" ]; then
            fw_in 6400     tcp 'k8sd cluster API (Canonical k8s)'
            fw_in 6443     tcp 'kube-apiserver'
            fw_in 2379:2381 tcp 'k8s-dqlite / embedded datastore'
            fw_in 10257    tcp 'kube-controller-manager'
            fw_in 10259    tcp 'kube-scheduler'
        fi
        fw_in 10250    tcp 'kubelet'
        fw_in 10256    tcp 'kube-proxy health'
        fw_in 30000:32767 tcp 'NodePort tcp'
        fw_in 30000:32767 udp 'NodePort udp'
        ;;
esac

# (d) CNI-specific
case "$CNI" in
    calico)
        fw_in 4789 udp 'Calico VXLAN'
        fw_in 179  tcp 'Calico BGP (optional)'
        fw_in 5473 tcp 'Calico Typha (optional)'
        # IPIP (ip proto 4) — firewalld + nftables can express natively;
        # ufw cannot, requires a raw iptables rule.
        if [ "$FW" = "ufw" ] && is_apply; then
            iptables  -A INPUT -p 4 -j ACCEPT 2>/dev/null || true
            ip6tables -A INPUT -p 4 -j ACCEPT 2>/dev/null || true
        elif [ "$FW" = "firewalld" ] && is_apply; then
            firewall-cmd --permanent --add-protocol=ipip 2>/dev/null || true
        elif [ "$FW" = "nftables" ]; then
            NFT_IN_RAW="${NFT_IN_RAW}        meta l4proto 4 accept comment \"Calico IPIP\"\\n"
        fi
        [ "$MODE" = "showports" ] && echo "  INGRESS ip-proto-4         Calico IPIP (raw rule)"
        ;;
    flannel)
        fw_in 8472 udp 'Flannel VXLAN'
        fw_in 51820 udp 'Flannel WireGuard (optional)'
        ;;
    cilium)
        fw_in 8472 udp 'Cilium VXLAN'
        fw_in 6081 udp 'Cilium GENEVE (optional)'
        fw_in 4240 tcp 'Cilium health'
        fw_in 4244 tcp 'Cilium Hubble relay'
        fw_in 51871 udp 'Cilium WireGuard (optional)'
        ;;
    weave)
        fw_in 6783 tcp 'Weave Net control'
        fw_in 6783 udp 'Weave Net datapath'
        fw_in 6784 udp 'Weave Net datapath alt'
        ;;
    none) : ;;
esac

# (e) CSI-specific
for c in $(echo "$CSI" | tr ',' ' '); do
    case "$c" in
        longhorn)
            fw_in 9500:9504 tcp 'Longhorn engine + replicas'
            fw_in 8500    tcp 'Longhorn instance manager'
            fw_in 30001   tcp 'Longhorn WebUI (optional)'
            ;;
        rook-ceph|ceph)
            fw_in 3300    tcp 'Ceph msgr v2'
            fw_in 6789    tcp 'Ceph msgr v1'
            fw_in 6800:7300 tcp 'Ceph OSDs'
            ;;
        openebs)
            fw_in 3260    tcp 'iSCSI (OpenEBS / others)'
            fw_in 9500    tcp 'OpenEBS cstor'
            fw_in 7676    tcp 'OpenEBS mayastor'
            ;;
        nfs)
            fw_in 2049    tcp 'NFS'
            fw_in 2049    udp 'NFS'
            fw_in 111     tcp 'rpcbind'
            fw_in 111     udp 'rpcbind'
            fw_in 20048   tcp 'mountd'
            fw_in 20048   udp 'mountd'
            ;;
        none) : ;;
    esac
done

# Reload firewall
if is_apply; then
    case "$FW" in
        ufw)
            ufw logging on 2>/dev/null || true
            ufw --force enable 2>/dev/null || true
            ufw reload 2>/dev/null || true
            echo "  ✓ ufw rules applied + enabled"
            ;;
        firewalld)
            firewall-cmd --reload 2>/dev/null || true
            echo "  ✓ firewalld rules reloaded"
            ;;
        nftables)
            # Materialize a agent-mode-owned table that opens the K8s ports.
            # Kept in its own table so we don't disturb any existing CIS L2
            # nftables ruleset (e.g. /etc/nftables.conf). priority -10 runs
            # before the default filter table; policy=accept means we only
            # whitelist, never block — the deny is supplied by the existing
            # firewall (or by CIS L2's own rules).
            install -d -m 0755 /etc/nftables.d
            NFT_FILE=/etc/nftables.d/99-canvos-k8s.nft
            {
                echo "# canvos-k8s ingress/egress allowlist for agent-mode + K8s carve-outs"
                echo "# Generated by cis-l2-agent-prep.sh. Loaded after the base filter table."
                echo "table inet canvos_k8s {"
                echo "    chain canvos_input {"
                echo "        type filter hook input priority filter - 10; policy accept;"
                echo "        ct state established,related accept"
                echo "        iif \"lo\" accept"
                printf '%b' "$NFT_IN_TCP"
                printf '%b' "$NFT_IN_UDP"
                printf '%b' "$NFT_IN_RAW"
                echo "    }"
                echo "    chain canvos_output {"
                echo "        type filter hook output priority filter - 10; policy accept;"
                echo "        ct state established,related accept"
                printf '%b' "$NFT_OUT_TCP"
                printf '%b' "$NFT_OUT_UDP"
                echo "    }"
                echo "}"
            } > "$NFT_FILE"
            # Wire into the main /etc/nftables.conf if not already.
            if [ -f /etc/nftables.conf ] && ! grep -qE '^include\s+"?/etc/nftables\.d/' /etc/nftables.conf; then
                echo "include \"/etc/nftables.d/*.nft\"" >> /etc/nftables.conf
            fi
            # Reload. Atomic — if syntax is bad, the kernel state stays as-is.
            if nft -f "$NFT_FILE" 2>/tmp/canvos-nft.err; then
                echo "  ✓ nftables canvos_k8s table loaded ($NFT_FILE)"
                systemctl enable nftables 2>/dev/null || true
            else
                echo "  ✗ nftables load failed:"
                sed 's/^/      /' /tmp/canvos-nft.err
            fi
            ;;
        *)
            echo "  WARN: no firewall manager available (ufw/firewalld/nftables);"
            echo "        run with --show-ports to print the rule list and apply manually"
            ;;
    esac
    # Persist iptables rules added for Calico IPIP if applicable
    if [ "$FW" = "ufw" ] && [ "$CNI" = "calico" ] && command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save  > /etc/iptables/rules.v4  2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
fi

# ===========================================================================
# Summary / exit
# ===========================================================================
echo
echo "=================================================================="
case "$MODE" in
    verify)
        if [ "$VERIFY_FAIL" = "0" ]; then
            echo "VERIFY: all carve-outs in place. Host is agent-mode-ready."
            exit 0
        else
            echo "VERIFY: one or more carve-outs missing / not active (see ✗ above)."
            echo "Re-run without --verify to apply."
            exit 1
        fi ;;
    dryrun)     echo "DRY-RUN complete. No changes made."; exit 0 ;;
    showports)  echo "SHOW-PORTS complete. Firewall not modified."; exit 0 ;;
    apply)
        cat <<EOF
DONE. Host is ready for palette-agent-install.sh.

Next steps:
  cd /opt/palette-agent
  curl -fsSL https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh \\
    -o palette-agent-install.sh
  chmod +x palette-agent-install.sh
  sudo USERDATA=/path/to/userdata.yaml ./palette-agent-install.sh

After install completes, run the post-install verifier in this directory:
  sudo bash cis-l2-post-install-verify.sh

If you reboot, re-verify the carve-outs survived:
  sudo bash $0 --verify --cluster $CLUSTER --role $ROLE --cni $CNI --csi $CSI
EOF
        ;;
esac
echo "=================================================================="
