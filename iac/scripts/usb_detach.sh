#!/bin/bash
# Run on the Proxmox node. Args: VMID SLOT
set -euo pipefail
VMID="${1:?vmid}"
SLOT="${2:-usb0}"
qm set "$VMID" -delete "$SLOT" || true
echo "detached $SLOT from VM $VMID"
