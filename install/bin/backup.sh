#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- automated modem partition backup engine.
# Dumps all radio/modem partitions to $POX_BACKUP_ROOT/Modem_<TS>/ with a
# sha256 manifest + device identity snapshot. Best effort, never aborts.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib.sh"

TS=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo manual)
# storage root: /sdcard when writable, else /data/media/0 (same FUSE tree)
if mkdir -p /sdcard/Pox_Backups 2>/dev/null; then
  POX_BACKUP_ROOT=/sdcard/Pox_Backups
elif mkdir -p /data/media/0/Pox_Backups 2>/dev/null; then
  POX_BACKUP_ROOT=/data/media/0/Pox_Backups
fi
DST="$POX_BACKUP_ROOT/Modem_$TS"
mkdir -p "$DST" 2>/dev/null

PARTS="nvram nvdata nvcfg protect1 protect2 proinfo md1img persist"
banner "Backing up modem partitions -> $DST"

FAILS=0
: > "$DST/checksums.sha256"
for p in $PARTS; do
  BLK=$(pblock "$p")
  if [ -z "$BLK" ]; then
    log "backup: $p: no by-name node found, skipping"
    continue
  fi
  if dd if="$BLK" of="$DST/${p}.img" bs=4M 2>>"$POX_LOG"; then
    h=$(sha256_of "$DST/${p}.img")
    [ -n "$h" ] && echo "$h  ${p}.img" >> "$DST/checksums.sha256"
    log "backup: $p OK ($h)"
  else
    log "backup: $p FAILED"
    FAILS=$((FAILS+1))
    rm -f "$DST/${p}.img"
  fi
done

{
  echo "pox_backup_info: $(date 2>/dev/null)"
  echo "kernel: $(pox_kernel)  device: $(pox_device)  chipid: $(pox_chipid)  region: $(pox_region)"
  echo "md1img support prop: $(getp ro.vendor.mtk_md1_support)"
} > "$DST/backup_info.txt" 2>/dev/null

if [ "$FAILS" = 0 ]; then banner "Backup complete ($DST)"; else banner "Backup PARTIAL: $FAILS partition(s) failed"; fi
echo "$DST" > /data/local/tmp/pox_last_backup 2>/dev/null
exit 0
