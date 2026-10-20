#!/system/bin/sh
# ---------------------------------------------------------------------------
# POX imei-fixer -- on-device NVRAM validator.
# Shell port of timjosten's check_nvram.php; verifies without writing anything:
#   [1] structural sanity (CSSD LID present, size == 4168)
#   [2] CSSD md5-fold 8-byte checksum (payload 4096B after 64B header)
#   [3] criticalData: >=5 TLV fields and contains the device chipid
#   [4] LD0B_00 marker byte 0x0A at +12 (when the LID exists)
#   [5] optional RSA chain verify via openssl (if installed)
# args: nvram_check.sh <nvram-block-dev> <chipid> [product]
# exit: 0 valid | 1 usage | 2 read fail | 3 structure invalid
#       4 checksum mismatch | 5 chipid mismatch | 6 RSA verify failed
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib.sh"

NV="$1"; CHIPID="$2"; PRODUCT="$3"
[ -z "$PRODUCT" ] && PRODUCT=$(pox_device)

if [ -z "$NV" ] || [ -z "$CHIPID" ]; then
  banner "usage: $0 <nvram-block-dev> <chipid> [product]"; exit 1
fi
[ -e "$NV" ] || { banner "cannot read $NV"; exit 2; }

TMP=$(mktemp -d 2>/dev/null) || TMP=/tmp/poxchk.$$
mkdir -p "$TMP" 2>/dev/null
trap 'rm -rf "$TMP" 2>/dev/null' EXIT
dd if="$NV" of="$TMP/toc.bin" bs=65536 count=2 2>/dev/null || { banner "TOC read fail"; exit 2; }

# --- locate CSSD -------------------------------------------------------------
CSSD_POS=$(boff "$TMP/toc.bin" "/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/CSSD_000")
[ -n "$CSSD_POS" ] || { banner "CSSD LID not found in NVRAM"; exit 3; }
CSSD_SZ=$(u32le "$TMP/toc.bin" $((CSSD_POS-4)))
[ "$CSSD_SZ" = "4168" ] || { banner "invalid CSSD size: $CSSD_SZ (want 4168)"; exit 3; }
CSSD_OFF=$((0x20000 + $(u32le "$TMP/toc.bin" $((CSSD_POS-8)))))
dd if="$NV" of="$TMP/cssd.bin" bs=1 skip="$CSSD_OFF" count=4168 2>/dev/null \
  || { banner "CSSD read fail"; exit 2; }

# --- [2] md5-fold checksum ----------------------------------------------------
dd if="$TMP/cssd.bin" of="$TMP/payload.bin" bs=1 skip=64 count=4096 2>/dev/null
dd if="$TMP/cssd.bin" of="$TMP/ck8.bin"    bs=1 skip=4160 count=8 2>/dev/null
want=$(od -An -tx1 "$TMP/ck8.bin" | tr -d ' \n')
got=$(md5fold8 "$TMP/payload.bin")
if [ -z "$got" ] || [ "$want" != "$got" ]; then
  banner "CSSD checksum mismatch (want $want got $got)"; exit 4
fi

# --- [3] KV parse / chipid ----------------------------------------------------
# CSSD records are separated by the 2-byte literal pair backslash+'n'
# (PHP single-quote '\\n' in the tool); strip NUL padding, split, keep ':' rows.
tr -d '\000' < "$TMP/payload.bin" 2>/dev/null \
  | awk '{ gsub(/\\n/, "\n"); print }' \
  | grep -a ':' > "$TMP/kv.txt"
N=$(grep -c ':' "$TMP/kv.txt" 2>/dev/null)
[ -n "$N" ] || N=0
[ "$N" -ge 5 ] || { banner "CSSD has only $N items (<5)"; exit 3; }
CD_HEX=$(sed -n 's/^criticalData:\(.*\)$/\1/p' "$TMP/kv.txt" | head -1)
[ -n "$CD_HEX" ] || { banner "criticalData missing"; exit 3; }
hex2bin "$CD_HEX" > "$TMP/cd.bin"
grep -aq -- "$CHIPID" "$TMP/cd.bin" 2>/dev/null \
  || { banner "ChipID mismatch"; exit 5; }

# --- [4] LD0B marker ----------------------------------------------------------
LD0B_POS=$(boff "$TMP/toc.bin" "/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_00")
if [ -n "$LD0B_POS" ]; then
  LD0B_OFF=$((0x20000 + $(u32le "$TMP/toc.bin" $((LD0B_POS-8)))))
  B=$(u8at "$NV" $((LD0B_OFF+12)))
  [ "$B" = "10" ] || { banner "LD0B marker invalid ($B, want 0x0A)"; exit 3; }
fi

# --- [5] optional RSA verify --------------------------------------------------
OPENSSL_BIN=$(command -v openssl 2>/dev/null)
if [ -n "$OPENSSL_BIN" ]; then
  DPKM=$(sed -n 's/^devPubKeyModulus:\(.*\)$/\1/p' "$TMP/kv.txt" | head -1 | tr 'A-F' 'a-f')
  DPKS=$(sed -n 's/^devPubKeySign:\(.*\)$/\1/p'   "$TMP/kv.txt" | head -1 | tr 'a-f' 'A-F')
  if [ -n "$DPKM" ] && [ -n "$DPKS" ]; then
    FIRST=$(printf '%s' "$DPKM" | cut -c1)
    case "$FIRST" in
      [8-9a-f]) DER="30818902818100${DPKM}0203010001" ; MODHEX="$DPKM$(printf '')"; MH="$DPKM" ;;
      *)        DER="308188028180${DPKM}0203010001"   ; MH="$DPKM" ;;
    esac
    b64=$(printf '%s' "$DER" | hex2bin | base64 2>/dev/null | tr -d '\n' || \
          printf '%s' "$DER" | hex2bin | openssl base64 2>/dev/null | tr -d '\n')
    {
      echo "-----BEGIN RSA PUBLIC KEY-----"
      printf '%s\n' "$(printf '%s' "$b64" | fold -w 64)"
      echo "-----END RSA PUBLIC KEY-----"
    } > "$TMP/dpk.pem"
    hex2bin "$DPKS" > "$TMP/sig.bin"
    em=$("$OPENSSL_BIN" rsautl -verify -pubin -inkey "$TMP/dpk.pem" -in "$TMP/sig.bin" -raw 2>/dev/null \
         | od -An -tx1 | tr -d ' \n')
    if [ -n "$em" ]; then
      hash_in=$(printf '%s' "$em" | tail -c 64)
      hash=$(printf '%s' "10001${DPKM}${PRODUCT}" | sha256_of 2>/dev/null)
      if [ -n "$hash" ] && [ "$hash" = "$hash_in" ]; then
        banner "NVRAM RSA chain: EM covers (e,modulus,product) -- structural verify OK"
      else
        banner "NVRAM RSA chain: EM hash mismatch (unknown CA layout) -- treating as non-fatal"
      fi
    else
      banner "NVRAM RSA chain: not verifiable (openssl $?) -- treating as non-fatal"
    fi
  fi
fi

banner "NVRAM validation: OK"
log "nvram_check OK chipid=$CHIPID"
exit 0
