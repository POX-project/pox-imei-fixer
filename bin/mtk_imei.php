<?php
  ini_set('memory_limit', '1024M');

  function intval32($value)
  {
    $value = $value & 0xFFFFFFFF;
    if($value & 0x80000000)
      $value = -((~$value & 0xFFFFFFFF) + 1);
    return $value;
  }

  function checksum_nvram($data)
  {
    $sum = 0;
    $tempNum = 0;
    $size = strlen($data);
    for($i = 0; $i < $size; $i += 4)
    {
      $buf = substr($data, $i, 4);
      $value = unpack('l', str_pad($buf, 4, "\x00"))[1];
      if(strlen($buf) < 4)  // last incomplete read
      {
        $tempNum = $value;
        break;
      }
      $sum = ($i / 4) % 2 == 0 ? $sum ^ $value : $sum + $value;
    }
    return pack('l', intval32($sum + $tempNum) ^ $size);
  }

  function checksum_2b($data)
  {
    $sum = 0;
    $size = strlen($data);
    for($i = 0; $i < $size; $i++)
    {
      $value = unpack('C', $data, $i)[1];
      $sum = $i % 2 == 0 ? $sum + $value : $sum ^ $value;
    }
    return "\xAA".pack('C', $sum);
  }

  function checksum_8b($data)
  {
    $sum = '';
    $md5 = md5($data, true);
    for($i = 0; $i < 8; $i++)
      $sum[$i] = chr(ord($md5[$i]) ^ ord($md5[$i + 8]));
    return $sum;
  }

  function swap_bytes(&$data)
  {
    for($i = 0; $i < strlen($data); $i += 2)
    {
      $temp = $data[$i + 1];
      $data[$i + 1] = $data[$i];
      $data[$i] = $temp;
    }
  }

  function scramble_iv_key(&$iv, &$key, $xor)
  {
    swap_bytes($iv);
    swap_bytes($key);
    for($i = 0; $i < strlen($iv); $i++)
    {
      $iv[$i] = chr(ord($iv[$i]) ^ ord($xor[$i]));
      $key[$i] = chr(ord($key[$i]) ^ ord($iv[$i]));
    }
  }

  function convert_imei($imei)
  {
    $imei .= 'F0000';
    swap_bytes($imei);
    return hex2bin($imei);
  }

  function rbundle($zip, $base)  // bundle helper: walk a folder into the zip
  {
    $it = new RecursiveIteratorIterator(
      new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS),
      RecursiveIteratorIterator::LEAVES_ONLY);
    foreach($it as $f)
    {
      if(!$f->isFile())
        continue;
      $name = str_replace('\\', '/', $f->getPathname());
      $zip->addFile($name, $name);   // keep full path incl. $base prefix
    }
  }

  echo "========================================================\n";
  echo "       POX KERNEL MODEM & IMEI RESTORATION SUITE        \n";
  echo "========================================================\n";
  echo "  Universal NVRAM/NVDATA Generator & RSA Patcher        \n";
  echo "  Begonia & MTK Helio G-Series | POX Project            \n";
  echo "========================================================\n\n";

  echo "[*] [1/6] Checking environment & runtime dependencies...\n";
  if(!extension_loaded('openssl'))
    die("[-] FAILED: The PHP openssl extension is required.\n");
  if(!extension_loaded('zip'))
    die("[-] FAILED: The PHP zip extension is required (install php-zip or enable ZipArchive).\n");
  echo "    [+] PHP OpenSSL extension : active\n";
  echo "    [+] PHP ZipArchive        : active\n\n";

  echo "[*] [2/6] Parsing device configuration (config.txt)...\n";
  $config_file = is_file('config.txt') ? 'config.txt' : (is_file('config.myphone.txt') ? 'config.myphone.txt' : '');
  if(!$config_file)
    die("[-] FAILED: Cannot find config.txt or config.myphone.txt!\n    Please copy config.example.txt to config.txt and populate your device values.\n");

  $config_raw = file_get_contents($config_file);
  $config = json_decode($config_raw, true);
  if(!$config)
    die("[-] FAILED: Malformed JSON syntax in $config_file.\n");

  $config['device']     = strlen($config['device'] ?? '') ? ($config['device'] ?? $config['product']) : '';
  $config['patch_cert'] = $config['device'] == 'begonia' ? 1 : ($config['patch_cert'] ?? 1);  // begonia is rsa-only
  $config['chip_id']    = empty($config['patch_cert']) && strlen($config['chip_id'] ?? '') != 34 ? '0x'.md5('') : ($config['chip_id'] ?? '');
  $config['kernel']     = strlen($config['kernel'] ?? '') ? $config['kernel'] : 'all';
  $config['wifi_mac']   = strtoupper(str_replace(':', '', $config['wifi_mac'] ?? ''));
  $config['bt_mac']     = strtoupper(str_replace(':', '', $config['bt_mac'] ?? ''));
  $config['region']     = strlen($config['region'] ?? '') ? $config['region'] : 'global';    // cn | global | india
  $config['mode']       = strlen($config['mode'] ?? '') ? $config['mode'] : 'repair-if-invalid';
  // repair-if-invalid | force | validate-only

  if(strlen($config['device'])   == 0
  || strlen($config['chip_id'])  != 34
  || strlen($config['imei_1'])   != 15
  || strlen($config['imei_2'])   != 15
  || strlen($config['wifi_mac']) != 12
  || strlen($config['bt_mac'])   != 12)
  {
    die("[-] FAILED: Incorrect values in $config_file.\n    Ensure IMEIs are 15 digits, MACs are valid, and chip_id is 34 chars (0x...).\n");
  }

  if($config['imei_1'] == $config['imei_2'])
    die("[-] FAILED: IMEI 1 and IMEI 2 must be different.\n");

  $alias_list = file_get_contents('data/alias.txt') or
    die("[-] FAILED: Cannot open data/alias.txt.\n");
  $alias_list = json_decode($alias_list, true) or
    die("[-] FAILED: Malformed alias list.\n");
  $device = $config['device'];
  foreach($alias_list as $original => $aliases)
  {
    foreach($aliases as $alias)
    {
      if($alias == $device)
      {
        $device = $original;
        break 2;
      }
    }
  }

  echo "    [+] Target Device : {$config['device']} (resolved alias -> $device)\n";
  echo "    [+] Region        : {$config['region']}\n";
  echo "    [+] Mode          : {$config['mode']}\n";
  echo "    [+] Kernel Filter : {$config['kernel']}\n";
  echo "    [+] Patch Cert    : " . ($config['patch_cert'] ? "ENABLED (RSA bypass)" : "DISABLED") . "\n";
  echo "    [+] Chip ID       : {$config['chip_id']}\n";
  echo "    [+] Target IMEI 1 : {$config['imei_1']}\n";
  echo "    [+] Target IMEI 2 : {$config['imei_2']}\n";
  echo "    [+] Wi-Fi MAC     : {$config['wifi_mac']}\n";
  echo "    [+] Bluetooth MAC : {$config['bt_mac']}\n\n";

  echo "[*] [3/6] Generating cryptographic hardware signatures...\n";
  $privatekey_2048 = file_get_contents('data/private_2048.pem') or
    die("[-] FAILED: Cannot open data/private_2048.pem.\n");
  $privatekey_1024 = file_get_contents('data/private_1024.pem') or
    die("[-] FAILED: Cannot open data/private_1024.pem.\n");
  $modulus_1024 = openssl_pkey_get_details(openssl_pkey_get_private($privatekey_1024))['rsa']['n'];
  $exponent_1024 = '10001';
  if(strlen($modulus_1024) != 128)
    die("[-] FAILED: Cannot extract modulus from private key 1024.\n");

  $data = $exponent_1024;
  $data .= bin2hex($modulus_1024);
  $data .= $config['device'];
  $signature = "\x00\x01";
  $signature .= str_repeat("\xFF", 221);
  $signature .= "\x00";
  $signature .= hash('sha256', $data, true);
  openssl_private_encrypt($signature, $devPubKeySign, $privatekey_2048, OPENSSL_NO_PADDING) or
    die("[-] FAILED: Cannot sign using private key 2048.\n");
  $devPubKeySign = strtoupper(bin2hex($devPubKeySign));

  // criticalData family header; last byte 0x72 for Chinese-region begonia,
  // 0x62 for global/India (matches MIUI's signed CDT layout).
  $header = "\x00\x01\x00";
  $header .= chr($config['device'] == 'begonia' && $config['region'] == 'cn' ? 0x72 : 0x62);
  $data = $header;
  $data .= "\x01\x22".$config['chip_id'];
  $data .= "\x02\x0F".$config['imei_1'];
  $data .= "\x03\x0F".$config['imei_2'];
  $data .= "\x05\x0C".$config['wifi_mac'];
  $data .= "\x06\x0C".$config['bt_mac'];
  $data = bin2hex($data);
  $signature = "\x00\x01";
  $signature .= str_repeat("\xFF", 93);
  $signature .= "\x00";
  $signature .= hash('sha256', $data, true);
  openssl_private_encrypt($signature, $crticalDataSign, $privatekey_1024, OPENSSL_NO_PADDING) or
    die("[-] FAILED: Cannot sign using private key 1024.\n");
  $crticalDataSign = bin2hex($crticalDataSign);

  $cssd = 'devPubKeyModulus:'.bin2hex($modulus_1024);
  $cssd .= "\\ndevPubKeyExponent:$exponent_1024";
  $cssd .= "\\ndevPubKeySign:$devPubKeySign";
  $cssd .= "\\ncriticalData:$data";
  $cssd .= "\\ncrticalDataSign:$crticalDataSign";
  $cssd = str_pad($cssd, 4096, "\x00");
  $cssd .= checksum_8b($cssd);

  $ld0b = '';
  for($i = 1; $i <= 10; $i++)
  {
    $imei = '';
    switch($i)
    {
      case 1:
      case 2:
        if($config["imei_$i"] != '000000000000000')
        {
          $imei = convert_imei($config["imei_$i"]);
          break;
        }
      default:
        $imei = str_repeat("\xFF", 10);
    }
    $ld0b .= str_pad($imei.checksum_8b($imei), 32, "\x00");
  }
  $xor  = "\x8F\x9C\x61\x51\xDC\x86\xB9\x16\x3A\x37\x50\x6D\x9D\xFF\x77\x53\x46\x4B\xA7\x3E\x5E\xDE\xF3\x62\x5B\xA1\x8D\x48\x12\x35\x80\x5B";
  $iv   = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x0B\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x00\x00\x00\x00";
  $key  = "\x35\x23\x32\x53\x42\x45\x54\x24\x43\x86\x68\x34\x78\x56\x34\x12\x78\x56\x34\x12\x43\x86\x68\x34\x42\x45\x54\x24\x35\x23\x32\x53";
  $key2 = "\xBE\x41\x0C\x67\x39\x4D\x98\x01\x72\x56\xAA\x3C\x8F\x21\xBB\x42";
  scramble_iv_key($iv, $key, $xor);
  $key2 = openssl_encrypt($key2, 'aes-256-cbc', $key,  OPENSSL_RAW_DATA | OPENSSL_ZERO_PADDING, substr($iv, 0, 16));
  $ld0b = openssl_encrypt($ld0b, 'aes-128-ecb', $key2, OPENSSL_RAW_DATA | OPENSSL_ZERO_PADDING);
  echo "    [+] RSA-2048 device public key signature generated\n";
  echo "    [+] RSA-1024 critical hardware certificate generated ($config[region] header)\n";
  echo "    [+] AES encrypted LD0B & authenticated CSSD blocks built\n\n";

  echo "[*] [4/6] Building calibrated NVRAM partition image...\n";
  $nvram = @file_get_contents("data/$device/nvram.bin") or
    die("[-] FAILED: Cannot open original NVRAM image for '$device' (device not supported).\n");
  $toc_size = 0x20000;
  $content_size = unpack('V', $nvram, 4)[1];
  $ld0b_offset = strpos($nvram, '/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_00');
  if($ld0b_offset !== false)
    $ld0b_offset = $toc_size + unpack('V', $nvram, $ld0b_offset - 8)[1];
  $cssd_offset = strpos($nvram, '/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/CSSD_000');
  if($cssd_offset !== false)
    $cssd_offset = $toc_size + unpack('V', $nvram, $cssd_offset - 8)[1];
  $wifi_offset = strpos($nvram, '/mnt/vendor/nvdata/APCFG/APRDEB/WIFI') or
    die("[-] FAILED: Cannot find WIFI file in NVRAM image.\n");
  $wifi_size = unpack('V', $nvram, $wifi_offset - 4)[1];
  $wifi_offset = $toc_size + unpack('V', $nvram, $wifi_offset - 8)[1];
  $bt_offset = strpos($nvram, '/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr') or
    die("[-] FAILED: Cannot find BT_Addr file in NVRAM image.\n");
  $bt_size = unpack('V', $nvram, $bt_offset - 4)[1];
  $bt_offset = $toc_size + unpack('V', $nvram, $bt_offset - 8)[1];
  $nvram = str_replace('/CALIBRAT/', '/CALIBRUH/', $nvram);
  @mkdir('out');
  file_put_contents('out/nvram.img', $nvram) or
    die("[-] FAILED: Cannot save NVRAM image to out/nvram.img.\n");
  $fp = fopen('out/nvram.img', 'r+b') or
    die("[-] FAILED: Cannot open out/nvram.img for writing.\n");
  if($ld0b_offset !== false)
  {
    fseek($fp, $ld0b_offset + 12);
    fwrite($fp, "\x0A");
    fseek($fp, $ld0b_offset + 64);
    fwrite($fp, $ld0b);
    echo "    [+] Injected encrypted LD0B IMEI block\n";
  }
  if($cssd_offset !== false)
  {
    fseek($fp, $cssd_offset + 64);
    fwrite($fp, $cssd);
    echo "    [+] Injected authenticated CSSD certificate block\n";
  }
  fseek($fp, $wifi_offset + 4);
  fwrite($fp, hex2bin($config['wifi_mac']));
  fseek($fp, $wifi_offset);
  $wifi = fread($fp, $wifi_size - 2);
  fwrite($fp, checksum_2b($wifi));
  echo "    [+] Injected Wi-Fi MAC ({$config['wifi_mac']}) with verified 2B checksum\n";

  fseek($fp, $bt_offset);
  fwrite($fp, hex2bin($config['bt_mac']));
  fseek($fp, $bt_offset);
  $bt = fread($fp, $bt_size - 2);
  fwrite($fp, checksum_2b($bt));
  echo "    [+] Injected Bluetooth MAC ({$config['bt_mac']}) with verified 2B checksum\n";

  fseek($fp, $toc_size);
  $content = fread($fp, $content_size);
  fseek($fp, 0x0C);
  fwrite($fp, checksum_nvram($content));
  fclose($fp);
  echo "    [+] Recomputed global NVRAM TOC checksum (size: 64MB)\n\n";

  $patch_cert = (bool)$config['patch_cert'];

  echo "[*] [5/6] Packaging flashable recovery & root archive...\n";
  $out_main   = "out/pox_imei_fixer-{$config['device']}.zip";
  $out_compat = "out/imei_repair-{$config['device']}.zip";
  $out_restore= "out/pox_restore-{$config['device']}.zip";

  if(!is_file('data/patch.zip'))
  {
    die("[-] FAILED: Base template 'data/patch.zip' is missing!\n    Please ensure data/patch.zip is present in the repository.\n");
  }

  copy('data/patch.zip', $out_main) or
    die("[-] FAILED: Cannot copy data/patch.zip to $out_main.\n");

  $zip = new ZipArchive;
  $zip->open($out_main) or
    die("[-] FAILED: Cannot open archive $out_main.\n");

  // replace template updater-script with the generic driver; drop skip_mount
  $zip->addFile('data/generic_updater-script.txt', 'META-INF/com/google/android/updater-script') or
    die("[-] FAILED: Cannot add updater-script to zip archive.\n");
  $zip->deleteName('skip_mount');
  $zip->addFile('module/customize.sh',      'customize.sh');
  $zip->addFile('module/post-fs-data.sh',   'post-fs-data.sh');
  $zip->addFile('module/service.sh',        'service.sh');
  $zip->addFile('module/system.prop',       'system.prop');
  $zip->addFile('module/module.prop',       'module.prop');
  $zip->addFile('module/sepolicy.rule',     'sepolicy.rule');
  $zip->addFile('module/pox_diag.sh',       'pox_diag.sh');
  // installer & module glue
  rbundle($zip, 'install');
  // mode hint consumed by installers
  $zip->addFromString('mode', $config['mode']."\n");
  echo "    [+] Injected module glue (customize.sh, loaders, system.prop)\n";
  echo "    [+] Injected on-device installer + validator + backup engine\n";

  // 64MB calibrated image lives INSIDE install/ so the generic edify
  // updater extracts it automatically; root managers unzip the whole tree.
  $zip->addFile('out/nvram.img', 'install/nvram.img') or
    die("[-] FAILED: Cannot add nvram.img to zip archive.\n");
  echo "    [+] Injected calibrated nvram.img\n";

  if($patch_cert)
  {
    $zip->deleteName('vendor/lib/modules/md_patcher.ko');
    $zip->deleteName('system/bin/toybox2');
    $zip->deleteName('system/etc/init/md_patcher.rc');
    if($config['kernel'] === 'all' || $config['kernel'] === '*')
      $ko_list = glob("data/$device/md_patcher-*.ko");
    else
      $ko_list = array("data/$device/md_patcher-{$config['kernel']}.ko");

    $found = 0;
    $added = array();
    foreach($ko_list as $ko)
    {
      if(!is_file($ko))
      {
        if($config['kernel'] !== 'all' && $config['kernel'] !== '*')
          die("[-] FAILED: Specified kernel '{$config['kernel']}' not found in data/$device/.\n");
        continue;
      }
      $name = basename($ko);
      $zip->addFile($ko, 'vendor/lib/modules/'.$name) or
        die("[-] FAILED: Cannot add $name to zip archive.\n");
      $added[] = $name;
      $found++;
    }
    if($found == 0)
      die("[-] FAILED: No md_patcher modules found for device '$device'.\n");

    echo "    [+] Bundled $found Pox kernel patcher module(s) under vendor/lib/modules/\n";

    // vendor rc for the persistent (recovery-flash) path: boot-time loader via
    // a vendor copy of the picker script (kernel version is resolved at boot).
    $rc = "service md_patcher_exec /vendor/bin/sh /vendor/bin/pox_module.sh\n"
        . "    class core\n    user root\n    group root\n    oneshot\n    disabled\n\n"
        . "on post-fs-data\n    start md_patcher_exec\n";
    $zip->deleteName('vendor/etc/init/md_patcher.rc');
    $zip->addFromString('vendor/etc/init/md_patcher.rc', $rc);
  }
  else
  {
    $zip->deleteName('vendor/etc/init/md_patcher.rc');
  }

  $zip->close();
  unlink('out/nvram.img');

  // -----------------------------------------------------------------------
  // Restore package: bring back the latest automatic backup, then uninstall.
  // -----------------------------------------------------------------------
  copy('data/patch.zip', $out_restore) or die("[-] FAILED: copy data/patch.zip to $out_restore.\n");
  $zip2 = new ZipArchive;
  $zip2->open($out_restore) or die("[-] FAILED: Cannot open archive $out_restore.\n");
  $zip2->addFile('data/generic_restore_updater.txt', 'META-INF/com/google/android/updater-script');
  $zip2->addFromString('mode', 'restore'."\n");
  rbundle($zip2, 'install');
  $zip2->deleteName('vendor/lib/modules/md_patcher.ko');
  $zip2->close();
  echo "    [+] Restore/uninstall package written: $out_restore\n";

  // Maintain compatibility with legacy scripts expecting imei_repair-<device>.zip
  copy($out_main, $out_compat);

  $sz_mb = round(filesize($out_main) / 1048576, 2);

  echo "\n========================================================\n";
  echo " [+] SUCCESS: Flashable Pox Package Created!\n";
  echo "========================================================\n";
  echo " Primary Package     : $out_main ($sz_mb MB)\n";
  echo " Compatibility Alias : $out_compat\n";
  echo " Restore / Uninstall : $out_restore\n";
  echo "\n How to flash:\n";
  echo " 1. Recovery Mode   : Reboot to TWRP/OrangeFox and flash via zip\n";
  echo "                      (backup engine runs first; existing NVRAM is\n";
  echo "                       validated and PRESERVED when it is still valid)\n";
  echo " 2. In-OS Root Mode : Flash module directly in FolkPatch / APatch,\n";
  echo "                        KernelSU, or Magisk Manager.\n";
  echo " Modes (config.txt): repair-if-invalid (default) | force | validate-only\n";
  echo "========================================================\n\n";

  exit(0);
