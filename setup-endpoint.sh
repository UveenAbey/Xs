#!/usr/bin/env bash
# setup-endpoint.sh — Automate steps 26–33, then run RPort installer (claim-code prompt)
# Usage:
#   sudo bash setup-endpoint.sh [--keep-mounted]
#
# Idempotent. Logs to /opt/endpoint-setup/logs/

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
  # util-linux -> lsblk; fs tools -> RW for common USB formats
  apt-get install -y ansible sshpass jq util-linux ntfs-3g exfatprogs dosfstools curl ca-certificates
}

find_usb_part() {
  # Find a partition living on a removable disk
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

  # (Steps 27–30) wait up to 60s for USB
  info "Waiting up to 60s for a USB device..."
  local usb_part=""
  for _ in $(seq 1 60); do
    usb_part="$(find_usb_part || true)"
    [ -n "$usb_part" ] && break
    sleep 1
  done
  [ -z "$usb_part" ] && fail "No USB device detected. Insert the USB and re-run."

  ok "USB partition: $usb_part"
  local fstype="$(lsblk -no FSTYPE "$usb_part" || true)"
  info "Filesystem detected: ${fstype:-unknown}"

  # Clean mount
  if mountpoint -q "$mnt"; then umount -lf "$mnt" || true; fi
  mount "$usb_part" "$mnt" || true

  # If read-only, try to flip to RW
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
  echo "$fstype"    > "$ROOTDIR/usb-fstype"
}

detect_nic() {
  # (Step 32) default route interface + IPv4
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

patch_yaml_key() {
  # Replace YAML key's value on a single line
  local file="$1" key="$2" value="$3"
  backup_file "$file"
  # If key exists, replace its value; otherwise append key at end
  if grep -Eq "^[[:space:]]*$key[[:space:]]*:" "$file"; then
    sed -E -i "s/^([[:space:]]*$key[[:space:]]*):.*/\1: $value/g" "$file"
  else
    echo "$key: $value" >> "$file"
  fi
}

patch_files_step33() {
  # (Step 33) Update interface value in both files on USB
  local mnt="/mnt"
  local f1="$mnt/Programmer_local.yaml"
  local f2="$mnt/Programmer-files/docker-compose.yml"

  if [ -f "$f1" ]; then
    info "Patching 'interface' in $f1"
    patch_yaml_key "$f1" "interface" "$IFACE"
    ok "Updated $f1"
  else
    info "Skip: $f1 not found."
  fi

  if [ -f "$f2" ]; then
    info "Patching 'parent' and 'interface' in $f2 (macvlan, rules, etc.)"
    patch_yaml_key "$f2" "parent" "$IFACE"
    # also replace any plain 'interface:' keys if present
    if grep -Eq "^[[:space:]]*interface[[:space:]]*:" "$f2"; then
      sed -E -i "s/^([[:space:]]*interface[[:space:]]*):.*/\1: $IFACE/g" "$f2"
    fi
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

run_rport_installer() {
  echo
  echo "-----------------------------------------------"
  echo "RPort pairing"
  echo "-----------------------------------------------"
  echo "From your PC, open the RPort console, go to 'More (cog) ▸ Client Access',"
  echo "add a new access, set the ID to this host (e.g., 'olucust0xx'), then click 'Linux'."
  echo
  echo "👉 Option A (recommended): Paste the full Linux command shown there (starts with 'curl https://pairing.rport.io/... rport_installer.sh'):"
  echo "   - Paste it here and press Enter. I'll run it for you."
  echo
  echo "👉 Option B: Press Enter without pasting anything, and I'll run the generic installer that will PROMPT for the claim code."
  echo

  read -r -p "Paste Linux pairing command (or press Enter to be prompted for claim code): " RPORT_CMD || true

  if [ -n "$RPORT_CMD" ]; then
    # Extract URL if user pasted entire command; else run as-is
    if echo "$RPORT_CMD" | grep -qE '^curl[[:space:]]+https?://'; then
      URL="$(echo "$RPORT_CMD" | grep -Eo 'https?://[^[:space:]]+')"
      [ -n "$URL" ] || fail "Could not parse URL from the pasted command."
      info "Downloading installer from: $URL"
      TMP=/tmp/rport_installer.sh
      curl -fsSL "$URL" -o "$TMP"
      chmod +x "$TMP"
      echo
      echo "Running RPort installer now..."
      echo "(If it asks for a claim code, paste the code from the console.)"
      echo
      bash "$TMP"
    else
      echo
      echo "Running your pasted command exactly as provided..."
      echo
      eval "$RPORT_CMD"
    fi
  else
    # Generic interactive installer — will ask for claim code
    TMP=/tmp/rport_installer.sh
    info "Fetching generic RPort installer (will prompt for claim code)..."
    curl -fsSL https://pairing.rport.io/rport_installer.sh -o "$TMP" || {
      echo "[!] Could not fetch generic installer. If your org uses a custom pairing URL, rerun the script and paste the full command from the console."
      return 1
    }
    chmod +x "$TMP"
    echo
    echo "Running RPort installer now..."
    echo "(You will be prompted for the claim code.)"
    echo
    bash "$TMP"
  fi
}

# --- Main flow ---
require_root
pkg_install
ensure_usb_rw_mounted
detect_nic
patch_files_step33
maybe_unmount
run_rport_installer

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) setup-endpoint finished ==="
echo "Log saved to: $LOG"
