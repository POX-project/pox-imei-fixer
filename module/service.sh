#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- late_start service.
#  * re-asserts any props a stock ROM may clobber (idempotent)
#  * verifies md_patcher actually landed this boot (fallback load)
#  * runs the VoLTE/VoWiFi stack report once per boot (rotated log)
# ---------------------------------------------------------------------------
MODDIR=${0%/*}
LOG=/data/local/tmp/pox_imei_patcher.log
(
echo "---- pox service.sh $(date 2>/dev/null) ----"
if [ -x "$MODDIR/install/bin/glue_props.sh" ]; then
  "$MODDIR/install/bin/glue_props.sh" live >>"$LOG" 2>&1 || true
fi
if [ -x "$MODDIR/install/bin/stack_report.sh" ]; then
  "$MODDIR/install/bin/stack_report.sh" >>"$LOG" 2>&1 || true
fi
# fallback patcher load (post-fs-data may have raced ahead of module data)
if ! dmesg 2>/dev/null | grep -qa "md_patcher:"; then
  if [ -x "$MODDIR/install/bin/pick_module.sh" ]; then
    "$MODDIR/install/bin/pick_module.sh" "$MODDIR/vendor/lib/modules" >>"$LOG" 2>&1 || true
  fi
fi
dmesg 2>/dev/null | grep -a md_patcher | tail -8 >>"$LOG"
) >>"$LOG" 2>&1
exit 0
