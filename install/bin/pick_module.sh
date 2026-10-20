#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- kernel-aware md_patcher module picker.
# Selects the .ko matching the RUNNING kernel (uname -r), with progressively
# looser matching, and insmods it (with -f fallback). Used by:
#   * vendor rc path   (recovery flash, /vendor/bin/pox_module.sh symlink)
#   * magisk module    (module_post-fs loader calls us with $MODDIR)
#   * TWRP install     (install.sh)
# args: pick_module.sh <dir-containing-md_patcher-*.ko> [debug]
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib.sh"

DIR="$1"
DBG="$2"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  banner "pick_module: dir '$DIR' not found"; exit 2
fi

K=$(pox_kernel)
[ -z "$K" ] && K=$(cat /proc/version 2>/dev/null | awk -F'version ' '{print $2}' | awk '{print $1}')
[ -z "$K" ] && { banner "pick_module: cannot read kernel version"; exit 3; }

PICK=""
# 1) exact release match: md_patcher-<uname -r>.ko
if [ -f "$DIR/md_patcher-$K.ko" ]; then
  PICK="$DIR/md_patcher-$K.ko"
fi
# 2) same base version + root-manager flavour (KSU / APatch builds)
if [ -z "$PICK" ]; then
  base=${K%%-*}
  want=""
  [ -d /data/adb/ksu ] && want=KSU
  [ -d /data/adb/ap ]  && want=APatch
  if [ -n "$want" ]; then
    for f in "$DIR"/md_patcher-"$base"-*.ko; do
      [ -e "$f" ] || break
      case "$f" in
        *"-$want-"*) PICK="$f"; break ;;
      esac
    done
  fi
fi
# 3) any module built from the same base kernel version
if [ -z "$PICK" ]; then
  base=${K%%-*}
  for f in "$DIR"/md_patcher-"$base"*.ko; do
    [ -e "$f" ] && PICK="$f" && break
  done
fi
# 4) classic reference build fallback, then first available
if [ -z "$PICK" ]; then
  for probe in "$DIR/md_patcher-4.14.186.ko" "$DIR/md_patcher-4.14.141.ko"; do
    [ -f "$probe" ] && PICK="$probe" && break
  done
fi
if [ -z "$PICK" ]; then
  PICK=$(ls "$DIR"/md_patcher-*.ko 2>/dev/null | head -1)
fi

if [ -z "$PICK" ]; then
  banner "pick_module: no md_patcher-*.ko in '$DIR'"
  exit 4
fi

bname=$(basename "$PICK")
[ "$DBG" = "debug" ] && banner "pick_module: kernel=$K -> $bname"

# insmod path search
INS=""
for c in insmod "/data/adb/magisk/busybox" /system/bin/insmod /sbin/insmod; do
  if [ "$c" = "/data/adb/magisk/busybox" ]; then
    [ -x "$c" ] && INS="$c insmod" && break
  elif command -v "$c" >/dev/null 2>&1; then
    INS="$c"; break
  fi
done
# static helper shipped with the package (last resort)
if [ -z "$INS" ]; then
  for d in "$(dirname "$0")" /data/adb/modules/pox_imei_fixer/bin /vendor/bin; do
    [ -x "$d/insmod2" ] && INS="$d/insmod2" && break
  done
fi

if [ -z "$INS" ]; then
  banner "pick_module: no insmod available (skip)"
  exit 5
fi
if $INS "$PICK" >>"$POX_LOG" 2>&1; then
  banner "md_patcher loaded: $bname"
elif $INS -f "$PICK" >>"$POX_LOG" 2>&1; then
  banner "md_patcher loaded (forced): $bname"
else
  banner "md_patcher insmod FAILED for $bname (see $POX_LOG)"
  exit 6
fi
dmesg 2>/dev/null | grep -a md_patcher | tail -6 >>"$POX_LOG" 2>/dev/null
exit 0
