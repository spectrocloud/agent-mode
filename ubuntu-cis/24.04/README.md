# `ubuntu-cis/24.04/` — CIS L2 agent-mode prep, Ubuntu 24.04 LTS

See [`../README.md`](../README.md) for the full design, flag matrix, port table per cluster/CNI/CSI, and the CIS rule deviation table.

## Files in this directory

| File | Purpose |
|---|---|
| `cis-l2-agent-prep.sh` | Runs BEFORE `palette-agent-install.sh`; applies the 12 sections of K8s carve-outs |
| `cis-l2-post-install-verify.sh` | Runs AFTER agent install + initial cluster bring-up; smoke tests the stylus unit, kubelet, sysctl survival, kubectl exec, CNI ping |

## Quick start — Calico+Longhorn worker on kubeadm

```bash
# Phase 1: CIS L2 hardening (customer's process)
sudo pro attach <token>
sudo pro enable usg
sudo apt-get install -y usg
sudo usg fix cis_level2_server      # 30-60 min, AIDE init dominates
sudo reboot

# Phase 2: Copy scripts somewhere exec-OK (NOT /tmp on hardened hosts)
sudo mkdir -p /root/canvos-prep && cd /root/canvos-prep
# scp from workstation, OR curl if outbound HTTPS to github is permitted:
sudo curl -fsSLO https://raw.githubusercontent.com/spectrocloud/agent-mode/PE-8774/ubuntu-cis/24.04/cis-l2-agent-prep.sh
sudo curl -fsSLO https://raw.githubusercontent.com/spectrocloud/agent-mode/PE-8774/ubuntu-cis/24.04/cis-l2-post-install-verify.sh
sudo chmod +x *.sh

# K8s carve-outs
sudo ./cis-l2-agent-prep.sh \
    --cluster kubeadm \
    --role both \
    --cni calico \
    --csi longhorn

sudo reboot                          # let modules-load + sysctl apply at boot

sudo /root/canvos-prep/cis-l2-agent-prep.sh --verify --cluster kubeadm --role both --cni calico --csi longhorn

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

## 24.04-specific notes

- Default cgroup hierarchy on 24.04 is v2 (unified). No grub edit needed unless something earlier flipped it back.
- AppArmor profile paths: `/etc/apparmor.d/runc`, `/etc/apparmor.d/containerd`. The 22.04 Docker profile (`/etc/apparmor.d/docker`) typically isn't present on stock 24.04; the script's existence check handles this.
- `libpam-cracklib` was removed upstream in 22.04+, so it never appears on 24.04. The script doesn't touch PAM.
- `nftables` is the default firewall backend (ufw uses nft under the hood). The script's `ufw allow` commands work transparently.
- Kernel 6.8 has native `ip_vs*` and `br_netfilter` support — no DKMS needed.
- Ubuntu 24.04 cloud images often enable zram swap via `zram-generator`. The script masks it as part of swap-off (`systemctl mask --now zram-generator.service dev-zram0.swap`).

## Common operator questions

**Q: Do I need to run prep before OR after CIS L2 fix?**
After. CIS L2 hardening enables the lockdowns; this script then carves out the K8s-required exceptions on top.

**Q: Can I re-run after a reboot?**
Yes — idempotent. Use `--verify` to just check, or re-`--apply` to be safe.

**Q: What if I change the cluster type or CNI later?**
Re-run with the new flags. Firewall rules are added cumulatively (ufw won't duplicate), but if you switch from e.g. `--cni calico` to `--cni flannel`, the old Calico ports stay allowed — manually `ufw delete allow 4789/udp` etc. if you want to tighten back.

**Q: What about the airgap install path (`sudo tar -xvf -C /`)?**
The script can't safely modify root mount options on a hardened host. Inspect the tarball's contents and confirm each top-level directory is writable on your image before extracting; remount with `exec` and writable any path that isn't.
