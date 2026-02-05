# Agent Mode

## Prerequisites

Before you begin, ensure you have the following installed:

- `bash`
- `systemd`
- `rsync`
- `jq`
- `zstd`
- `conntrack` (required for `PXKE` clusters)
- `systemd-networkd` (required if palette is managing networks)
- `systemd-resolved` (required if palette is managing DNS)
- `systemd-timesyncd` (required if palette is managing NTP)
- `rsyslog` (required for audit logs)
- `nfs-common` (required for zot) in Ubuntu. Equivalent packages for other OS - `nfs-utils` for RHEL, `nfs-client` for Opensuse

To enable FIPS modules on Ubuntu - refer to the documentation [here](https://ubuntu.com/tutorials/using-the-ubuntu-pro-client-to-enable-fips#1-overview)

To enable FIPS mode of RHEL - refer to the documentation [here](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/security_hardening/switching-rhel-to-fips-mode_security-hardening)

Refer to respective Operating system documentation for enabling FIPS mode.

## Quick Start

To quickly install the agent, run the following command:

```bash
curl -Ls https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | bash
```

## Usage

### Specify Userdata

Userdata can be a URL or a file path.

```bash
curl -Ls https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | USERDATA=https://xxx/userdata bash
# or
curl -Ls https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | USERDATA=/path/to/userdata bash
```

### Specify Palette version

```bash
curl -Ls https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | VERSION=v4.5.0 bash
```

## FIPS(Work In Progress)

```bash
curl -Ls https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install-fips.sh | bash
```

## Userdata

Refer to [Palette Agent Parameters Documentation](https://docs.spectrocloud.com/clusters/edge/edge-configuration/installer-reference/#palette-agent-parameters) for more details.

## Examples

Here are some examples of how to use the install script on different platforms.

- [MAAS](examples/maas/README.md)
- [Lima](examples/lima/README.md)

## Uninstall
To remove all the artifacts related to agent-mode setup on the host run the script 

```bash
curl -Ls https://github.com/spectrocloud/agent-mode/releases/latest/download/spectro-uninstall-linux-amd64.sh | bash
```

## Development

### Build install script

```bash
earthly +install-script \
    --IMAGE_REPO=us-docker.pkg.dev/palette-images/edge \
    --AGENT_URL_PREFIX=https://github.com/spectrocloud/agent-mode/releases/download/v4.5.0-rc5 \
    --PE_VERSION=v4.5.0-rc7
```
