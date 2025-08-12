#!/usr/bin/env bash
# setup-endpoint.sh — Steps 26–33 + immediate RPort claim prompt
# Usage:
#   sudo bash setup-endpoint.sh [--keep-mounted]
#
# Logs: /opt/endpoint-setup/logs/

set -euo pipefail
KEEP_MOUNTED="${1:-}"

# --- Paths & logging ---
ROOTDIR="/opt/endpoint-setup"
LOGDIR="$ROOTDIR/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/setup-endpoint.$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

fail(){ echo "[!] $*" >&2; exit 1; }
info(){ echo "[*] $*"; }
ok(){ echo "[+] $*"; }

# --- Preconditions ---
[ "$(id -u)" -eq 0 ] || fail "Run as root (sudo)."
command -v ip >/dev/null || fail "'ip' command missing (install iproute2)."

# --- Step 26: packages ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ansible sshpass jq util-linux ntfs-3g exfatprogs dosfstools curl ca-certificates

# --- Helpers ---
find_usb_part() {
  # Find first partition on a removable disk
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
  info "Waiting up to 60s for a USB device..."
  local usb_part=""
  for _ in $(seq 1 60); do
    usb_part="$(find_usb_part || true)"
    [ -n "$usb_part" ] && break
    sleep 1
  done
  [ -n "$usb_part" ] || fail "No USB device detected. Insert the USB and re-run."

  ok "USB partition: $usb_part"
  local fstype="$(lsblk -no FSTYPE "$usb_part" || true)"
  info "Filesystem: ${fstype:-unknown}"

  mountpoint -q "$mnt" && umount -lf "$mnt" || true
  mount "$usb_part" "$mnt" || true

  if mount | grep -qE " on $mnt .* \(ro,"; then
    info "/mnt is read-only; switching to read–write..."
    case "$fstype" in
      ntfs)
        ntfsfix -d "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" \
          || { umount -lf "$mnt" || true; mount -t ntfs-3g -o rw "$usb_part" "$mnt"; }
        ;;
      exfat)
        fsck.exfat -a "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" \
          || { umount -lf "$mnt" || true; mount -t exfat -o rw "$usb_part" "$mnt"; }
        ;;
      vfat|fat|msdos)
        dosfsck -a "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" \
          || { umount -lf "$mnt" || true; mount -t vfat -o rw,uid=0,gid=0,umask=022 "$usb_part" "$mnt"; }
        ;;
      ext2|ext3|ext4|"")
        mount -o remount,rw "$usb_part" "$mnt" || true
        ;;
      *)
        mount -o remount,rw "$usb_part" "$mnt" || true
        ;;
    esac
  fi

  mount | grep -qE " on $mnt .* \(rw," || fail "USB is still read-only; cannot patch files."
  ok "Mounted $usb_part at $mnt (rw)"
  echo "$usb_part" > "$ROOTDIR/usb-partition"
  echo "$fstype"    > "$ROOTDIR/usb-fstype"
}

detect_nic() {
  IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [ -n "${IFACE:-}" ] || fail "Could not detect default interface."
  IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
  ok "Detected interface: $IFACE    IPv4: ${IPV4:-unknown}"

  cat >"$ROOTDIR/detected.json" <<JSON
{ "interface":"$IFACE", "ipv4":"${IPV4:-}" }
JSON
}

backup_file(){ [ -f "$1" ] || fail "File not found: $1"; cp -a "$1" "$1.bak-$(date -u +%Y%m%d%H%M%S)"; }

patch_yaml_key() {
  # Replace/append a simple YAML key on a single line
  local f="$1" k="$2" v="$3"
  backup_file "$f"
  if grep -Eq "^[[:space:]]*$k[[:space:]]*:" "$f"; then
    sed -E -i "s/^([[:space:]]*$k[[:space:]]*):.*/\1: $v/g" "$f"
  else
    echo "$k: $v" >> "$f"
  fi
}

patch_files_step33() {
  local mnt="/mnt"
  local f1="$mnt/Programmer_local.yaml"
  local f2="$mnt/Programmer-files/docker-compose.yml"

  if [ -f "$f1" ]; then
    info "Patching interface in $f1"
    patch_yaml_key "$f1" "interface" "$IFACE"
    ok "Updated $f1"
  else
    info "Skip: $f1 not found"
  fi

  if [ -f "$f2" ]; then
    info "Patching parent/interface in $f2"
    patch_yaml_key "$f2" "parent" "$IFACE"
    if grep -Eq "^[[:space:]]*interface[[:space:]]*:" "$f2"; then
      sed -E -i "s/^([[:space:]]*interface[[:space:]]*):.*/\1: $IFACE/g" "$f2"
    fi
    ok "Updated $f2"
  else
    info "Skip: $f2 not found"
  fi
}

maybe_unmount() {
  if [ "$KEEP_MOUNTED" = "--keep-mounted" ]; then
    info "Leaving USB mounted at /mnt (per --keep-mounted)"
  else
    mountpoint -q /mnt && umount -lf /mnt || true
    ok "Unmounted /mnt"
  fi
}

rport_claim_prompt() {
  echo
  echo "-----------------------------------------------"
  echo " RPort pairing"
  echo "-----------------------------------------------"
  echo "Option A: Paste the FULL Linux command from your RPort portal"
  echo "          (starts with: curl https://... rport_installer.sh)"
  echo
  echo "Option B: Press Enter to run the generic installer and then"
  echo "          paste the CLAIM CODE when prompted."
  echo
  read -r -p "Paste Linux pairing command (or press Enter for generic installer): " RPORT_CMD || true

  if [ -n "${RPORT_CMD:-}" ]; then
    if echo "$RPORT_CMD" | grep -qE '^curl[[:space:]]+https?://'; then
      URL="$(echo "$RPORT_CMD" | grep -Eo 'https?://[^[:space:]]+')"
      if [ -n "$URL" ]; then
        TMP=/tmp/rport_installer.sh
        info "Downloading installer from: $URL"
        curl -fsSL "$URL" -o "$TMP"
        chmod +x "$TMP"
        echo
        echo "Running RPort installer..."
        bash "$TMP"
      else
        echo "[!] Could not parse URL; running pasted command as-is…"
        eval "$RPORT_CMD"
      fi
    else
      echo "[*] Running pasted command as-is…"
      eval "$RPORT_CMD"
    fi
  else
    TMP=/tmp/rport_installer.sh
    info "Fetching generic installer (will PROMPT for CLAIM CODE)…"
    curl -fsSL https://pairing.rport.io/rport_installer.sh -o "$TMP"
    chmod +x "$TMP"
    echo
    echo "Running RPort installer (you will be asked for the CLAIM CODE)…"
    bash "$TMP"
  fi
}

# --- Main flow ---
ensure_usb_rw_mounted       # 27–30
detect_nic                 # 32
patch_files_step33         # 33
maybe_unmount
rport_claim_prompt         # 31 (claim code prompt path)

echo
echo "=== Done. Log: $LOG ==="
