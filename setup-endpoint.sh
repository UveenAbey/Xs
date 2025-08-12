cat >/opt/endpoint-setup/setup-endpoint.sh <<'EOF'
#!/usr/bin/env bash
# setup-endpoint.sh — automate steps 26–33 (no claim code)
# Usage: sudo bash /opt/endpoint-setup/setup-endpoint.sh [--keep-mounted]
set -euo pipefail

KEEP_MOUNTED="${1:-}"
LOGDIR=/opt/endpoint-setup/logs
mkdir -p "$LOGDIR"
LOG="$LOGDIR/setup-endpoint.$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date -Is) setup-endpoint start ==="

# ---- Step 26: install packages ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ansible sshpass jq lsblk

# ---- Helpers ----
fail(){ echo "[!] $*" ; exit 1; }

detect_usb_part() {
  # return first partition belonging to a removable disk that has a filesystem
  lsblk -rpo NAME,TYPE,RM,FSTYPE | awk '
    $2=="disk" && $3==1 {rd[$1]=1}
    $2=="part" && $4!="" {print $1}
  ' | while read -r part; do
      p="$part"; parent="$p"; parent="${parent%[0-9]}"; parent="${parent%p}"
      if lsblk -rpo NAME,RM | awk -v P="$parent" '$1==P&&$2==1{found=1} END{exit found?0:1}'; then
        echo "$part"; break
      fi
    done
}

remount_rw_or_fix() {
  local dev="$1" fstype="$2"
  if mount | grep -q "/mnt type .* (ro,"; then
    echo "[i] /mnt currently read-only; trying to make it writable (fstype=$fstype)"
    case "$fstype" in
      ntfs)
        apt-get install -y ntfs-3g
        ntfsfix -d "$dev" || true
        mount -o remount,rw "$dev" /mnt || { umount -lf /mnt || true; mount -t ntfs-3g -o rw "$dev" /mnt; }
        ;;
      exfat)
        apt-get install -y exfatprogs
        fsck.exfat -a "$dev" || true
        mount -o remount,rw "$dev" /mnt || { umount -lf /mnt || true; mount -t exfat -o rw "$dev" /mnt; }
        ;;
      vfat|fat|msdos)
        apt-get install -y dosfstools
        dosfsck -a "$dev" || true
        mount -o remount,rw "$dev" /mnt || { umount -lf /mnt || true; mount -t vfat -o rw,uid=0,gid=0,umask=022 "$dev" /mnt; }
        ;;
      ext2|ext3|ext4|"")
        mount -o remount,rw "$dev" /mnt || true
        ;;
      *)
        mount -o remount,rw "$dev" /mnt || true
        ;;
    esac
  fi
  mount | grep -q "/mnt type .* (ro," && fail "USB still read-only; cannot patch files"
}

ts() { date +%Y%m%d%H%M%S; }

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  cp -a "$f" "${f}.bak-$(ts)"
  echo "[+] Backup: ${f}.bak-$(ts)"
}

# ---- Step 27–30: wait for USB & mount to /mnt ----
echo "[*] Waiting up to 60s for a USB device..."
USB_PART=""
for i in $(seq 1 60); do
  USB_PART="$(detect_usb_part || true)"
  [ -n "$USB_PART" ] && break
  sleep 1
done
[ -z "$USB_PART" ] && fail "No USB partition detected. Insert USB and rerun."

mkdir -p /mnt
FSTYPE="$(lsblk -no FSTYPE "$USB_PART" || true)"
echo "[+] USB partition: $USB_PART  fstype: ${FSTYPE:-unknown}"

# clean mountpoint if already mounted
mountpoint -q /mnt && umount -lf /mnt || true
mount "$USB_PART" /mnt || true
# if it mounted read-only, try to flip to rw
remount_rw_or_fix "$USB_PART" "${FSTYPE:-}"

echo "[+] Mounted at /mnt (rw)"

# ---- Step 32: detect NIC + IPv4 ----
IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
[ -n "$IFACE" ] || fail "Could not detect default route interface"
IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
echo "[+] Detected interface: $IFACE   IPv4: ${IPV4:-unknown}"

# Save for downstream steps/tools
mkdir -p /opt/endpoint-setup
cat >/opt/endpoint-setup/detected.json <<JSON
{ "usb_partition":"$USB_PART", "mountpoint":"/mnt", "interface":"$IFACE", "ipv4":"$IPV4" }
JSON
echo "[+] Wrote /opt/endpoint-setup/detected.json"

# ---- Step 33: patch files on USB with detected interface ----
PL="/mnt/Programmer_local.yaml"
DC="/mnt/Programmer-files/docker-compose.yml"

if [ -f "$PL" ]; then
  echo "[*] Patching $PL"
  backup_file "$PL"
  # Replace any "interface: <value>" with detected IFACE
  sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$PL"
  # Also try YAML lists where interface might appear as a value in rules (best effort)
  sed -E -i "s/(interface:[[:space:]]*)([a-zA-Z0-9._:-]+)/\1$IFACE/g" "$PL"
  echo "[+] Updated interface in Programmer_local.yaml -> $IFACE"
else
  echo "[i] Skipped: $PL not found"
fi

if [ -f "$DC" ]; then
  echo "[*] Patching $DC"
  backup_file "$DC"
  # Replace macvlan parent and any interface keys
  sed -E -i "s/(parent:[[:space:]]*)([a-zA-Z0-9._:-]+)/\1$IFACE/g" "$DC"
  sed -E -i "s/(interface:[[:space:]]*)([a-zA-Z0-9._:-]+)/\1$IFACE/g" "$DC"
  echo "[+] Updated docker-compose.yml parent/interface -> $IFACE"
else
  echo "[i] Skipped: $DC not found"
fi

# ---- Step 32 (finish): unmount unless asked not to ----
if [ "$KEEP_MOUNTED" = "--keep-mounted" ]; then
  echo "[i] Leaving /mnt mounted as requested."
else
  umount -lf /mnt || true
  echo "[+] Unmounted /mnt"
fi

echo "=== $(date -Is) setup-endpoint done ==="
EOF

chmod +x /opt/endpoint-setup/setup-endpoint.sh
echo "Saved script to /opt/endpoint-setup/setup-endpoint.sh"
echo "Run it with: sudo /opt/endpoint-setup/setup-endpoint.sh"
