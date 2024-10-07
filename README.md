# agent-mode

## Prerequisites

- `bash`
- `rsync`
- `jq`
- `conntrack` (for `pxke` clusters only)

## Quick Start

```bash
curl https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | bash
```

## Usage

### specify userdata

Userdata can be a URL or a file path.

```bash
curl https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | USERDATA=https://xxx/userdata bash
# or
curl https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | USERDATA=/path/to/userdata bash
```

### specify palette version

```bash
curl https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh | VERSION=v4.5.0 bash
```

## Development

### Build install script

```bash
earthly +install-script \
    --IMAGE_REPO=us-docker.pkg.dev/palette-images/edge \
    --AGENT_URL_PREFIX=https://github.com/spectrocloud/agent-mode/releases/download/v4.5.0-rc5 \
    --PE_VERSION=v4.5.0-rc7
```
