#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- VoLTE / VoWiFi stack compatibility reporter.
# Work anywhere (recovery or in-OS). Detects which pieces of the MTK telephony
# stack the current ROM actually carries, and writes a plain report the user
# can share when asking for help.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib.sh"

OUT=${POX_STACK_REPORT:-/data/local/tmp/pox_stack_report.txt}
SRC="$(dirname "$0")/.."

: > "$OUT" 2>/dev/null
rep() { echo "$*" >> "$OUT"; }

rep "POX VoLTE/VoWiFi stack report — $(date 2>/dev/null)"
rep "kernel: $(pox_kernel)  device: $(pox_device)  chipid: $(pox_chipid)  region: $(pox_region)"
rep ""

V=/vendor
rep "-- vendor binaries / RIL ------------------------------------------"
for f in bin/volte_imsm_93 bin/volte_stack bin/volte_ua bin/volte_imcb \
         bin/volte_md_status bin/hw/mtkfusionrild lib64/libmtk-ril.so \
         lib64/libstrongswan.so lib64/libcharon-ss.so lib64/libipsec_ims_shr.so \
         etc/ipsec/ipsec.conf etc/ipsec/ipsec.d/cacerts; do
  if [ -e "$V/$f" ]; then rep "  [ OK ] /vendor/$f"; else rep "  [-- MISS] /vendor/$f"; fi
done
rep "-- IMS assists (system side) --------------------------------------"
for f in priv-app/ImsService/ImsService.apk \
         etc/permissions/privapp-permissions-mediatek-ims.xml \
         framework/ims-common.jar framework/mediatek-ims-common.jar \
         framework/mediatek-ims-base.jar \
         priv-app/ImsServiceEntitlement/ImsServiceEntitlement.apk; do
  found=""
  for base in /system /system_root /; do
    [ -e "$base/$f" ] && { found="$base/$f"; break; }
  done
  if [ -n "$found" ]; then rep "  [ OK ] /system/$f ($found)"; else rep "  [-- MISS] /system/$f"; fi
done
rep "-- vintf HAL visibility --------------------------------------------"
for hal in "vendor.mediatek.hardware.mtkradioex" "android.hardware.radio" "android.hardware.radio.config"; do
  if grep -qs "$hal" "$V/etc/vintf/manifest.xml" "$V"/etc/vintf/manifest/*.xml 2>/dev/null; then
    rep "  [ OK ] hal $hal declared"
  else
    rep "  [-- MISS] hal $hal (vintf fragment would be needed)"
  fi
done
rep "-- props -----------------------------------------------------------"
for p in persist.vendor.volte_support persist.vendor.ims_support \
         persist.vendor.mims_support persist.vendor.mtk.volte.enable \
         persist.vendor.mtk_wfc_support ro.vendor.md_auto_setup_ims \
         ro.vendor.mtk_md1_support ro.vendor.mtk_ril_mode \
         persist.vendor.radio.ims.pdn.notify persist.vendor.mtk_dynamic_ims_switch; do
  v=$(getp "$p"); [ -z "$v" ] && v="(unset)"
  rep "  $p=$v"
done
rep ""
rep "Interpretation: any '[-- MISS]' on /vendor items usually means this"
rep "ROM replaced the stock (MIUI) vendor partition; VoLTE/VoWiFi cannot"
rep "be stitched in from userspace alone -- keep/reflash the MIUI vendor."
rep "MISS on ImsService apk/framework jars means the ROM device tree"
rep "lacks the MTK IMS framework glue; VoLTE will not register even with"
rep "a fixed IMEI. Ask the ROM maintainer to enable mtk_ims_* in the tree."

log "stack_report -> $OUT"
cat "$OUT" 2>/dev/null >> "$POX_LOG" 2>/dev/null
echo "$OUT" >&2
exit 0
