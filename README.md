# Agent Mode

## Prerequisites

Before you begin, ensure you have the following installed:

- `bash`
- `systemd`
- `rsync`
- `jq`
- `zstd`
- `conntrack` (for `pxke` clusters only)

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

## Userdata

Refer to [Palette Agent Parameters Documentation](https://docs.spectrocloud.com/clusters/edge/edge-configuration/installer-reference/#palette-agent-parameters) for more details.

## Examples

Here are some examples of how to use the install script on different platforms.

### MAAS

Use [maas.yml](examples/maas.yml) as cloudinit to provision your machine.

> **Note:** You might need to modify the cloudinit with your own userdata.

## Development

### Build install script

```bash
earthly +install-script \
    --IMAGE_REPO=us-docker.pkg.dev/palette-images/edge \
    --AGENT_URL_PREFIX=https://github.com/spectrocloud/agent-mode/releases/download/v4.5.0-rc5 \
    --PE_VERSION=v4.5.0-rc7
```
