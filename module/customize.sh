#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- in-OS (root manager) installer hook.
# Runs inside Magisk / KernelSU / APatch / FolkPatch when the user installs
# this zip. Performs the full repair job from the running system:
#    backup -> validate nvram -> (conditionally) flash new nvram
#    -> wipe nvdata -> perms -> stage module files -> props glue
# SKIPUNZIP=0 (standard template unzip is fine)
# ---------------------------------------------------------------------------
MODDIR=${0%/*}
LOG=${LOG:-/data/local/tmp/pox_imei_patcher.log}
{
echo "======== customize.sh install $(date 2>/dev/null) loader=$(uname -r) ========"
} >> "$LOG" 2>&1

ui_print() { echo "$1"; }
mount /data 2>/dev/null
mount /vendor 2>/dev/null
mount /sdcard 2>/dev/null
mount /system 2>/dev/null

[ -f "$MODDIR/install/bin/lib.sh" ] || { ui_print "POX install/bin missing"; exit 1; }
POX_MODE=repair-if-invalid
[ -f "$MODDIR/mode" ] && POX_MODE=$(cat "$MODDIR/mode")

BINDIR="$MODDIR/install/bin"
export POX_LOG="$LOG"
CHIP=$(getprop ro.boot.chipid)
BLK=/dev/block/platform/bootdevice/by-name
[ -d /dev/block/by-name ] && BLK=/dev/block/by-name
[ -d /dev/block/bootdevice/by-name ] && BLK=/dev/block/bootdevice/by-name

ui_print "POX in-OS install (mode=$POX_MODE)"
ui_print "backup engine..."
"$BINDIR/backup.sh" >>"$LOG" 2>&1 || ui_print "backup reported issues (see log)"

NVRAM_OK=0
if "$BINDIR/nvram_check.sh" "$BLK/nvram" "$CHIP" "$(getprop ro.product.device)" >>"$LOG" 2>&1; then
  NVRAM_OK=1
  ui_print "existing NVRAM is valid -- keeping it"
fi

WRITE=0
case "$POX_MODE" in
  validate-only) WRITE=0 ;;
  force)         WRITE=1 ;;
  *)             [ "$NVRAM_OK" = 0 ] && WRITE=1 ;;
esac

if [ "$WRITE" = 1 ]; then
  NVRAM_IMG="$MODDIR/install/nvram.img"
  [ -f "$NVRAM_IMG" ] || NVRAM_IMG="$MODDIR/nvram.img"
  if [ -f "$NVRAM_IMG" ]; then
    ui_print "writing calibrated NVRAM (64MB, please wait)..."
    dd if="$NVRAM_IMG" of="$BLK/nvram" bs=4M conv=fsync 2>>"$LOG" || { ui_print "nvram flash FAILED"; exit 5; }
  else
    ui_print "FATAL: nvram.img missing in package"; exit 4
  fi
else
  ui_print "NVRAM untouched."
fi

ui_print "wiping NVDATA (modem regenerates at boot)..."
if [ -f "$MODDIR/install/nvdata.img" ]; then
  dd if="$MODDIR/install/nvdata.img" of="$BLK/nvdata" bs=4M conv=fsync 2>>"$LOG" || ui_print "nvdata write failed (continue)"
elif [ -f "$MODDIR/nvdata.img" ]; then
  dd if="$MODDIR/nvdata.img" of="$BLK/nvdata" bs=4M conv=fsync 2>>"$LOG" || ui_print "nvdata write failed (continue)"
else
  dd if=/dev/zero of="$BLK/nvdata" bs=4M conv=fsync 2>>"$LOG" || ui_print "nvdata zero failed (continue)"
fi
mkdir -p /mnt/vendor/nvdata 2>/dev/null
chmod 0771 /mnt/vendor/nvdata 2>/dev/null
chown 1000:1000 /mnt/vendor/nvdata 2>/dev/null || true

ui_print "staging module bits..."
mkdir -p "$MODDIR/vendor/lib/modules" 2>/dev/null
# module already unzipped at $MODDIR (magisk template did install_module)
# free storage: remove the big templates once used (keep install/bin glue)
rm -f "$MODDIR/install/nvram.img" "$MODDIR/install/nvdata.img" 2>/dev/null
rm -f "$MODDIR/nvram.img" "$MODDIR/nvdata.img" 2>/dev/null

ui_print "done. Reboot to system; check /data/local/tmp/pox_imei_patcher.log"
exit 0
