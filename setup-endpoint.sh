sudo mkdir -p /opt/endpoint-setup/logs
sudo tee /opt/endpoint-setup/setup-endpoint.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG=/opt/endpoint-setup/logs/setup-endpoint.log
exec >>"$LOG" 2>&1

echo "=== $(date -Is) setup-endpoint start ==="

# --------- args ---------
KEEP_MOUNTED=0
RPORT_CLAIM="${RPORT_CLAIM:-}"   # or pass --rport-claim CODE
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-mounted) KEEP_MOUNTED=1; shift;;
    --rport-claim) RPORT_CLAIM="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

# --------- packages (Step 26) ---------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ansible sshpass jq util-linux ntfs-3g exfatprogs dosfstools curl ca-certificates

# --------- find USB (Steps 27–30) ---------
find_usb_part() {
  # removable disk -> first partition with a filesystem
  lsblk -rpo NAME,TYPE,RM,FSTYPE | awk '
    $2=="disk" && $3==1 {d[$1]=1}
    $2=="part" && $4!="" {p[$1]=1}
    END{
      for (part in p){
        parent=part; sub(/p?[0-9]+$/,"",parent)
        if (d[parent]==1){print part; exit}
      }
    }'
}

echo "[*] Waiting up to 60s for a USB device..."
USB_PART=""
for i in {1..60}; do
  USB_PART="$(find_usb_part || true)"
  [[ -n "$USB_PART" ]] && break
  sleep 1
done
if [[ -z "$USB_PART" ]]; then
  echo "[!] No USB detected. Insert USB and re-run: systemctl start endpoint-setup.service"
  exit 1
fi
echo "[+] USB partition: $USB_PART"

mkdir -p /mnt
# unmount any stale mount
mountpoint -q /mnt && umount -lf /mnt || true

FSTYPE="$(lsblk -no FSTYPE "$USB_PART" || true)"
echo "[+] Filesystem: ${FSTYPE:-unknown}"
mount "$USB_PART" /mnt || true

# if mounted ro, try to make it rw for common fs types
if mount | grep -q "/mnt type .* (ro,"; then
  echo "[i] /mnt is read-only; trying to remount read-write..."
  case "$FSTYPE" in
    ntfs)      ntfsfix -d "$USB_PART" || true; mount -o remount,rw "$USB_PART" /mnt || { umount -lf /mnt || true; mount -t ntfs-3g -o rw "$USB_PART" /mnt; } ;;
    exfat)     fsck.exfat -a "$USB_PART" || true; mount -o remount,rw "$USB_PART" /mnt || { umount -lf /mnt || true; mount -t exfat -o rw "$USB_PART" /mnt; } ;;
    vfat|fat*) dosfsck -a "$USB_PART" || true; mount -o remount,rw "$USB_PART" /mnt || { umount -lf /mnt || true; mount -t vfat -o rw,uid=0,gid=0,umask=022 "$USB_PART" /mnt; } ;;
    ext2|ext3|ext4|"") mount -o remount,rw "$USB_PART" /mnt || true ;;
    *)         mount -o remount,rw "$USB_PART" /mnt || true ;;
  esac
fi

if mount | grep -q "/mnt type .* (ro,"; then
  echo "[!] Still read-only. Cannot modify files on USB. Aborting."
  exit 1
fi
echo "[+] Mounted at /mnt (read-write)"

# --------- detect NIC + IP (Step 32) ---------
IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
IPV4="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
echo "[+] Interface: $IFACE   IPv4: $IPV4"

# persist facts for later or auditing
tee /opt/endpoint-setup/detected.json <<JSON >/dev/null
{ "usb_partition":"$USB_PART", "mountpoint":"/mnt", "interface":"$IFACE", "ipv4":"$IPV4" }
JSON

# --------- Step 33: edit files on the USB ---------
PL="/mnt/Programmer_local.yaml"
DC="/mnt/Programmer-files/docker-compose.yml"
STAMP="$(date +%Y%m%d%H%M%S)"

# 33a) Programmer_local.yaml -> set network.interface: <IFACE>
if [[ -f "$PL" ]]; then
  cp -a "$PL" "${PL}.bak-${STAMP}"
  # replace 'interface:' anywhere; if not present, add under top-level 'network:' block
  if grep -qE '^[[:space:]]*interface:[[:space:]]' "$PL"; then
    sed -i -E "s|^([[:space:]]*interface:[[:space:]]*).*$|\1$IFACE|g" "$PL"
  else
    # try to append under an existing 'network:' section, else append to end
    if grep -qE '^network:[[:space:]]*$' "$PL"; then
      awk -v iface="$IFACE" '
        BEGIN{added=0}
        {print}
        /^network:[[:space:]]*$/ && added==0 {print "  interface: " iface; added=1}
        END{if(added==0) print "network:\n  interface: " iface}
      ' "$PL" > "${PL}.tmp" && mv "${PL}.tmp" "$PL"
    else
      printf "\nnetwork:\n  interface: %s\n" "$IFACE" >> "$PL"
    fi
  fi
  echo "[+] Patched $PL (backup: ${PL}.bak-${STAMP})"
else
  echo "[i] Skipped: $PL not found on USB."
fi

# 33b) docker-compose.yml -> set parent: <IFACE> (macvlan) and any 'interface:' fields
if [[ -f "$DC" ]]; then
  cp -a "$DC" "${DC}.bak-${STAMP}"
  # parent: <iface>
  sed -i -E "s|^([[:space:]]*parent:[[:space:]]*).*$|\1$IFACE|g" "$DC"
  # interface: <iface> (e.g., inside firewall blocks)
  sed -i -E "s|^([[:space:]]*interface:[[:space:]]*).*$|\1$IFACE|g" "$DC"
  echo "[+] Patched $DC (backup: ${DC}.bak-${STAMP})"
else
  echo "[i] Skipped: $DC not found on USB."
fi

# --------- Optional: Rport claim (if provided) ---------
if [[ -n "$RPORT_CLAIM" ]]; then
  echo "[*] Running Rport claim with code suffix: $RPORT_CLAIM"
  # Example: adjust flags per your environment/policy
  curl -fsSL "https://pairing.rport.io/${RPORT_CLAIM}" -o /tmp/rport_installer.sh
  chmod +x /tmp/rport_installer.sh
  sudo /tmp/rport_installer.sh -s r -b l
  echo "[+] Rport claim attempted."
fi

# --------- tidy ----------
if [[ "$KEEP_MOUNTED" -ne 1 ]]; then
  umount -lf /mnt || true
  echo "[+] USB unmounted."
else
  echo "[i] Leaving USB mounted at /mnt (--keep-mounted)."
fi

echo "=== $(date -Is) setup-endpoint done ==="
EOF
sudo chmod +x /opt/endpoint-setup/setup-endpoint.sh
