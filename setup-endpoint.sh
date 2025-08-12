#!/usr/bin/env bash
# Automates Steps 26–33 from your doc, with optional RPort claim prompt.

set -euo pipefail

KEEP_MOUNTED="${1:-}"       # Pass --keep-mounted to leave USB mounted
PRE_CLAIM_ONLY="${2:-}"     # Pass --pre-claim to stop before claim prompt

ROOTDIR="/opt/endpoint-setup"
LOGDIR="$ROOTDIR/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/setup-endpoint.$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

info(){ echo "[*] $*"; }
ok(){ echo "[+] $*"; }
fail(){ echo "[!] $*" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Please run as root."
  fi
}

pkg_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ansible sshpass jq util-linux ntfs-3g exfatprogs dosfstools
}

find_usb_part() {
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
  for i in $(seq 1 60); do
    usb_part="$(find_usb_part || true)"
    [ -n "$usb_part" ] && break
    sleep 1
  done
  [ -z "$usb_part" ] && fail "No USB detected."

  ok "USB partition: $usb_part"
  local fstype="$(lsblk -no FSTYPE "$usb_part" || true)"
  info "Filesystem: ${fstype:-unknown}"

  if mountpoint -q "$mnt"; then umount -lf "$mnt" || true; fi
  mount "$usb_part" "$mnt" || true

  if mount | grep -qE " on $mnt .* \(ro,"; then
    info "Remounting read-write..."
    case "$fstype" in
      ntfs)
        ntfsfix -d "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" || mount -t ntfs-3g -o rw "$usb_part" "$mnt"
        ;;
      exfat)
        fsck.exfat -a "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" || mount -t exfat -o rw "$usb_part" "$mnt"
        ;;
      vfat|fat|msdos)
        dosfsck -a "$usb_part" || true
        mount -o remount,rw "$usb_part" "$mnt" || mount -t vfat -o rw,uid=0,gid=0,umask=022 "$usb_part" "$mnt"
        ;;
      ext2|ext3|ext4|"")
        mount -o remount,rw "$usb_part" "$mnt" || true
        ;;
      *)
        mount -o remount,rw "$usb_part" "$mnt" || true
        ;;
    esac
  fi

  mount | grep -qE " on $mnt .* \(rw," || fail "USB still read-only."
  ok "Mounted at $mnt (rw)"
}

detect_nic() {
  IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [ -n "$IFACE" ] || fail "No default interface found."
  IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
  ok "Interface: $IFACE   IPv4: $IPV4"
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || fail "File not found: $f"
  cp -a "$f" "${f}.bak-$(date -u +%Y%m%d%H%M%S)"
}

patch_step33() {
  local mnt="/mnt"
  local f1="$mnt/Programmer_local.yaml"
  local f2="$mnt/Programmer-files/docker-compose.yml"

  if [ -f "$f1" ]; then
    info "Patching $f1"
    backup_file "$f1"
    sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$f1"
    ok "Updated $f1"
  else
    info "$f1 not found"
  fi

  if [ -f "$f2" ]; then
    info "Patching $f2"
    backup_file "$f2"
    sed -E -i "s/^([[:space:]]*parent:[[:space:]]*).*/\1$IFACE/g" "$f2"
    sed -E -i "s/^([[:space:]]*interface:[[:space:]]*).*/\1$IFACE/g" "$f2"
    ok "Updated $f2"
  else
    info "$f2 not found"
  fi
}

maybe_unmount() {
  if [ "$KEEP_MOUNTED" = "--keep-mounted" ]; then
    info "Keeping /mnt mounted"
  else
    umount -lf /mnt || true
    ok "Unmounted /mnt"
  fi
}

prompt_claim_code() {
  local profile_script="/etc/profile.d/99-rport-claim.sh"
  cat >"$profile_script" <<'EOS'
#!/usr/bin/env bash
echo ""
echo "=== RPort pairing (claim code) ==="
echo "Option A: Paste the full Linux command from the RPort portal (starts with curl)"
echo "Option B: Type: curl https://pairing.url | bash"
EOS
  chmod +x "$profile_script"
  ok "Claim code prompt will appear at next login"
}

# --- Main ---
require_root
pkg_install
ensure_usb_rw_mounted
detect_nic
patch_step33
maybe_unmount

if [ "$PRE_CLAIM_ONLY" = "--pre-claim" ]; then
  touch "$ROOTDIR/.claim_pending"
  prompt_claim_code
fi

ok "Automation complete."
