#!/usr/bin/env bash
# setup-endpoint.sh — automate steps 26–33 (install, mount USB, detect NIC, patch files)
# Usage:
#   sudo bash setup-endpoint.sh [--keep-mounted]
#
# Re-run safe/idempotent. Logs: /opt/endpoint-setup/logs/

set -euo pipefail

KEEP_MOUNTED="${1:-}"

# --- Paths & logging ---
ROOTDIR="/opt/endpoint-setup"
LOGDIR="$ROOTDIR/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/setup-endpoint.$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) setup-endpoint start ==="

# --- Helpers ---
fail(){ echo "[!] $*" >&2; exit 1; }
info(){ echo "[*] $*"; }
ok(){ echo "[+] $*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Please run as root (sudo)."
  fi
}

pkg_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  # util-linux provides lsblk; fs tools provide rw mounts for common USB formats
  apt-get install -y ansible sshpass jq util-linux ntfs-3g exfatprogs dosfstools
}

find_usb_part() {
  # find a partition on a removable disk
  lsblk -rpo NAME,TYPE,RM,TRAN,FSTYPE,MOUNTPOINT | awk '
    $2=="disk" && $3==1 {d[$1]=1}
    $2=="part" {parts[NR]=$1}
    END{
      for(i in parts){
        part=parts[i]
        parent=part; sub(/p?[0-9]+$/,"",parent)
        if(d[parent]==1){print part; exit}
      }
    }'
}

ensure_usb_rw_mounted() {
  local mnt="/mnt"
  mkdir -p "$mnt"

  # (Step 27–30) wait for a USB partition
  info "Waiting up to 60s for a USB device..."
  local usb_part=""
  for i in $(seq 1 60); do
    usb_part="$(find_usb_part || true)"
    [ -n "$usb_part" ] && break
    sleep 1
  done
  [ -z "$usb_part" ] && fail "No USB device detected. Insert the USB and re-run."

  ok "USB partition: $usb_part"
  local fstype="$(lsblk -no FSTYPE "$usb_part" || true)"
  info "Filesystem detected: ${fstype:-unknown}"

  # (Re)mount cleanly
  if mountpoint -q "$mnt"; then umount -lf "$mnt" || true; fi
  mount "$usb_part" "$mnt" || true

  # If mounted read-only, try to flip to rw based on fs type
  if mount | grep -qE " on $mnt .* \(ro,"; then
    info "/mnt is read-only; attempting to switch to read-write..."
    case "$fstype" in
      ntfs)
        ntfsfix -d "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" || { umount -lf "$mnt" || true; mount -t ntfs-3g -o rw "$usb_part" "$mnt"; }
        ;;
      exfat)
        fsck.exfat -a "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" || { umount -lf "$mnt" || true; mount -t exfat -o rw "$usb_part" "$mnt"; }
        ;;
      vfat|fat|msdos)
        dosfsck -a "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" || { umount -lf "$mnt" || true; mount -t vfat -o rw,uid=0,gid=0,umask=022 "$usb_part" "$mnt"; }
        ;;
      ext2|ext3|ext4|"")
        mount -o remount,rw "$usb_part" "$mnt" || true
        ;;
      *)
        mount -o remount,rw "$usb_part" "$mnt" || true
        ;;
    esac
  fi

  mount | grep -qE " on $mnt .* \(rw," || fail "USB is still read-only; cannot patch files safely."

  ok "Mounted $usb_part at $mnt (read-write)"
  echo "$usb_part" > "$ROOTDIR/usb-partition"
  echo "$fstype" > "$ROOTDIR/usb-fstype"
}

detect_nic() {
  # (Step 32) detect default route interface + IPv4
  IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [ -n "${IFACE:-}" ] || fail "Could not detect default interface."
  IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
  ok "Detected interface: $IFACE    IPv4: ${IPV4:-unknown}"

  cat >"$ROOTDIR/detected.json" <<JSON
{ "interface":"$IFACE", "ipv4":"${IPV4:-}" }
JSON
  ok "Wrote $ROOTDIR/detected.json"
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || fail "File not found: $f"
  cp -a "$f" "${f}.bak-$(date -u +%Y%m%d%H%M%S)"
}

patch_yaml_interface() {
  # Replace any YAML line like "interface: something" with detected IFACE
  local file="$1"
  backup_file "$file"
  sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$file"
}

patch_yaml_parent() {
  # Replace any YAML line like "parent: something" (macvlan) with detected IFACE
  local file="$1"
  backup_file "$file"
  sed -E -i "s/^([[:space:]]*parent:[[:space:]]*).*/\1$IFACE/g" "$file"
}

patch_files_step33() {
  # (Step 33) Apply interface to both files on the USB
  local mnt="/mnt"
  local f1="$mnt/Programmer_local.yaml"
  local f2="$mnt/Programmer-files/docker-compose.yml"

  if [ -f "$f1" ]; then
    info "Patching interface in $f1"
    patch_yaml_interface "$f1"
    # Also patch any other 'interface:' occurrences inside that file
    sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$f1"
    ok "Updated $f1"
  else
    info "Skip: $f1 not found."
  fi

  if [ -f "$f2" ]; then
    info "Patching parent/interface in $f2"
    patch_yaml_parent "$f2"
    sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$f2"
    ok "Updated $f2"
  else
    info "Skip: $f2 not found."
  fi
}

maybe_unmount() {
  local mnt="/mnt"
  if [ "$KEEP_MOUNTED" = "--keep-mounted" ]; then
    info "Leaving USB mounted at $mnt (per --keep-mounted)."
  else
    if mountpoint -q "$mnt"; then
      umount -lf "$mnt" || true
      ok "Unmounted $mnt"
    fi
  fi
}

# --- Main flow ---
require_root
pkg_install
ensure_usb_rw_mounted
detect_nic
patch_files_step33
maybe_unmount

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) setup-endpoint finished ==="
echo "Log saved to: $LOG"
