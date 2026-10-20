# Pox Modem & IMEI Restoration Suite
> Universal IMEI repair, NVRAM/NVDATA partition generator, automated modem backup engine, and dynamic kernel RSA patcher for MediaTek Helio G-Series devices (MT6785 / begonia).

[![License: GPL-2.0](https://img.shields.io/badge/License-GPL%202.0-blue.svg)](LICENSE)
[![Device: Begonia](https://img.shields.io/badge/Device-Redmi%20Note%208%20Pro-orange.svg)](https://github.com/POX-project/pox-begonia-kernel)
[![Root: Universal](https://img.shields.io/badge/Root-FolkPatch%20%7C%20APatch%20%7C%20KernelSU%20%7C%20Magisk-brightgreen.svg)](#)

---

## Overview

When flashing custom AOSP/LineageOS/HyperOS ROMs or custom kernels on Xiaomi MediaTek devices, modified or aftermarket IMEIs are frequently rejected by the baseband modem due to RSA signature checks.

**Pox IMEI Fixer** solves this comprehensively:
1. **Calibrated NVRAM/NVDATA Generator**: Recreates the NVRAM/NVDATA partition image with your hardware identifiers (IMEI 1, IMEI 2, Wi-Fi MAC, and Bluetooth MAC) and generates valid security certificates.
2. **Automated Modem Partition Backup Engine**: Before touching any partition, the recovery installer and in-OS hook automatically dump and hash all 8 radio/modem partitions (`nvram`, `nvdata`, `nvcfg`, `protect1`, `protect2`, `proinfo`, `md1img`) to `/sdcard/Pox_Backups/Modem_<TIMESTAMP>/` with SHA256 verification.
3. **Dynamic Kernel RSA Patcher (`md_patcher`)**: Injects an in-memory kernel patch via SMC and EMI MPU to unlock modem RSA signature verification at boot time.
4. **Universal Root & Recovery Support**: Flashes seamlessly in **TWRP / OrangeFox Recovery**, **FolkPatch / APatch Manager**, **KernelSU Manager**, and **Magisk Manager**.

---

## Supported Devices

- **Redmi Note 8 Pro** (`begonia` / `begoniain`) - Full native Pox Kernel support
- **Redmi Note 10S / Redmi Note 11 SE / POCO M5s** (`rosemary` / `secret` / `maltose`)
- **Redmi Note 12S** (`sea`)
- **Redmi 10 / Redmi 10 2022 / Redmi 10 Prime / Redmi Note 11 4G** (`selene`)
- **Redmi 12C / POCO C55** (`earth`)
- **Redmi 12** (`fire`)
- **Redmi 9** (`lancelot`)

---

## Getting Started

### 1. Prerequisites
- **Linux / macOS**: PHP 7.4+ or 8.x with `openssl` and `zip` extensions (`sudo apt install php-cli php-openssl php-zip`).
- **Windows**: Built-in PHP binaries and DLLs are already bundled in the `bin/` directory.

### 2. Configuration
Copy `config.example.txt` to `config.txt` and fill in your device values:

```json
{
  "patch_cert": 1,
  "kernel":   "all",
  "device":   "begonia",
  "chip_id":  "0x00000000000000000000000000000000",
  "imei_1":   "860000000000001",
  "imei_2":   "860000000000002",
  "wifi_mac": "00:11:22:33:44:55",
  "bt_mac":   "00:11:22:33:44:66"
}
```

### 2.1 Collect Required Values (Termux or ADB Shell)
Run these commands on the phone (Termux) or through ADB (`adb shell <command>`) to collect the values used in `config.txt`:

- **Chip ID (`chip_id`)**
  ```bash
  getprop ro.boot.chipid
  ```
- **Device codename (`device`)**
  ```bash
  getprop ro.product.device
  ```
- **IMEI slot 1 (`imei_1`)**
  ```bash
  service call iphonesubinfo 1
  ```
- **IMEI slot 2 (`imei_2`)**
  ```bash
  service call iphonesubinfo 3
  ```
> **Note:** If IMEI is not readable or not working on the phone, check the IMEI printed on the back of the device or on the original phone box/label.
- **Wi-Fi MAC (`wifi_mac`)**
  ```bash
  cat /sys/class/net/wlan0/address
  ```
- **Bluetooth MAC (`bt_mac`)**
  ```bash
  cat /sys/class/bluetooth/hci0/address
  ```

> **Tip:** Leaving `"kernel": "all"` bundles matching prebuilt modules for every Pox Kernel edition (`Onyx`, `Onyx-APatch`, `Onyx-BakaSU`, `Onyx-KSU-Next`, `Onyx-Sultan-APatch`, OpenELA/Suzaku, stock) and automatically picks the right module matching `uname -r` at boot.

### 3. Generate Flashable Package
- **Linux / macOS**:
  ```bash
  chmod +x mtk_imei.sh
  ./mtk_imei.sh
  ```
- **Windows**:
  Double-click `mtk_imei.cmd`.

The generated package will be placed in the `out/` folder:
`out/imei_repair-<device>.zip` (or `pox_imei_fixer-<device>.zip`).

---

## Installation Guide

### Option A: Flash in Recovery (TWRP / OrangeFox)
1. Boot into Recovery.
2. Tap **Install** -> Select the generated `.zip` -> **Swipe to Flash** (or `adb sideload <zip>`).
3. The generic edify driver (`data/generic_updater-script.txt`) hands over to `install/bin/install.sh`, which will:
   - **Back up** all modem partition(s) to `/sdcard/Pox_Backups/` with SHA-256 manifest.
   - **Validate** the existing NVRAM (`install/bin/nvram_check.sh`, shell port of the tool's `check_nvram.php`).
   - **Write** the calibrated NVRAM *only if the existing chain is invalid* (see `mode` in config), then rebuild `nvdata`.
   - **Stage** the kernel-aware `md_patcher` loader (`vendor/bin/pox_module.sh` + `vendor/etc/init/md_patcher.rc`) and every bundled `.ko` into `/vendor`, plus the VoLTE/VoWiFi prop block into `/vendor/build.prop`, so it survives ROM flashes.
   - **Read-back verify** the TOC+CSSD region after flashing.
4. Reboot to System.

### Option B: Flash via Root Manager App (In-OS)
1. Open **FolkPatch**, **APatch**, **KernelSU**, or **Magisk** Manager.
2. Go to **Modules** -> **Install from Storage** -> Select the `.zip`.
3. The built-in `customize.sh` backs up partitions, validates, writes when warranted, sets `/mnt/vendor/nvdata` perms (`1000:1000`, `0771`) and purges the temporary images; the `md_patcher-<kernel>.ko` is selected at every boot via `install/bin/pick_module.sh` (`uname -r` match -> root-manager flavour -> base version -> classic fallback).
4. Reboot your phone.

### Restore / uninstall
A companion package `out/pox_restore-<device>.zip` restores the newest
`/sdcard/Pox_Backups/Modem_*` snapshot and removes the POX vendor/module bits.

### Verify the build before flashing (recommended)
```bash
php bin/mtk_imei.php
php bin/nvram_selftest.php out/pox_imei_fixer-<device>.zip config.txt
# expect: == 17 passed, 0 failed ==
```

### Diagnose a running phone
```bash
adb shell sh /data/adb/modules/pox_imei_fixer/pox_diag.sh
adb shell sh /data/adb/modules/pox_imei_fixer/install/bin/stack_report.sh
```
`stack_report` prints per-file which VoLTE/VoWiFi pieces the ROM carries; see
`docs/ARCHITECTURE.md` for interpretation and `docs/ADDING-DEVICES.md` for
porting to new devices.

---

## Automated Backup Location

All modem partition dumps are stored on internal storage:
`/sdcard/Pox_Backups/Modem_<TIMESTAMP>/`

Inside you will find:
- `nvram.img`
- `nvdata.img`
- `nvcfg.img`
- `protect1.img` / `protect2.img`
- `proinfo.img`
- `md1img.img`
- `checksums.sha256`
- `backup_info.txt`

To restore any partition manually:
```bash
dd if=/sdcard/Pox_Backups/Modem_<TIMESTAMP>/nvram.img of=/dev/block/by-name/nvram
dd if=/sdcard/Pox_Backups/Modem_<TIMESTAMP>/nvdata.img of=/dev/block/by-name/nvdata
```

---

## VoLTE & Telephony Support (v3.2.0+)

Modern custom ROMs (AOSP, Lineage, Axion, Android 13/14/15/16) and pure LTE networks (such as Airtel or Jio) require explicit VoLTE and IMS configuration. Version 3.2.0+ includes:
- **Expanded VoLTE/VoWiFi property injection** (`module/system.prop` + recovery `/vendor/build.prop` append): the full set observed in the working reference ROM - `persist.dbg.{ims_volte_enable,volte_avail_ovr,vt_avail_ovr,wfc_avail_ovr}`, iwlan feature props (`persist.data.iwlan*`, `ro.telephony.iwlan_operation_mode`), IMS/MAL enable flags, `telephony.active_modems.max_count`, `ro.vendor.md_auto_setup_ims`, `ro.vendor.mtk_ril_mode`.
- **Kernel-aware module loading** with `install/bin/pick_module.sh` (replaces the hardcoded single-`.ko` insmod).
- **SELinux Context Restoration**: Applies `u:object_r:vendor_file:s0` to staged modules, avoiding AVC denials under SELinux Enforcing mode.
- **Runtime NVDATA Permissions**: Automatically sets `/mnt/vendor/nvdata` ownership (`1000:1000`) and mode (`0771`).
- **Validate-before-overwrite**: existing signed NVRAM chains are preserved; the calibrated image is only written when the local chain fails validation (or when `mode=force`).
- **VINTF fragment**: when the ROM manifest lacks the MTK radio HALs, `install/etc/vintf_pox_radio_fragment.xml` is dropped to `/vendor/etc/vintf/manifest/` (recovery path only).

---

## Verification & Logs

To verify that the modem patcher is active on boot:
```bash
adb shell "cat /data/local/tmp/pox_imei_patcher.log"
adb shell "dmesg | grep md_patcher"
```

---

## Security & Privacy Notice

- Never share your personalized `config.txt` or generated `nvram.img` publicly; they contain your device's unique hardware identifiers.
- The `config.txt` shipped in this repository contains dummy placeholder values by design.

---

## Credits & License

- **Pox Project Team** & **Antigravity**: Universal FolkPatch/APatch compatibility, AnyKernel3 integration, automated modem backup engine, native Pox kernel compilation.
- **timjosten**: Original MTK IMEI patcher concept and algorithm.
- Licensed under the **GNU General Public License v2.0** (`GPL-2.0`).
