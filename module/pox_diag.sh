#!/system/bin/sh
MODDIR=${0%/*}
# -----
# POX imei-fixer -- diagnostics one-shooter. Run from a root shell:
#   sh /data/adb/modules/pox_imei_fixer/pox_diag.sh
# ---------------------------------------------------------------------------
echo "===== POX diag $(date 2>/dev/null) ====="
echo "-- kernel"; uname -a
echo "-- chipid / device / hwc"
getprop ro.boot.chipid; getprop ro.product.device; getprop ro.boot.hwc
echo "-- kernel module state"
grep -a md_patcher /proc/modules 2>/dev/null || echo "(md_patcher NOT loaded)"
dmesg 2>/dev/null | grep -a md_patcher | tail -12 || echo "(no dmesg access)"
echo "-- modem daemons"
ps -A 2>/dev/null | grep -aE "volte|mtkfusionrild|rild" || echo "(none running)"
echo "-- ims sockets"
ls -l /dev/socket 2>/dev/null | grep -aE "volte|rild" || true
ls /dev/radio 2>/dev/null || true
echo "-- imei readable"
service call iphonesubinfo 1 2>/dev/null || true
echo "-- props snapshot"
getprop 2>/dev/null | grep -iE "volte|ims|wfc|md1|ril_mode|mims" || true
echo "-- patcher log tail"
tail -40 /data/local/tmp/pox_imei_patcher.log 2>/dev/null || true
echo "-- stack report"
cat /data/local/tmp/pox_stack_report.txt 2>/dev/null || \
  ([ -x "$MODDIR/install/bin/stack_report.sh" ] && "$MODDIR/install/bin/stack_report.sh" 2>/dev/null)
echo "===== end diag ====="
