# `ubuntu-cis/22.04/` — CIS L2 agent-mode prep, Ubuntu 22.04 LTS

See [`../README.md`](../README.md) for the full design, flag matrix, port table per cluster/CNI/CSI, and the CIS rule deviation table.

## Files in this directory

| File | Purpose |
|---|---|
| `cis-l2-agent-prep.sh` | Runs BEFORE `palette-agent-install.sh` |
| `cis-l2-post-install-verify.sh` | Runs AFTER agent install + initial cluster bring-up |

## Quick start — Cilium+OpenEBS k3s server on 22.04

```bash
# Phase 1: CIS L2 hardening
sudo pro attach <token>
sudo pro enable usg
sudo apt-get install -y usg
sudo usg fix cis_level2_server
sudo reboot

# Phase 2: Copy scripts somewhere exec-OK (NOT /tmp on hardened hosts)
sudo mkdir -p /root/canvos-prep && cd /root/canvos-prep
sudo curl -fsSLO https://raw.githubusercontent.com/spectrocloud/agent-mode/PE-8774/ubuntu-cis/22.04/cis-l2-agent-prep.sh
sudo curl -fsSLO https://raw.githubusercontent.com/spectrocloud/agent-mode/PE-8774/ubuntu-cis/22.04/cis-l2-post-install-verify.sh
sudo chmod +x *.sh

# K8s carve-outs
sudo ./cis-l2-agent-prep.sh \
    --cluster k3s \
    --role server \
    --cni cilium \
    --csi openebs

sudo reboot
sudo /root/canvos-prep/cis-l2-agent-prep.sh --verify --cluster k3s --role server --cni cilium --csi openebs

# Phase 3: agent install (prep created /opt/palette-agent for this)
cd /opt/palette-agent
sudo curl -fsSL https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh \
    -o palette-agent-install.sh
sudo chmod +x palette-agent-install.sh
sudo USERDATA=/path/to/userdata.yaml ./palette-agent-install.sh

# Phase 4: post-install smoke test
sudo /root/canvos-prep/cis-l2-post-install-verify.sh
```

> **Where to put the scripts:** see the [top-level README "Where to put the scripts on the host"](../README.md#where-to-put-the-scripts-on-the-host) for the full list of safe / unsafe paths under CIS L2. Short version: use `/root/`, never `/tmp` or `/var/tmp` on hosts where those are separate partitions (CIS rule 1.1.2.4 mounts them `noexec`).

## 22.04-specific notes

- Kernel 5.15 default. All `ip_vs*`, `br_netfilter`, `nf_conntrack`, `vxlan` are built-in or modules. No DKMS needed.
- AppArmor profiles include `/etc/apparmor.d/docker` (Docker Engine ships its own) in addition to `runc` and `containerd`. The script tries all three.
- `libpam-cracklib` is still in the archive on 22.04. CIS L2 may enable it; the script doesn't touch PAM. If your subsequent operator-driven `passwd` calls fail under cracklib, override via `pam-auth-update --disable cracklib` after deploy.
- cgroup v1 is still common on stock 22.04 cloud images. If `cis-l2-agent-prep.sh` reports cgroup v1 in section 6, edit `/etc/default/grub`:
  ```
  GRUB_CMDLINE_LINUX_DEFAULT="... systemd.unified_cgroup_hierarchy=1"
  ```
  then `sudo update-grub && sudo reboot`.
- `ufw` on 22.04 uses the iptables backend (not nftables) unless explicitly migrated. The script's `ufw allow` works regardless; the IPIP rule for Calico uses `iptables -A INPUT -p 4 -j ACCEPT` and persists via `iptables-save > /etc/iptables/rules.v4`.

## Common operator questions

Same as the 24.04 README — see [`../24.04/README.md`](../24.04/README.md#common-operator-questions).
