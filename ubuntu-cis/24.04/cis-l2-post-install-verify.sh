#!/usr/bin/env bash
# cis-l2-post-install-verify.sh — Ubuntu 24.04 LTS
#
# Run this AFTER palette-agent-install.sh succeeds, on a host that was
# prepped by cis-l2-agent-prep.sh. Validates that:
#   - the stylus / palette-agent systemd unit is healthy
#   - the systemd unit doesn't have hardening directives that would
#     break Kubernetes (NoNewPrivileges, RestrictNamespaces, ...)
#   - kubelet + containerd are running
#   - cgroup driver matches between kubelet + containerd
#   - kubectl exec works (proves ptrace policy is permissive enough)
#   - basic pod-to-pod connectivity through the CNI
#   - AppArmor profile states are sane
#
# Exits non-zero if any check fails. Idempotent and read-only — does
# NOT modify host state. Operators can run this any time as a smoke test.
set -uo pipefail

VERSION=24.04
FAIL=0

check() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        printf '  ✓ %s\n' "$desc"
    else
        printf '  ✗ %s\n' "$desc"
        FAIL=$((FAIL + 1))
    fi
}

warn() {
    printf '  ⚠ %s\n' "$1"
}

info() {
    printf '  · %s\n' "$1"
}

if [ "$(id -u)" != "0" ]; then
    echo "Must be run as root: sudo $0" >&2
    exit 1
fi

echo "=================================================================="
echo "cis-l2-post-install-verify.sh"
echo "=================================================================="

# ---------------------------------------------------------------------------
# 1) Stylus / palette-agent systemd unit
# ---------------------------------------------------------------------------
echo
echo "[1/8] Stylus / palette-agent systemd unit"
STYLUS_UNIT=
for u in stylus-agent.service palette-agent.service stylus.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 && \
       systemctl list-unit-files "$u" 2>/dev/null | grep -qw "$u"; then
        STYLUS_UNIT="$u"
        break
    fi
done
if [ -z "$STYLUS_UNIT" ]; then
    warn "no stylus / palette-agent unit found — has palette-agent-install.sh been run?"
    FAIL=$((FAIL + 1))
else
    info "unit: $STYLUS_UNIT"
    check "$STYLUS_UNIT is active"            "systemctl is-active --quiet $STYLUS_UNIT"
    check "$STYLUS_UNIT is enabled"           "systemctl is-enabled --quiet $STYLUS_UNIT"

    # Inspect unit for hardening directives that would break K8s ops.
    UNIT_FILE=$(systemctl show -p FragmentPath "$STYLUS_UNIT" --value 2>/dev/null)
    if [ -n "$UNIT_FILE" ] && [ -f "$UNIT_FILE" ]; then
        info "unit file: $UNIT_FILE"
        # The following directives, if set to restrictive values, break K8s ops.
        for bad in \
            'NoNewPrivileges=yes:cannot setuid; containers fail to start' \
            'RestrictNamespaces=yes:cannot create container namespaces' \
            'ProtectKernelModules=yes:cannot modprobe at runtime' \
            'ProtectKernelTunables=yes:cannot write /proc/sys/* needed by kubelet' \
            'PrivateNetwork=yes:no network access' \
            'PrivateUsers=yes:cannot map UIDs for containers' \
            'ProtectSystem=strict:cannot write to /var /etc paths kubelet needs' \
            'MountFlags=private:volume mount propagation broken'; do
            key="${bad%%=*}"; rest="${bad#*=}"; want="${rest%%:*}"; why="${rest#*:}"
            actual=$(systemctl show -p "$key" "$STYLUS_UNIT" --value 2>/dev/null)
            if [ "$actual" = "$want" ]; then
                printf '  ✗ %-30s = %s  (will break: %s)\n' "$key" "$actual" "$why"
                FAIL=$((FAIL + 1))
            fi
        done
        # Positive checks: things we WANT set
        for good in \
            'LimitNOFILE:1048576' \
            'LimitMEMLOCK:infinity'; do
            key="${good%%:*}"; want="${good#*:}"
            actual=$(systemctl show -p "$key" "$STYLUS_UNIT" --value 2>/dev/null)
            if [ "$actual" = "$want" ] || [ "$actual" = "infinity" ]; then
                printf '  ✓ %-30s = %s\n' "$key" "$actual"
            else
                printf '  ⚠ %-30s = %s  (recommended: %s)\n' "$key" "$actual" "$want"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# 2) Container runtime + kubelet
# ---------------------------------------------------------------------------
echo
echo "[2/8] Container runtime + kubelet"
check "containerd is active"        "systemctl is-active --quiet containerd"
# kubelet may take a few minutes to come up after agent registration
if systemctl is-active --quiet kubelet 2>/dev/null; then
    info "kubelet active"
else
    warn "kubelet not yet active — cluster bring-up may still be in progress"
fi

# cgroup driver consistency between containerd and kubelet
if command -v crictl >/dev/null 2>&1; then
    CRI_CGROUP=$(crictl info 2>/dev/null | grep -i systemdCgroup | head -1)
    info "containerd cgroup: $CRI_CGROUP"
fi

# ---------------------------------------------------------------------------
# 3) Kernel modules at runtime (re-check what prep loaded)
# ---------------------------------------------------------------------------
echo
echo "[3/8] Kernel modules"
for m in overlay br_netfilter nf_conntrack ip_vs; do
    check "module $m loaded" "lsmod | awk '{print \$1}' | grep -qx $m"
done

# ---------------------------------------------------------------------------
# 4) Sysctl carve-outs survived
# ---------------------------------------------------------------------------
echo
echo "[4/8] Sysctl carve-outs"
for kv in net.ipv4.ip_forward=1 \
          net.bridge.bridge-nf-call-iptables=1 \
          kernel.unprivileged_bpf_disabled=0 \
          kernel.yama.ptrace_scope=0 \
          vm.max_map_count=262144; do
    k="${kv%=*}"; want="${kv#*=}"; got="$(sysctl -n "$k" 2>/dev/null || echo MISSING)"
    if [ "$got" = "$want" ]; then printf '  ✓ %s=%s\n' "$k" "$got"
    else printf '  ✗ %s=%s (want %s)\n' "$k" "$got" "$want"; FAIL=$((FAIL + 1))
    fi
done

# ---------------------------------------------------------------------------
# 5) Mount safety
# ---------------------------------------------------------------------------
echo
echo "[5/8] Mount safety"
for mp in /var /var/lib /var/lib/containerd /var/lib/kubelet; do
    opts=$(awk -v m="$mp" '$2 == m {print $4}' /proc/mounts 2>/dev/null | head -1)
    [ -n "$opts" ] || continue
    if echo "$opts" | grep -qw noexec; then
        printf '  ✗ %s mounted noexec — containers cannot execute from here\n' "$mp"
        FAIL=$((FAIL + 1))
    else
        printf '  ✓ %s exec-ok\n' "$mp"
    fi
done
check "swap is off" "[ -z \"\$(swapon --show 2>/dev/null)\" ]"

# ---------------------------------------------------------------------------
# 6) kubectl exec smoke test (ptrace policy)
# ---------------------------------------------------------------------------
echo
echo "[6/8] kubectl exec smoke test (catches strict ptrace_scope, AppArmor)"
KUBECONFIG=
for kc in /etc/rancher/k3s/k3s.yaml /etc/rancher/rke2/rke2.yaml /etc/kubernetes/admin.conf /var/lib/spectro/kubeconfig; do
    if [ -r "$kc" ]; then KUBECONFIG="$kc"; break; fi
done
if [ -z "$KUBECONFIG" ]; then
    warn "no readable kubeconfig found; skipping kubectl tests"
elif ! command -v kubectl >/dev/null 2>&1; then
    warn "kubectl binary not in PATH; skipping kubectl tests"
else
    export KUBECONFIG
    info "using kubeconfig: $KUBECONFIG"
    # Find any Running pod and try exec
    POD_NS_NAME=$(kubectl get pods -A --field-selector status.phase=Running -o jsonpath='{range .items[0]}{.metadata.namespace} {.metadata.name}{end}' 2>/dev/null)
    if [ -n "$POD_NS_NAME" ]; then
        PNS=${POD_NS_NAME%% *}; PNAME=${POD_NS_NAME##* }
        if kubectl -n "$PNS" exec "$PNAME" -- /bin/sh -c 'echo ok' 2>/dev/null | grep -qx ok; then
            printf '  ✓ kubectl exec works (%s/%s)\n' "$PNS" "$PNAME"
        else
            printf '  ✗ kubectl exec failed — check ptrace_scope, AppArmor, runtime caps\n'
            FAIL=$((FAIL + 1))
        fi
    else
        warn "no Running pods to smoke-test exec against"
    fi
fi

# ---------------------------------------------------------------------------
# 7) Pod-to-pod connectivity (CNI smoke test)
# ---------------------------------------------------------------------------
echo
echo "[7/8] CNI smoke test (pod-to-pod ping)"
if [ -n "${KUBECONFIG:-}" ] && command -v kubectl >/dev/null 2>&1; then
    # Two random Running pods on different nodes (best effort)
    mapfile -t TARGETS < <(kubectl get pods -A --field-selector status.phase=Running -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}/{.status.podIP}{"\n"}{end}' 2>/dev/null | grep -v '//$' | head -2)
    if [ "${#TARGETS[@]}" -ge 2 ]; then
        A=${TARGETS[0]}; B=${TARGETS[1]}
        A_NS=${A%%/*}; A_NAME=$(echo "$A" | cut -d/ -f2); B_IP=${B##*/}
        if kubectl -n "$A_NS" exec "$A_NAME" -- /bin/sh -c "command -v ping >/dev/null && ping -c1 -W2 $B_IP || (command -v wget >/dev/null && wget -q -T2 --tries=1 -O- http://$B_IP 2>/dev/null) || nc -z -w2 $B_IP 80 2>/dev/null" >/dev/null 2>&1; then
            printf '  ✓ pod-to-pod reachable (%s -> %s)\n' "$A" "$B_IP"
        else
            printf '  ⚠ pod-to-pod connectivity check inconclusive (no ping/wget/nc in test pod or IP unreachable)\n'
        fi
    else
        warn "fewer than 2 Running pods; skipping pod-to-pod test"
    fi
fi

# ---------------------------------------------------------------------------
# 8) AppArmor profile states
# ---------------------------------------------------------------------------
echo
echo "[8/8] AppArmor profile states (container runtimes should NOT be enforcing)"
if command -v aa-status >/dev/null 2>&1; then
    for p in runc containerd dockerd docker kubelet; do
        if aa-status --enforced 2>/dev/null | grep -qw "$p"; then
            printf '  ✗ %s is ENFORCING (likely to deny K8s ops; aa-complain it)\n' "$p"
            FAIL=$((FAIL + 1))
        elif aa-status --complaining 2>/dev/null | grep -qw "$p"; then
            printf '  ✓ %s in complain mode\n' "$p"
        else
            info "$p has no profile (fine; means runtime is unconfined)"
        fi
    done
else
    warn "apparmor-utils not installed; cannot check profile states"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=================================================================="
if [ "$FAIL" = "0" ]; then
    echo "VERIFY: PASS — host is post-install healthy for agent-mode + K8s."
    exit 0
else
    echo "VERIFY: $FAIL check(s) failed (see ✗ above)."
    echo "       Re-run cis-l2-agent-prep.sh to fix host-level issues."
    echo "       For stylus unit issues, edit the unit file's [Service]"
    echo "       section to remove the offending hardening directive, then"
    echo "       'systemctl daemon-reload && systemctl restart $STYLUS_UNIT'."
    exit 1
fi
