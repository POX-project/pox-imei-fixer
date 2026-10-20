#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- property glue.
# Applies the full set of telephony props found in timjosten's begonia build
# (system build.prop) via resetprop when a root context is available. Runs at:
#   * module post-fs-data / service (in-OS path)
#   * recovery install (idempotent append to /vendor/build.prop happens in
#     apply_props_recover() -- vendor/build.prop props apply at every boot
#     even on ROMs without any root manager).
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib.sh"

POX_PROPS="
persist.vendor.volte_support=1
persist.vendor.ims_support=1
persist.vendor.mims_support=2
persist.vendor.mtk.volte.enable=1
persist.vendor.mtk_dynamic_ims_switch=1
persist.vendor.mtk_wfc_support=1
persist.vendor.mtk.wfc.enable=1
persist.vendor.mtk.vilte.enable=1
persist.vendor.mtk.viwifi.enable=1
persist.vendor.radio.ims.pdn.notify=1
persist.radio.calls.on.ims=1
persist.radio.VT_ENABLE=1
persist.dbg.ims_volte_enable=1
persist.dbg.volte_avail_ovr=1
persist.dbg.vt_avail_ovr=1
persist.dbg.wfc_avail_ovr=1
persist.data.iwlan.enable=true
persist.data.iwlan=1
persist.data.iwlan.ipsec.ap=1
ro.telephony.iwlan_operation_mode=default
telephony.active_modems.max_count=2
ro.vendor.md_auto_setup_ims=1
ro.vendor.mtk_ril_mode=c6m_1rild
vendor.ril.mtk=1
"

# --- live application (root env) ---------------------------------------------
apply_live() {
  local n=0
  for kv in $POX_PROPS; do
    k=${kv%%=*}; v=${kv#*=}
    if rp "$k" "$v"; then n=$((n+1)); fi
  done
  log "glue_props: applied $n props (live)"
}

# --- persistent append (recovery path) ---------------------------------------
# Appends key=value lines to a build.prop file if not already set there.
apply_file() {
  local file="$1"
  [ -w "$file" ] || { chmod 644 "$file" 2>/dev/null || return 1; }
  grep -qs "POX-VOLTE-BEGIN" "$file" || {
    printf '\n# POX-VOLTE-BEGIN (added by pox_imei_fixer)\n' >> "$file"
    for kv in $POX_PROPS; do echo "$kv" >> "$file"; done
    printf '# POX-VOLTE-END\n' >> "$file"
    return 0
  }
  # block already there -- verify each key exists, append missing only
  local k v found=0
  for kv in $POX_PROPS; do
    k=${kv%%=*}; v=${kv#*=}
    grep -qsE "^$k=" "$file" || { echo "$kv" >> "$file"; found=$((found+1)); }
  done
  log "glue_props: $file patched (missing rows: $found)"
  return 0
}

apply_props_recover() {
  mount_vendor
  local f=/vendor/build.prop
  if [ -e "$f" ]; then apply_file "$f"; else log "glue_props: /vendor/build.prop missing"; fi
  # also mirror into /odm/etc/build.prop (some MIUI vendors only read odm)
  if [ -e /vendor/odm/etc/build.prop ]; then apply_file /vendor/odm/etc/build.prop; fi
}

case "$1" in
  live)    apply_live ;;
  recover) apply_props_recover ;;
  both)    apply_live; apply_props_recover ;;
  *) apply_live ;;
esac
exit 0
