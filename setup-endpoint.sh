bash -c 'set -euo pipefail
# --- Paths
ROOT=/opt/endpoint-setup
LOGS=$ROOT/logs
mkdir -p "$ROOT" "$LOGS"

# --- Main script: setup-endpoint.sh (pre-claim steps + optional interactive)
cat >"$ROOT/setup-endpoint.sh" <<"EOS"
#!/usr/bin/env bash
# setup-endpoint.sh — Steps 26–33, non-interactive.
#   Flags:
#     --keep-mounted      leave USB mounted at /mnt
#     --preclaim-only     do NOT run RPort installer here (used by systemd); instead mark claim pending.

set -euo pipefail
KEEP_MOUNTED=""
PRECLAIM_ONLY=""

for a in "$@"; do
  case "$a" in
    --keep-mounted) KEEP_MOUNTED="1" ;;
    --preclaim-only) PRECLAIM_ONLY="1" ;;
    *) ;;
  esac
done

ROOTDIR="/opt/endpoint-setup"
LOGDIR="$ROOTDIR/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/setup-endpoint.$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

fail(){ echo "[!] $*" >&2; exit 1; }
info(){ echo "[*] $*"; }
ok(){ echo "[+] $*"; }

[ "$(id -u)" -eq 0 ] || fail "Run as root."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ansible sshpass jq util-linux ntfs-3g exfatprogs dosfstools curl ca-certificates

find_usb_part() {
  lsblk -rpo NAME,TYPE,RM,TRAN,FSTYPE,MOUNTPOINT | awk "
    \$2==\"disk\" && \$3==1 {d[\$1]=1}
    \$2==\"part\" {parts[NR]=\$1}
    END{
      for(i in parts){
        part=parts[i]
        parent=part; sub(/p?[0-9]+\$/,\"\",parent)
        if(d[parent]==1){print part; exit}
      }
    }"
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
  [ -z "$usb_part" ] && fail "No USB device detected."

  ok "USB partition: $usb_part"
  local fstype="$(lsblk -no FSTYPE "$usb_part" || true)"
  info "Filesystem: ${fstype:-unknown}"

  mountpoint -q "$mnt" && umount -lf "$mnt" || true
  mount "$usb_part" "$mnt" || true

  if mount | grep -qE " on $mnt .* \(ro,"; then
    info "/mnt is RO; switching to RW…"
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
      *)  mount -o remount,rw "$usb_part" "$mnt" || true ;;
    esac
  fi

  mount | grep -qE " on $mnt .* \(rw," || fail "USB still read-only."
  echo "$usb_part" > "$ROOTDIR/usb-partition"
  echo "$fstype" > "$ROOTDIR/usb-fstype"
  ok "Mounted $usb_part at $mnt (rw)"
}

detect_nic() {
  IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [ -n "${IFACE:-}" ] || fail "No default interface."
  IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
  ok "Interface: $IFACE   IPv4: ${IPV4:-unknown}"
  cat >"$ROOTDIR/detected.json" <<JSON
{ "interface":"$IFACE", "ipv4":"${IPV4:-}" }
JSON
}

backup_file(){ [ -f "$1" ] || fail "Missing: $1"; cp -a "$1" "$1.bak-$(date -u +%Y%m%d%H%M%S)"; }

patch_yaml_key() {
  local f="$1" k="$2" v="$3"
  backup_file "$f"
  if grep -Eq "^[[:space:]]*$k[[:space:]]*:" "$f"; then
    sed -E -i "s/^([[:space:]]*$k[[:space:]]*):.*/\1: $v/g" "$f"
  else
    echo "$k: $v" >> "$f"
  fi
}

patch_step33() {
  local mnt="/mnt"
  local f1="$mnt/Programmer_local.yaml"
  local f2="$mnt/Programmer-files/docker-compose.yml"
  [ -f "$f1" ] && { echo "[*] Patching $f1"; patch_yaml_key "$f1" "interface" "$IFACE"; echo "[+] Done $f1"; } || echo "[i] $f1 not found"
  if [ -f "$f2" ]; then
    echo "[*] Patching $f2"
    patch_yaml_key "$f2" "parent" "$IFACE"
    if grep -Eq "^[[:space:]]*interface[[:space:]]*:" "$f2"; then
      sed -E -i "s/^([[:space:]]*interface[[:space:]]*):.*/\1: $IFACE/g" "$f2"
    fi
    echo "[+] Done $f2"
  else
    echo "[i] $f2 not found"
  fi
}

maybe_unmount(){
  if [ -z "$KEEP_MOUNTED" ]; then
    mountpoint -q /mnt && umount -lf /mnt || true
    echo "[+] Unmounted /mnt"
  else
    echo "[i] Keeping /mnt mounted per flag"
  fi
}

main() {
  ensure_usb_rw_mounted
  detect_nic
  patch_step33
  maybe_unmount

  if [ -n "$PRECLAIM_ONLY" ]; then
    touch "$ROOTDIR/.claim_pending"
    echo "[*] Pre-claim steps complete. .claim_pending created."
  fi
}

main
EOS
chmod +x "$ROOT/setup-endpoint.sh"

# --- Login-time prompt to run RPort pairing (interactive)
cat >/etc/profile.d/99-rport-claim.sh <<"EOS"
# If preclaim marker exists, prompt for RPort pairing at login.
[ -f /opt/endpoint-setup/.claim_pending ] || return 0
echo
echo "-----------------------------------------------"
echo " RPort pairing (claim code)"
echo "-----------------------------------------------"
echo "Option A: Paste the full Linux command from the RPort portal (starts with 'curl https://... rport_installer.sh')"
echo "Option B: Press Enter to run the generic installer and then paste the claim code when prompted."
echo

read -r -p "Paste Linux pairing command (or press Enter for generic installer): " RPORT_CMD
if [ -n "$RPORT_CMD" ]; then
  if echo "$RPORT_CMD" | grep -qE '^curl[[:space:]]+https?://'; then
    URL="$(echo "$RPORT_CMD" | grep -Eo "https?://[^[:space:]]+")"
    if [ -n "$URL" ]; then
      TMP=/tmp/rport_installer.sh
      echo "[*] Downloading installer from: $URL"
      curl -fsSL "$URL" -o "$TMP" && chmod +x "$TMP" && bash "$TMP"
    else
      echo "[!] Could not parse URL. Running pasted command as-is…"
      eval "$RPORT_CMD"
    fi
  else
    echo "[*] Running pasted command as-is…"
    eval "$RPORT_CMD"
  fi
else
  TMP=/tmp/rport_installer.sh
  echo "[*] Fetching generic installer (will prompt for claim code)…"
  if curl -fsSL https://pairing.rport.io/rport_installer.sh -o "$TMP"; then
    chmod +x "$TMP"
    bash "$TMP"
  else
    echo "[!] Could not fetch generic installer. Please paste the full command from your portal instead."
    return 0
  fi
fi

# If we got here, the installer exited. Remove marker so you are not prompted again.
rm -f /opt/endpoint-setup/.claim_pending
echo "[+] Pairing step finished. This prompt will not appear next login."
echo
EOS
chmod 644 /etc/profile.d/99-rport-claim.sh

# --- systemd oneshot: run steps 26–33 on first boot
cat >/etc/systemd/system/endpoint-preclaim.service <<"EOS"
[Unit]
Description=Endpoint pre-claim automation (steps 26–33)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/endpoint-setup/.preclaim_done

[Service]
Type=oneshot
ExecStart=/opt/endpoint-setup/setup-endpoint.sh --preclaim-only --keep-mounted
ExecStartPost=/bin/sh -c 'touch /opt/endpoint-setup/.preclaim_done'
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOS

systemctl daemon-reload
systemctl enable --now endpoint-preclaim.service || true

echo
echo "==> Installed."
echo "Logs will appear in: /opt/endpoint-setup/logs/"
echo "The pre-claim steps will run now (or at next boot)."
echo "On your next login, you will be prompted to complete RPort pairing (claim code)."
'
