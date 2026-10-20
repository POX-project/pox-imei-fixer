#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/pox_imei_patcher.log
(
echo "---- pox post-fs-data $(date) uname=$(uname -r) ----"
# 1) pick + load the right md_patcher-<kernel>.ko
if [ -f "$MODDIR/picker.sh" ]; then
  "$MODDIR/picker.sh" "$MODDIR/vendor/lib/modules" >>"$LOG" 2>&1
elif [ -f /vendor/bin/pox_module.sh ]; then
  /vendor/bin/sh /vendor/bin/pox_module.sh "$MODDIR/vendor/lib/modules" >>"$LOG" 2>&1
else
  # inline fallback: try every module; wrong vermagic fails harmlessly
  K=$(uname -r)
  pick=""
  for f in "$MODDIR"/vendor/lib/modules/md_patcher-*$K*.ko; do
    [ -e "$f" ] && pick="$f" && break
  done
  for f in "$MODDIR"/vendor/lib/modules/md_patcher-*.ko; do
    [ -n "$pick" ] && break
    [ -e "$f" ] && pick="$f"
  done
  if [ -n "$pick" ]; then
    insmod "$pick" >>"$LOG" 2>&1 || insmod -f "$pick" >>"$LOG" 2>&1 || \
      ([ -x "$MODDIR/bin/insmod2" ] && "$MODDIR/bin/insmod2" "$pick" >>"$LOG" 2>&1)
    echo "inline load: $pick" >>"$LOG"
  fi
fi

# 2) vendor-overlay bind mounts (ROM-modification rescue: a file dropped into
#    $MODDIR/vendor_overlay/<subpath> overrides an EXISTING /vendor/<subpath>;
#    bind mounts cannot create missing nodes on a read-only vendor)
for f in $(cd "$MODDIR/vendor_overlay" 2>/dev/null && find . -type f | sed 's#^./##'); do
  target="/vendor/$f"
  src="$MODDIR/vendor_overlay/$f"
  if [ -e "$target" ] && mount -o bind "$src" "$target" 2>>"$LOG"; then
    echo "bind-mounted $src -> $target" >>"$LOG"
  else
    echo "vendor_overlay: no existing /vendor/$f target (skipped)" >>"$LOG"
  fi
done

# 3) CN begonia: force ro.boot.hwlevel=P0 via bundled static resetprop
if [ "$(getprop ro.boot.hwc 2>/dev/null)" = "CN" ] && [ -x "$MODDIR/bin/resetprop" ]; then
  "$MODDIR/bin/resetprop" ro.boot.hwlevel P0 >>"$LOG" 2>&1
  echo "hwlevel P0 applied (CN)" >>"$LOG"
fi
) >>"$LOG" 2>&1
exit 0
