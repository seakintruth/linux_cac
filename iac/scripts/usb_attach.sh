#!/bin/bash
# Run on the Proxmox node. Args: VMID VENDOR:PRODUCT SLOT
set -euo pipefail
VMID="${1:?vmid}"
USB_ID="${2:?vendor:product}"
SLOT="${3:-usb0}"
LOCK="${USB_LOCK:-/var/lock/linux-cac-usb.lock}"

exec 9>"$LOCK"
flock -w 600 9

# Drop the slot from every other VM on this node first.
for conf in /etc/pve/qemu-server/*.conf; do
  other="$(basename "$conf" .conf)"
  if [ "$other" = "$VMID" ]; then
    continue
  fi
  if grep -q "^${SLOT}:" "$conf"; then
    qm set "$other" -delete "$SLOT" || true
  fi
done

qm set "$VMID" -"$SLOT" "host=${USB_ID},usb3=1"
echo "attached $USB_ID as $SLOT on VM $VMID"
