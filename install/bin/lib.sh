#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer shared shell helpers.
# POSIX sh + busybox/toybox only (runs in TWRP, OrangeFox, APatch, KernelSU,
# FolkPatch, Magisk). No openssl/awk-fancy assumptions.
# ---------------------------------------------------------------------------

POX_LOG=/data/local/tmp/pox_imei_fixer.log
POX_BACKUP_ROOT=/sdcard/Pox_Backups

#============= logging =======================================================
log()  { echo "$*" >> "$POX_LOG" 2>/dev/null; }
ui()   { echo "$*" >&2; }          # recovery captures stderr for ui_print
banner(){ ui "???? $*"; log "[UI] $*"; }

#============= partition helpers =============================================
# Resolve /dev/block/.../by-name/<part> across MTK layouts.
pblock() { # $1 = partition name
  for base in /dev/block/platform/bootdevice/by-name \
              /dev/block/by-name \
              /dev/block/bootdevice/by-name; do
    if [ -e "$base/$1" ]; then echo "$base/$1"; return 0; fi
  done
  return 1
}

#============= property helpers ==============================================
getp() { # $1 = prop
  if command -v getprop >/dev/null 2>&1; then getprop "$1"
  elif [ -x /system/bin/getprop ]; then /system/bin/getprop "$1"
  elif [ -x /sbin/getprop ];       then /sbin/getprop "$1"
  else echo ""
  fi
}
setp() { # $1 prop, $2 value -- best effort (root contexts only)
  if command -v setprop >/dev/null 2>&1; then setprop "$1" "$2"
  elif [ -x /system/bin/setprop ]; then /system/bin/setprop "$1" "$2"
  fi
}
rp() { # resetprop wrapper: finds the boot-loader's own resetprop or module one
  # $POX_RESETPROP override wins; then managers' binaries; then bundled copy
  for rpbin in "$POX_RESETPROP" \
               "$(dirname "$0")/../../bin/resetprop" \
               /data/adb/magisk/resetprop \
               /data/adb/ksu/bin/resetprop \
               /data/adb/ap/bin/resetprop \
               /sbin/resetprop /system/xbin/resetprop; do
    [ -n "$rpbin" ] && [ -x "$rpbin" ] && "$rpbin" "$1" "$2" >/dev/null 2>&1 && return 0
  done
  setp "$1" "$2" 2>/dev/null
}

#============= generic =======================================================
have() { command -v "$1" >/dev/null 2>&1; }

md5_of() { # $1 file ; prints hash
  if   have md5sum;   then md5sum "$1" | cut -d' ' -f1
  elif have toybox;   then toybox md5sum "$1" | cut -d' ' -f1
  elif have busybox;  then busybox md5sum "$1" | cut -d' ' -f1
  else echo ""
  fi
}

sha256_of() { # $1 file
  if   have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif have toybox;    then toybox sha256sum "$1" | cut -d' ' -f1
  elif have busybox;   then busybox sha256sum "$1" | cut -d' ' -f1
  else md5_of "$1"
  fi
}

# little-endian u32 at $offset of file $1  -> prints integer
u32le() { # $1 file, $2 offset
  dd if="$1" bs=1 skip="$2" count=4 2>/dev/null | od -An -tu4 | awk '{print $1}'
}

u8at() { # $1 file, $2 offset -> prints byte as 0..255
  dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | awk '{print $1}'
}

# byte-find of ASCII $2 inside $1 (streamed, full-file). prints byte offset or ""
boff() { # $1 file, $2 ascii needle
  grep -abo -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# xor-fold md5: byte-fold 8 bytes (hex pairs) of 16-byte md5
md5fold8() { # $1 file -> 16 hex chars (8 folded bytes)
  h=$(md5_of "$1"); [ -z "$h" ] && echo "" && return 1
  a=$(printf '%s' "$h" | cut -c1-16); b=$(printf '%s' "$h" | cut -c17-32)
  o=""; i=1
  while [ $i -le 16 ]; do
    xa=$(awk -v s="$a" -v i="$i" 'BEGIN{print "0x" substr(s,i,2)}')
    xb=$(awk -v s="$b" -v i="$i" 'BEGIN{print "0x" substr(s,i,2)}')
    o="$o$(printf '%02x' $((xa ^ xb)))"
    i=$((i+2))
  done
  echo "$o"
}

#----------- hex -> raw bytes (POSIX/awk) ------------------------------------
hex2bin() { # $1 = hex string (even length); raw bytes on stdout
  awk -v h="$1" 'BEGIN{
    L=length(h);
    for(i=1;i<=L;i+=2){ printf "%c", ("0x" substr(h,i,2)) + 0; }
  }'
}
#----------- u32 <-> raw little-endian-----------------------------------------
u32hexle() { # $1 = integer -> 4 little-endian hex bytes of it
  printf '%08x' "$1" | awk '{ printf substr($0,7,2) substr($0,5,2) substr($0,3,2) substr($0,1,2) }'
}

#============= device/region =================================================
pox_device() {
  d=$(getp ro.product.device); [ -z "$d" ] && d=$(getp ro.product.product)
  [ -z "$d" ] && d=$(getp ro.product.bootimage.name | sed 's/lineage_//')
  echo "$d"
}
pox_chipid() { getp ro.boot.chipid; }
pox_region() {
  hw=$(getp ro.boot.hwc)
  case "$hw" in CN|cn) echo cn;; IN|in) echo india;; *) echo global;; esac
}
pox_kernel() { uname -r 2>/dev/null; }

# mounts (best effort for the cmdlets we call)
mount_vendor() {
  if ! grep -q " /vendor " /proc/mounts 2>/dev/null; then
    BLK=$(pblock vendor) && mount -t ext4 "$BLK" /vendor 2>/dev/null
  fi
  grep -q " /vendor " /proc/mounts 2>/dev/null && mount -o remount,rw /vendor 2>/dev/null
  true
}
mount_system()  { grep -q " /system_root\| /system " /proc/mounts || mount -t ext4 "$(pblock system)" /system_root 2>/dev/null || mount "system" 2>/dev/null; }
mount_nvdata()  { [ -d /mnt/vendor/nvdata ] || mkdir -p /mnt/vendor/nvdata; grep -q " /mnt/vendor/nvdata " /proc/mounts || mount -t ext4 "$(pblock nvdata)" /mnt/vendor/nvdata 2>/dev/null; true; }
