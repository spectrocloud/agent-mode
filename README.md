# agent-mode

## Prerequisites

- `bash`
- `systemd`
- `rsync`
- `jq`
- `zstd`
- `conntrack` (for `pxke` clusters only)

## Quick Start

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

## Examples

Here are some examples of how to use the install script on different platforms.

### MAAS

[cloudinit](examples/maas.yml)

### AWS

TODO

## Development

### Build install script

```bash
earthly +install-script \
    --IMAGE_REPO=us-docker.pkg.dev/palette-images/edge \
    --AGENT_URL_PREFIX=https://github.com/spectrocloud/agent-mode/releases/download/v4.5.0-rc5 \
    --PE_VERSION=v4.5.0-rc7
```
