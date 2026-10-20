#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- restore helper (recovery or in-OS root).
# Restores the LATEST automatic backup produced by backup.sh, or, if a source
# directory is passed as $1, that one. Overwrites partitions with dd.
# UNINSTALLS the pox module bits afterwards if restore-all is requested.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib.sh"

SRC_DIR="$1"
if [ -z "$SRC_DIR" ]; then
  LAST=$(cat /data/local/tmp/pox_last_backup 2>/dev/null)
  if [ -n "$LAST" ] && [ -d "$LAST" ]; then SRC_DIR="$LAST"
  else SRC_DIR=$(ls -d "$POX_BACKUP_ROOT"/Modem_* 2>/dev/null | sort | tail -1)
  fi
fi
[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || { banner "No backup directory found."; exit 2; }
banner "Restoring modem partitions from: $SRC_DIR"

FAILS=0
for f in "$SRC_DIR"/*.img; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .img)
  BLK=$(pblock "$name")
  if [ -z "$BLK" ]; then log "restore: no by-name node for $name (skip)"; continue; fi
  # verify hash before writing when manifest exists
  if [ -f "$SRC_DIR/checksums.sha256" ]; then
    want=$(grep " $name\$\| ${name}.img$" "$SRC_DIR/checksums.sha256" | awk '{print $1}' | head -1)
    got=$(sha256_of "$f")
    [ -n "$want" ] && [ "$want" != "$got" ] && { banner "sha256 mismatch for $name -- NOT flashing."; FAILS=$((FAILS+1)); continue; }
  fi
  if dd if="$f" of="$BLK" bs=4M conv=fsync 2>>"$POX_LOG"; then
    banner "restored $name"
  else
    banner "FAILED to flash $name"
    FAILS=$((FAILS+1))
  fi
done

if [ "$2" = "--uninstall" ]; then
  mount_vendor
  rm -f /vendor/etc/init/md_patcher.rc /vendor/etc/vintf/manifest/pox_radio.xml 2>/dev/null
  rm -f /vendor/lib/modules/md_patcher-*.ko 2>/dev/null
  rm -rf /vendor/bin/pox_module.sh /vendor/bin/pox_lib.sh 2>/dev/null
  umount /vendor 2>/dev/null
  # remove pox build.prop block if present
  if [ -e /vendor/build.prop ]; then
    sed -i '/# POX-VOLTE-BEGIN/,/# POX-VOLTE-END/d' /vendor/build.prop 2>/dev/null
  fi
  rm -rf /data/adb/modules/pox_imei_fixer 2>/dev/null
  banner "POX module bits removed (full uninstall)."
fi

banner "Restore done (failures: $FAILS)"
exit $((FAILS>0))
