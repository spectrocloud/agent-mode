#!/bin/bash
set -ex
if [ -f /etc/spectro/environment ]; then
    . /etc/spectro/environment
fi

SENTINEL_FILE="${STYLUS_ROOT}/opt/spectrocloud/state/setup_done"

if [ -f ${SENTINEL_FILE} ]; then
    echo "Setup already done"
    exit
fi

export PATH=$PATH:/var/lib/spectro/stylus/opt/spectrocloud/bin
edge-agent install --source dir:/var/lib/spectro/stylus --config /var/lib/spectro/userdata

# reload the environment on first boot
if [ -f /etc/spectro/environment ]; then
    . /etc/spectro/environment
fi

touch ${SENTINEL_FILE}
systemctl daemon-reload
systemctl restart spectro-edge-agent-start || true
systemctl restart spectro-edge-agent-initramfs || true
systemctl restart spectro-edge-agent-boot || true
systemctl restart spectro-edge-agent-network || true
systemctl restart spectro-edge-agent-bootstrap || true
