#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- master installer (runs in recovery via edify, or in-OS
# via customize.sh much of the same flow). Behaviour:
#   1) sanity probe + stack report
#   2) automated modem-partition backup
#   3) validate CURRENT nvram;
#        - POX_MODE=validate-only  -> stop after report
#        - POX_MODE=repair-if-invalid (default) -> overwrite ONLY if invalid
#        - POX_MODE=force          -> overwrite regardless
#   4) write nvram.img (when warranted) + wipe nvdata via nvdata.img
#   5) fix nvdata perms (1000:1000 0771)
#   6) stage vendor bits (rc + picker script + inits + vintf fragment) when
#      possible; always copies module files into our own module dir.
#   7) apply telephony props to /vendor/build.prop (recovery path)
#   8) read-back verification of what we wrote
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib.sh"

SRC=""
[ -d /tmp/install ] && SRC=/tmp/install
[ -z "$SRC" ] && [ -f "./post-fs-data.sh" ] && SRC=.
SRC="${SRC:-$(pwd)}"
BINDIR="$SRC/bin"

POX_MODE=${POX_MODE:-repair-if-invalid}
[ -f "$SRC/mode" ] && POX_MODE=$(cat "$SRC/mode" 2>/dev/null)
banner "POX imei-fixer install (mode=$POX_MODE)"

NVRAM_BL=$(pblock nvram)
NVDATA_BL=$(pblock nvdata)
[ -z "$NVRAM_BL" ] && { banner "FATAL: nvram partition not found"; exit 3; }
[ -z "$NVDATA_BL" ] && { banner "FATAL: nvdata partition not found"; exit 3; }

CHIP=$(pox_chipid)
DEV=$(pox_device)

# --- 2) backup ---------------------------------------------------------------
"$BINDIR/backup.sh" || true

# --- 3) validation of current nvram ------------------------------------------
banner "Validating current NVRAM (chipid=$CHIP)..."
if "$BINDIR/nvram_check.sh" "$NVRAM_BL" "$CHIP" "$DEV"; then
  NV_VALID=1
  banner "Existing NVRAM is VALID (signed chain OK)."
else
  NV_VALID=0
  banner "Existing NVRAM is INVALID/missing ($?)."
fi

# --- decide whether to write -------------------------------------------------
WRITE=0
case "$POX_MODE" in
  validate-only) WRITE=0 ;;
  force)         WRITE=1 ;;
  *)             [ "$NV_VALID" = 0 ] && WRITE=1 || WRITE=0 ;;
esac

if [ "$WRITE" = 1 ]; then
  NVRAM_IMG=$(ls "$SRC/../nvram.img" "$SRC/nvram.img" 2>/dev/null | head -1)
  if [ -z "$NVRAM_IMG" ]; then
    banner "FATAL: nvram.img not found in package"
    exit 4
  fi
  banner "Writing calibrated NVRAM (${NVRAM_IMG##*/})..."
  assert_dd() { dd if="$1" of="$NVRAM_BL" bs=4M conv=fsync 2>>"$POX_LOG" || { banner "FATAL: nvram write failed"; exit 5; }; }
  assert_dd "$NVRAM_IMG"
  sync
else
  banner "Keeping existing NVRAM (no write)."
fi

# nvdata wipe is ALWAYS safe: modem rebuilds it from nvram at boot
NVDATA_IMG=$(ls "$SRC/../nvdata.img" "$SRC/nvdata.img" 2>/dev/null | head -1)
banner "Rebuilding NVDATA (wiped; modem regenerates on boot)..."
if [ -n "$NVDATA_IMG" ]; then
  dd if="$NVDATA_IMG" of="$NVDATA_BL" bs=4M conv=fsync 2>>"$POX_LOG" \
    || { banner "FATAL: nvdata write failed"; exit 6; }
else
  dd if=/dev/zero of="$NVDATA_BL" bs=4M conv=fsync 2>>"$POX_LOG" \
    || { banner "FATAL: nvdata zero failed"; exit 6; }
fi
sync

# --- 5) perms -----------------------------------------------------------------
if mount_nvdata; then
  chmod 0771 /mnt/vendor/nvdata 2>/dev/null
  chown 1000:1000 /mnt/vendor/nvdata 2>/dev/null || chown 1000 1000 /mnt/vendor/nvdata 2>/dev/null
  log "glue: nvdata perms set"
  umount /mnt/vendor/nvdata 2>/dev/null
fi

# --- 6) vendor staging + module staging --------------------------------------
if [ "$POX_MODE" = "validate-only" ]; then
  banner "validate-only mode: no vendor/module staging."
else
  # 6a) vendor files (persistent across reboot, survives ROM flashes) -- only
  #     when /vendor is writable (recovery). In-OS installs land as a module.
  if [ -d /vendor ] && mount_vendor; then
    mkdir -p /vendor/bin /vendor/etc/init /vendor/lib/modules /vendor/etc/vintf/manifest
    # picker script + module files
    cp -f "$BINDIR/pick_module.sh" /vendor/bin/pox_module.sh 2>/dev/null
    cp -f "$BINDIR/lib.sh" /vendor/bin/lib.sh 2>/dev/null
    # copy all bundled modules (kernel pick happens at every boot)
    cp -f "$SRC"/vendor/lib/modules/md_patcher-*.ko /vendor/lib/modules/ 2>/dev/null
    # vendor init rc that loads the picker at post-fs-data
    if [ -f "$SRC/vendor/etc/init/md_patcher.rc" ]; then
      cp -f "$SRC/vendor/etc/init/md_patcher.rc" /vendor/etc/init/md_patcher.rc
    else
      cat > /vendor/etc/init/md_patcher.rc <<'EOF2'
service md_patcher_exec /system/bin/sh /vendor/bin/pox_module.sh
    class core
    user root
    group root
    oneshot
    disabled

on post-fs-data
    start md_patcher_exec
EOF2
    fi
    # optional vintf fragment for ROMs missing the radio HALs
    VINTF_HAS=$(grep -qs "vendor.mediatek.hardware.mtkradioex" \
        /vendor/etc/vintf/manifest.xml /vendor/etc/vintf/manifest/*.xml && echo yes)
    if [ -f "$SRC/etc/vintf_pox_radio_fragment.xml" ] && [ "$VINTF_HAS" != "yes" ]; then
      cp -f "$SRC/etc/vintf_pox_radio_fragment.xml" /vendor/etc/vintf/manifest/pox_radio.xml 2>/dev/null
      log "staging: vintf fragment installed"
    fi
    chcon u:object_r:vendor_file:s0 /vendor/bin/pox_module.sh /vendor/bin/pox_lib.sh \
         /vendor/lib/modules/md_patcher-*.ko /vendor/etc/init/md_patcher.rc 2>/dev/null
    umount /vendor 2>/dev/null
    banner "Vendor staging done (rc + modules)."
  else
    banner "In-OS install detected; relying on module-based patching (see /data/adb/modules)."
  fi

  # 6b) persistent props (vendor build.prop append on recovery; live resetprop now)
  if [ -d /vendor ]; then
    "$BINDIR/glue_props.sh" both || true
  else
    "$BINDIR/glue_props.sh" live || true
  fi
fi

# --- 7) stack report -----------------------------------------------------------
"$BINDIR/stack_report.sh" >/dev/null 2>&1 || true

# --- 8) read-back verify --------------------------------------------------------
if [ "$WRITE" = 1 ]; then
  banner "Verifying written NVRAM ..."
  TMP=$(mktemp -d 2>/dev/null) || TMP=/tmp/poxver.$$
  mkdir -p "$TMP"
  dd if="$NVRAM_BL"   of="$TMP/now.bin" bs=1M count=2 2>/dev/null
  dd if="$NVRAM_IMG"  of="$TMP/ref.bin" bs=1M count=2 2>/dev/null
  H1=$(sha256_of "$TMP/ref.bin"); H2=$(sha256_of "$TMP/now.bin")
  if [ -n "$H1" ] && [ "$H1" = "$H2" ]; then
    banner "Read-back verify: OK (TOC+CSSD region matches source image)"
  else
    banner "WARNING: read-back region differs (wrote=$H1 read=$H2); check $POX_LOG"
    log "verify: MISMATCH wrote=$H1 read=$H2"
  fi
  rm -rf "$TMP" 2>/dev/null
fi

banner "POX install finished. MODE=$POX_MODE"
log "install.sh: done"
exit 0
