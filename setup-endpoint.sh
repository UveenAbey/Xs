#!/usr/bin/env bash
# Automates Steps 26–33 + run Ansible play + tail docker logs

set -euo pipefail

KEEP_MOUNTED="${1:-}"              # optional: --keep-mounted (ignored once we start docker logs)
ANSIBLE_USER="${ANSIBLE_USER:-spectre}"

ROOTDIR="/opt/endpoint-setup"
LOGDIR="$ROOTDIR/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/setup-endpoint.$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

info(){ echo "[*] $*"; }
ok(){ echo "[+] $*"; }
fail(){ echo "[!] $*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || fail "Please run as root (sudo)."; }

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

  mountpoint -q "$mnt" && umount -lf "$mnt" || true
  mount "$usb_part" "$mnt" || true

  if mount | grep -qE " on $mnt .* \(ro,"; then
    info "Remounting read‑write..."
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

  mount | grep -qE " on $mnt .* \(rw," || fail "USB still read‑only."
  ok "Mounted at $mnt (rw)"
}

detect_nic() {
  IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [ -n "$IFACE" ] || fail "No default interface found."
  IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
  ok "Interface: $IFACE   IPv4: $IPV4"
}

backup_file() { local f="$1"; [ -f "$f" ] || fail "File not found: $f"; cp -a "$f" "${f}.bak-$(date -u +%Y%m%d%H%M%S)"; }

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

run_ansible_play() {
  local play="/mnt/Programmer_local.yaml"
  [ -f "$play" ] || fail "Playbook not found at $play"
  echo
  echo "=== Running Ansible playbook (you will be prompted for become password) ==="
  echo "Command: ansible-playbook --ask-become-pass --connection=local -u $ANSIBLE_USER $play"
  echo
  # If you also want SSH password prompt, add: --ask-pass
  (cd / && ansible-playbook --ask-become-pass --connection=local -u "$ANSIBLE_USER" "$play")
  ok "Ansible playbook finished."
}

unmount_usb() {
  umount -lf /mnt || true
  ok "Unmounted /mnt"
}

tail_docker_logs() {
  echo
  echo "=== Tailing Docker logs for project 'greenbone-community-edition' ==="
  echo "Tip: Press Ctrl+C to stop following logs."
  echo
  # If compose isn’t installed/containers not running, show a helpful message
  if ! command -v docker >/dev/null; then
    fail "Docker is not installed."
  fi
  # This does not rely on files on the USB (project should be already deployed by Ansible).
  exec docker compose -p greenbone-community-edition logs -f
}

# --- main ---
require_root
pkg_install
ensure_usb_rw_mounted
detect_nic
patch_step33
run_ansible_play
unmount_usb
tail_docker_logs
