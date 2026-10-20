# Adding a new device to POX imei-fixer

The package is built from three per-device things plus config keys. Nothing
needs to be recompiled unless your kernel is not currently covered.

## 1. What you need from the target device

| artifact | where to get it | goes to |
|---|---|---|
| `nvram.bin` (64 MiB NVRAM dump, ideally from a *corrupted-IMEI* unit matching the target layout) | `dd if=/dev/block/by-name/nvram of=nvram.bin` in recovery; use a sanitized copy (no personal data) | `data/<device>/nvram.bin` |
| `md_patcher-<kernel>.ko` | build `md_patcher/md_patcher.c` against the target 4.14/4.19 kernel (see `md_patcher/` — `make` with the target `vermagic`), one per kernel/root-manager flavour | `data/<device>/md_patcher-<vermagic>.ko` |
| original `updater-script.txt` *(optional legacy)* | only kept for template compat; the generic driver is used now | `data/<device>/updater-script.txt` |

Validate the dump: it must be exactly 64 MiB, contain the LID strings
`/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/CSSD_000`,
`/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_00`,
`/mnt/vendor/nvdata/APCFG/APRDEB/WIFI`, `/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr`
(`strings nvram.bin | grep nvdata | sort -u`).

## 2. Aliases

If the same NVRAM layout covers variants (e.g. `begonia` → `begonia_global`,
`begonia_cn`, `merlin`, …), add them to `data/alias.txt`:

```json
{
  "begonia": ["begonia", "begonia_global", "begonia_cn", "begonia_eea"],
  "Merlin":  ["merlin", "merlinnfc"]
}
```

## 3. Config keys (`config.txt`)

| key | meaning |
|---|---|
| `device` | repo device key (`data/<device>/`) or any alias |
| `patch_cert` | `1` = bundle kernel RSA patcher (needed whenever you keep the stock vendor+md1img); `0` = pure NVRAM repair for ROMs with an aftermarket md1img CA |
| `kernel` | `"all"` (bundle every `md_patcher-*.ko`) or a specific vermagic |
| `region` | `global` \| `cn` \| `india` — swaps the criticalData header byte (`0x62` vs `0x72` on begonia-class) and selects CN-specific boot handling |
| `mode` | `repair-if-invalid` (recommended; never overwrites a valid signed chain) \| `force` \| `validate-only` |
| `chip_id` | from `/proc/embi` or the tool's original readout — `0x` + 32 hex; **must** match the physical unit |
| `imei_1`, `imei_2` | 15 digits each, must differ (in most jurisdictions use lawful IMEIs only) |
| `wifi_mac`, `bt_mac` | `AA:BB:CC:DD:EE:FF` style |

## 4. Build & verify

```bash
php bin/mtk_imei.php                 # → out/pox_imei_fixer-<device>.zip
php bin/nvram_selftest.php \
    out/pox_imei_fixer-<device>.zip config.txt   # must print: 17 passed, 0 failed
```

If the self-test fails on a new device, the usual causes are:

* `CSSD LID found` fails — nvram dump is not the 0x20000-TOC MTK format, or
  the LID string differs (adapt `lid_offset()` lookups in bin/nvram_selftest.php
  and the generators' `strpos` patterns).
* `CSSD md5-fold` fails — your device's CSSD content is larger/smaller than
  4096+64+8 (adjust `CSSD_SZ` checks).
* `LD0B AES…` fails — different LD0B key-derive constants; port the device's
  `scramble_iv_key` XOR pad from its original calibration tool.

## 5. VoLTE/VoWiFi stack readiness

Run on the *finished ROM + device*:

```sh
adb shell sh /data/adb/modules/pox_imei_fixer/install/bin/stack_report.sh
```

Every `/vendor` `[-- MISS]` means the ROM removed a piece of the MTK telephony
stack; VoLTE needs the MAL daemons (or bind-mount replacements under
`vendor_overlay/`). Missing `/system` IMS glue (ImsService apk /
`mediatek-ims-*` jars) cannot be worked around from a root module — engage the
ROM maintainer to include `mtk_ims` in their tree.
