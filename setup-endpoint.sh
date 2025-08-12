mkdir -p /opt/endpoint-setup/logs

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
apt-get install -y ansible sshpass jq

# ---- Helpers ----
fail(){ echo "[!] $*" ; exit 1; }

detect_usb_part() {
  # First partition of a removable disk that has a filesystem
  lsblk -rpo NAME,TYPE,RM,FSTYPE | awk '
    $2=="disk" && $3==1 {rd[$1]=1}
    $2=="part" && $4!="" {parts[NR]=$1}
    END{
      for(i in parts){
        p=parts[i]; parent=p; sub(/p?[0-9]+$/,"",parent)
        if(rd[parent]==1){print p; exit}
      }
    }'
}

remount_rw_or_fix() {
  local dev="$1" fstype="$2"
  if mount | grep -q "/mnt type .* (ro,"; then
    echo "[i] /mnt is read-only; attempting to make it writable (fstype=$fstype)"
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
backup_file() { local f="$1"; [ -f "$f" ] && cp -a "$f" "${f}.bak-$(ts)" && echo "[+] Backup: ${f}.bak-$(ts)"; }

# ---- Steps 27–30: wait for USB & mount to /mnt ----
echo "[*] Waiting up to 60s for a USB device..."
USB_PART=""
for i in $(seq 1 60); do
  USB_PART="$(detect_usb_part || true)"; [ -n "$USB_PART" ] && break; sleep 1
done
[ -z "$USB_PART" ] && fail "No USB partition detected. Insert USB and rerun."

mkdir -p /mnt
FSTYPE="$(lsblk -no FSTYPE "$USB_PART" || true)"
echo "[+] USB partition: $USB_PART  fstype: ${FSTYPE:-unknown}"

mountpoint -q /mnt && umount -lf /mnt || true
mount "$USB_PART" /mnt || true
remount_rw_or_fix "$USB_PART" "${FSTYPE:-}"
echo "[+] Mounted at /mnt (rw)"

# ---- Step 32: detect NIC + IPv4 ----
IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
[ -n "$IFACE" ] || fail "Could not detect default route interface"
IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
echo "[+] Detected interface: $IFACE   IPv4: ${IPV4:-unknown}"

# Save for downstream steps/tools
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
  sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$PL"
  sed -E -i "s/(interface:[[:space:]]*)([a-zA-Z0-9._:-]+)/\1$IFACE/g" "$PL"
  echo "[+] Updated interface in Programmer_local.yaml -> $IFACE"
else
  echo "[i] Skipped: $PL not found"
fi

if [ -f "$DC" ]; then
  echo "[*] Patching $DC"
  backup_file "$DC"
  sed -E -i "s/(parent:[[:space:]]*)([a-zA-Z0-9._:-]+)/\1$IFACE/g" "$DC"
  sed -E -i "s/(interface:[[:space:]]*)([a-zA-Z0-9._:-]+)/\1$IFACE/g" "$DC"
  echo "[+] Updated docker-compose.yml parent/interface -> $IFACE"
else
  echo "[i] Skipped: $DC not found"
fi

# ---- Unmount (unless told not to) ----
if [ "$KEEP_MOUNTED" = "--keep-mounted" ]; then
  echo "[i] Leaving /mnt mounted as requested."
else
  umount -lf /mnt || true
  echo "[+] Unmounted /mnt"
fi

echo "=== $(date -Is) setup-endpoint done ==="
EOF

chmod +x /opt/endpoint-setup/setup-endpoint.sh
echo "Saved: /opt/endpoint-setup/setup-endpoint.sh"
