# Architecture — how POX makes VoLTE / VoWiFi / IMEI work on MTK

This document explains the mechanism reverse-engineered from the working
reference (timjosten's `crDroid-v9.5-timjosten-begonia` ROM + `mtk_imei` tool),
and how the POX package replicates it on any ROM / device.

## 1. What actually makes calls & VoLTE work

On a MediaTek (MT6785 / begonia-class) phone, dialing and voice-over-LTE
depend on **four independent layers**. Every layer must be intact:

```
┌──────────────────────────────────────────────────────────────┐
│ 4. IMS user side   com.mediatek.ims (ImsService apk),        │ ── comes from /system
│                    framework jars mediatek-ims-*, MAL props  │   (ROM must enable in tree)
├──────────────────────────────────────────────────────────────┤
│ 3. MAL daemons     volte_imsm_93, volte_stack, volte_ua,     │ ── comes from /vendor
│                    volte_imcb, volte_md_status + strongswan/ │   (rebuild kept MIUI vendor)
│                    libipsec_ims_shr (VoWiFi IPsec)           │
├──────────────────────────────────────────────────────────────┤
│ 2. RILlayer   mtkfusionrild + mtkradioex@2.0 HIDL;      │ ── vendor/build.prop
│                    ro.vendor.mtk_ril_mode, md_auto_setup_ims │
├──────────────────────────────────────────────────────────────┤
│ 1. Modem/NVRAM    md1img (MOLY modem image) + NVRAM signed  │ ── partitions
│                    certificate chain (CSSD/LD0B)             │
└──────────────────────────────────────────────────────────────┘
```

The ROM keeps the **exact MIUI 12.5.8.0.RGGMIXM** modem/vendor pair, so layers
2 and 3 stay native. On top of that it adds only:

* `persist.dbg.{ims_volte_enable,volte_avail_ovr,vt_avail_ovr,wfc_avail_ovr}=1`
* iwlan feature props (`persist.data.iwlan*`, `ro.telephony.iwlan_operation_mode`)

POX ships exactly these as `module/system.prop` (systemless, re-applied each
boot) and, on the recovery path, appends them to `/vendor/build.prop`.

## 2. Why the IMEI part needs a kernel module

Modern MIUI/MTK phones validate the NVRAM **certificate chain at modem boot**:

1. `CSSD_000` (LID) carries the device's RSA-1024 *public modulus, exponent*,
   their signature by an upstream RSA-2048 CA, plus a `criticalData` blob
   (chipid, IMEI1/2, WiFi/BT MAC) signed by the RSA-1024 key itself.
2. The modem firmware embeds the CA-2048 **public key** — so the record chain
   must be signed by a key the running firmware (md1img on the `md1img`
   partition) actually trusts.
3. Aftermarket md1img builds (timjosten's ROM, Lineage/OFOX MTK trees) embed a
   *second* "aftermarket" CA public key next to the Xiaomi one, so freshly
   generated certificates are also accepted.

Unless you regenerate *both* the CSSD chain **and** the encrypted `LD0B_00`
IMEI block, `phonesky` / `mtkfusionrild` return `NULL` IMEIs and `iphonesubinfo`
calls fail. `bin/mtk_imei.php` does this signing job on the PC; the result is a
64 MiB `install/nvram.img` inside the flashable zip.

On **stock** (Xiaomi-signed) vendor+md1img pairs that were never unlocked for
aftermarket certs, the certificate chain still has to match the *running modem*,
i.e. the modem's embedded key. For that case the package ships
`vendor/lib/modules/md_patcher-<kernel>.ko`: a kernel module that, at boot,
locates the modem image copy in DRAM (EMI), swaps the embedded CA modulus with
one matching the certificate we wrote (via `MTK_SIP_KERNEL_EMIMPU_READ` SMC +
EMI-MPU remap), so the *original* vendor can be preserved on otherwise stock
ROMs. This is what the ROM's `post-fs-data.sh` + `insmod2` flow does.

## 3. The two installation paths

| | Recovery flash (TWRP/OrangeFox) | In-OS root (Magisk/KernelSU/APatch/FolkPatch) |
|---|---|---|
| driver | `META-INF/.../updater-script` → `install/bin/install.sh` | `MAGISK update-binary template` → `customize.sh` |
| backup | `install/bin/backup.sh` (all modem partitions + sha256, `/sdcard/Pox_Backups`) | same |
| validate | `install/bin/nvram_check.sh` (shell port of `check_nvram.php`) | same |
| nvram write | **only if invalid** (`mode` = `repair-if-invalid` / `force` / `validate-only`) | same |
| nvdata | wiped (modem regenerates from nvram at boot) | same |
| patcher | staged to `/vendor/lib/modules` + `/vendor/etc/init/md_patcher.rc` (survives ROM flashes) | module dir `/data/adb/modules/pox_imei_fixer` + `post-fs-data.sh` |
| props | appended to `/vendor/build.prop` | `module/system.prop` (resetprop each boot) |
| readback | TOC+CSSD region sha256 compare | — |

The template keeps Magisk's dual-binary installer: `META-INF/.../update-binary`
(shell, root-manager path) and `update-binary2` (ELF edify interpreter for
recovery), so **one zip serves both**.

## 4. Kernel-module selection (the "one .ko" bug)

The inherited template hardcoded `insmod /vendor/lib/modules/md_patcher.ko`,
but POX bundles **per-kernel builds** (SU/APatch/KSU/Rom variants). The new
loader chain is:

```
on post-fs-data (vendor rc OR module post-fs-data.sh)
  → pick_module.sh <dir>
      1. exact  : md_patcher-$(uname -r).ko
      2. flavour: md_patcher-<base>-{KSU|APatch}-*.ko (chosen by /data/adb/ksu|ap)
      3. base   : md_patcher-<base>*.ko   (base = ${K%%-*})
      4. classic: md_patcher-4.14.186.ko → first available
  → insmod → busybox insmod → bundled bin/insmod2 (last resort)
  → logs to /data/local/tmp/pox_imei_patcher.log
```

 ROM / vendor rescue (ROM modifications):

* `vendor_overlay/` in the module dir: drop files mirrored by **bind-mount**
  over existing `/vendor/<subpath>` targets (can replace a broken MAL binary
  without touching vendor).
* `system/` in the module dir: standard Magisk overlay — e.g. drop a
  ROM-provided `priv-app/ImsService/ImsService.apk` here so it appears merged
  into `/system` (needs the ROM's `mediatek-ims-*` framework jars present).

## 5. NVRAM validation (check_nvram.php → install/bin/nvram_check.sh)

The shell validator reproduces the tool's acceptance logic:

| check | method |
|---|---|
| CSSD LID found, size 4168 | `grep -abo` of TOC, u32 size read |
| CSSD md5-fold (8B) | md5(payload) XOR-fold vs stored bytes |
| ≥5 TLV KV elements | split on the literal `\` + `n` two-byte separator (PHP `'\\n'`) |
| criticalData ⊇ chipid | `grep` in hex-decoded TLV blob |
| LD0B marker 0x0A | byte at LID+12 |
| RSA chain | `openssl rsautl -verify -raw` when openssl exists (non-fatal) |

It is **only able to judge, not fix** — repair is the separate `mtk_imei.php`
step on the PC (keep the two apart; recovery cannot regenerate signatures).

## 6. Package generation flow

```
config.txt  ──▶  php bin/mtk_imei.php
                   ├─ sign CSSD (RSA-2048 CA sig + RSA-1024 criticalData sig)
                   ├─ AES-encrypt LD0B IMEIs (scramble_iv_key → CBC → ECB)
                   ├─ patch WIFI/BT MAC + 2B checksums, re-fold TOC checksum
                   ├─ data/patch.zip  +  module/ + install/  →  out/*.zip
                   └─ data/generic_updater-script.txt (+ restore updater)
                php bin/nvram_selftest.php  ← run this; 17 structural+cryptographic
                                              gates must pass (region, signatures,
                                              MACs, AES round-trip)
```

Region effects (`region` config key):

| region | criticalData header byte | notes |
|---|---|---|
| `global` / `india` | `0x62` | global/india begonia (and all other devices today) |
| `cn` | `0x72` | Chinese begonia; additionally `ro.boot.hwlevel=P0` is forced at boot by the module on CN (property datastore rewrite) |

## 7. Known limits

* The IMS **framework glue** (`mediatek-ims-*` boot-classpath jars) cannot be
  injected by any root module; ROMs missing them will not register VoLTE even
  with a perfect NVRAM. `install/bin/stack_report.sh` prints exactly what the
  running ROM is missing, per file.
* The global-image checksum (16 Mi-ops over 64 MiB) is skipped on-device
  (shell can't do int^128k in a useful time); CSSD/series checks cover the
  practical corruption cases. `bin/nvram_selftest.php` enforces it offline.
* A shared RSA keypair is currently burned into the repo (`data/private_*.pem`).
  For devices exposed in the wild, generate per-release keypairs and
  rebuild `md1img` with the corresponding *public* key modulus embedded.
