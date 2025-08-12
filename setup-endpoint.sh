#!/usr/bin/env bash
# setup-endpoint.sh
# Automates Steps 26–32:
#  - Installs ansible + sshpass + jq
#  - Waits for a USB stick, mounts it at /mnt
#  - Detects default NIC + IPv4
#  - Patches Programmer_local.yaml (interface:) and docker-compose.yml (parent:) on the USB (depth<=3)
#  - Writes /opt/endpoint-setup/detected.json
#  - Unmounts the USB
#  - Installs a systemd oneshot service so you can re-run easily
#
# Usage: sudo ./setup-endpoint.sh
set -euo pipefail

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root (e.g., sudo ./setup-endpoint.sh)"; exit 1
  fi
}
require_root
export DEBIAN_FRONTEND=noninteractive

echo "[*] Installing prerequisites (ansible, sshpass, jq)…"
apt-get update -y
apt-get install -y ansible sshpass jq

# Workspace and logs
mkdir -p /opt/endpoint-setup/logs

# --------------------------------------------------------------------
# Oneshoot payload that does the actual Steps 26–32 work
# --------------------------------------------------------------------
cat >/opt/endpoint-setup/endpoint-26-32.sh <<'PAYLOAD'
#!/usr/bin/env bash
set -euo pipefail

STAMP=/opt/endpoint-setup/.26-32.completed
LOG=/opt/endpoint-setup/logs/26-32.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) steps 26-32 start ==="

if [[ -f "$STAMP" ]]; then
  echo "Already completed once; delete $STAMP to re-run."
  exit 0
fi

# --- USB detection (prefer removable disk partitions with filesystems) ---
find_usb_part() {
  lsblk -rpo NAME,TYPE,RM,FSTYPE | awk '
    $2=="disk" && $3==1 {rem[$1]=1}
    $2=="part" && $4!="" {
      p=$1
      parent=p
      sub(/p?[0-9]+$/,"",parent)
      if (rem[parent]==1) { print p }
    }' | head -n1
}

echo "[*] Waiting up to 60s for a USB device…"
USB_PART=""
for _ in {1..60}; do
  USB_PART="$(find_usb_part || true)"
  [[ -n "${USB_PART:-}" ]] && break
  sleep 1
done
if [[ -z "${USB_PART:-}" ]]; then
  echo "[!] No USB detected. Insert USB and re-run: systemctl start endpoint-26-32.service"
  exit 1
fi
echo "[+] USB partition: $USB_PART"

# --- Mount USB at /mnt (ro if possible) ---
mkdir -p /mnt
if mountpoint -q /mnt; then umount -q /mnt || true; fi
if ! mount -o ro "$USB_PART" /mnt 2>/dev/null; then
  mount "$USB_PART" /mnt
fi
echo "[+] Mounted at /mnt"

# --- Detect default interface & IPv4 ---
IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
echo "[+] Interface: $IFACE   IPv4: $IPV4"

# --- Patch files on USB (depth <= 3) ---
ts="$(date +%Y%m%d%H%M%S)"

find_target() { find /mnt -maxdepth 3 -type f -iname "$1" | head -n1; }

PROG_FILE="$(find_target Programmer_local.yaml || true)"
DOCKER_FILE="$(find_target docker-compose.yml || true)"

if [[ -n "${PROG_FILE:-}" && -f "$PROG_FILE" ]]; then
  cp -a "$PROG_FILE" "${PROG_FILE}.bak-${ts}"
  # Replace any "interface:" line (preserve indentation)
  sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$PROG_FILE"
  echo "[+] Patched interface in: $PROG_FILE (backup: ${PROG_FILE}.bak-${ts})"
else
  echo "[!] Programmer_local.yaml not found within /mnt (depth<=3)"
fi

if [[ -n "${DOCKER_FILE:-}" && -f "$DOCKER_FILE" ]]; then
  cp -a "$DOCKER_FILE" "${DOCKER_FILE}.bak-${ts}"
  # Replace the first "parent:" occurrence only
  awk -v iface="$IFACE" '
    BEGIN{changed=0}
    {
      if (!changed && $0 ~ /^[[:space:]]*parent:[[:space:]]*/) {
        sub(/^[[:space:]]*parent:[[:space:]]*.*/, "      parent: " iface)
        changed=1
      }
      print
    }' "$DOCKER_FILE" > "${DOCKER_FILE}.tmp" && mv "${DOCKER_FILE}.tmp" "$DOCKER_FILE"
  echo "[+] Patched parent in: $DOCKER_FILE (backup: ${DOCKER_FILE}.bak-${ts})"
else
  echo "[!] docker-compose.yml not found within /mnt (depth<=3)"
fi

# --- Persist summary ---
cat >/opt/endpoint-setup/detected.json <<JSON
{
  "usb_partition": "$USB_PART",
  "mountpoint": "/mnt",
  "interface": "$IFACE",
  "ipv4": "$IPV4",
  "programmer_local_path": "${PROG_FILE:-}",
  "docker_compose_path": "${DOCKER_FILE:-}",
  "timestamp": "$ts"
}
JSON
echo "[+] Wrote /opt/endpoint-setup/detected.json"

# --- Unmount USB (end of Step 32) ---
umount /mnt || { echo "[!] Failed to unmount /mnt (files may be open)"; exit 1; }
echo "[+] USB unmounted (/mnt)"

touch "$STAMP"
echo "=== $(date -Is) steps 26-32 end ==="
PAYLOAD
chmod +x /opt/endpoint-setup/endpoint-26-32.sh

# --------------------------------------------------------------------
# systemd oneshot so you can re-run: systemctl start endpoint-26-32.service
# --------------------------------------------------------------------
cat >/etc/systemd/system/endpoint-26-32.service <<'UNIT'
[Unit]
Description=Automate Steps 26-32 (install, mount USB, patch files, unmount)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/endpoint-setup/endpoint-26-32.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now endpoint-26-32.service || true

echo
echo "==> Installed."
echo "    Run now (or after inserting USB): sudo systemctl start endpoint-26-32.service"
echo "    Logs:    /opt/endpoint-setup/logs/26-32.log"
echo "    Results: /opt/endpoint-setup/detected.json"

