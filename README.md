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
