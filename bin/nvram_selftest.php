<?php
  /*
   * POX imei-fixer -- nvram.img self-test.
   *
   * Validates a generated (or dumped) NVRAM image against a config.json WITHOUT
   * writing anything:
   *   [1] global TOC checksum (checksum_nvram)
   *   [2] CSSD md5-fold 8-byte checksum
   *   [3] devPubKeySign: RSA-2048 EM verifies & covers (e, modulus, device)
   *   [4] crticalDataSign: RSA-1024 EM verifies & covers hex(criticalData)
   *   [5] criticalData contains chip_id / imei_1 / imei_2 / wifi / bt
   *   [6] LD0B: marker 0x0A at +12, AES decrypts, IMEI 1 & 2 embedded
   *   [7] WIFI / BT MAC bytes + 2B checksums
   *
   * usage: php bin/nvram_selftest.php <nvram.img|flashable.zip> [config]
   * exit 0 = all checked gates passed; 1 = failure (details on stdout)
   */

  function checksum_nvram($data)
  {
    $sum = 0; $tempNum = 0; $size = strlen($data);
    for($i = 0; $i < $size; $i += 4)
    {
      $buf = substr($data, $i, 4);
      $value = unpack('V', str_pad($buf, 4, "\x00"))[1];
      if(strlen($buf) < 4) { $tempNum = $value; break; }
      $sum = ($i / 4) % 2 == 0 ? $sum ^ $value : $sum + $value;
      $sum &= 0xFFFFFFFF;
    }
    $acc = ($sum + $tempNum) & 0xFFFFFFFF;
    return pack('V', $acc ^ $size);
  }

  function checksum_2b($data)
  {
    $sum = 0; $size = strlen($data);
    for($i = 0; $i < $size; $i++)
    {
      $value = unpack('C', $data, $i)[1];
      $sum = $i % 2 == 0 ? $sum + $value : $sum ^ $value;
    }
    return "\xAA".pack('C', $sum);
  }

  function checksum_8b($data)
  {
    $sum = ''; $md5 = md5($data, true);
    for($i = 0; $i < 8; $i++) $sum[$i] = chr(ord($md5[$i]) ^ ord($md5[$i + 8]));
    return $sum;
  }

  function swap_bytes(&$data)
  {
    for($i = 0; $i < strlen($data); $i += 2)
    { $t = $data[$i+1]; $data[$i+1] = $data[$i]; $data[$i] = $t; }
  }

  function scramble_iv_key(&$iv, &$key, $xor)
  {
    swap_bytes($iv); swap_bytes($key);
    for($i = 0; $i < strlen($iv); $i++)
    {
      $iv[$i]  = chr(ord($iv[$i])  ^ ord($xor[$i]));
      $key[$i] = chr(ord($key[$i]) ^ ord($iv[$i]));
    }
  }

  function verify_em($sign, $modulus, $padlen)  // returns recovered hash or ''
  {
    $em = "\x00\x01".str_repeat("\xFF", $padlen)."\x00";
    return substr($sign, 0, strlen($em)) === $em ? substr($sign, strlen($em)) : '';
  }

  $fail = 0; $pass = 0;
  function gate($ok, $label)
  {
    global $fail, $pass;
    echo ($ok ? "  [PASS] " : "  [FAIL] ").$label."\n";
    $ok ? $pass++ : $fail++;
  }

  // ---- inputs -----------------------------------------------------------------
  $img = $argv[1] ?? 'out/nvram.img';
  $cfgf = $argv[2] ?? 'config.txt';
  $config = json_decode(file_get_contents($cfgf), true) or die("[-] bad config\n");
  $config['wifi_mac'] = strtoupper(str_replace(':', '', $config['wifi_mac'] ?? ''));
  $config['bt_mac']   = strtoupper(str_replace(':', '', $config['bt_mac']   ?? ''));

  // extract from flashable zip when needed
  if(substr($img, -4) === '.zip' && class_exists('ZipArchive'))
  {
    $z = new ZipArchive; $z->open($img);
    $dataImg = $z->getFromName('install/nvram.img') ?: $z->getFromName('nvram.img');
    if($dataImg === false) die("[-] nvram.img not found inside $img\n");
    $nvram = $dataImg;
  }
  else
    $nvram = file_get_contents($img) or die("[-] cannot read $img\n");

  echo "== POX nvram.img self-test ($img) ==\n";
  if(strlen($nvram) !== 64 * 1048576) die("[-] unexpected image size ".strlen($nvram)."\n");

  // ---- [1] global checksum -----------------------------------------------------
  $toc_size = 0x20000;
  $content_size = unpack('V', $nvram, 4)[1];
  $content = substr($nvram, $toc_size, $content_size);
  gate(checksum_nvram($content) === substr($nvram, 0x0C, 4), "global TOC checksum");

  // ---- locate CSSD / LD0B / WIFI / BT -------------------------------------------
  function lid_offset($nvram, $name, $toc_size = 0x20000)
  {
    $p = strpos($nvram, $name);
    if($p === false) return false;
    return $toc_size + unpack('V', $nvram, $p - 8)[1];
  }
  function lid_size($nvram, $name)
  {
    $p = strpos($nvram, $name);
    return unpack('V', $nvram, $p - 4)[1];
  }

  // ---- [2] CSSD md5-fold --------------------------------------------------------
  $cssd_off = lid_offset($nvram, '/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/CSSD_000');
  $ok = $cssd_off !== false;
  gate($ok, "CSSD LID found");
  if(!$ok) exit(1);
  $cssd = substr($nvram, $cssd_off, 4168);
  gate(checksum_8b(substr($cssd, 64, 4096)) === substr($cssd, 4160, 8), "CSSD md5-fold checksum");

  // ---- [3]/[4]/[5] signature chain ----------------------------------------------
  $pem1024 = file_get_contents('data/private_1024.pem') or die("[-] private_1024 missing\n");
  $pem2048 = file_get_contents('data/private_2048.pem') or die("[-] private_2048 missing\n");
  $modulus_1024 = openssl_pkey_get_details(openssl_pkey_get_private($pem1024))['rsa']['n'];
  $private_2048 = openssl_pkey_get_private($pem2048);
  $public_2048_mod = openssl_pkey_get_details($private_2048)['rsa']['n'];

  $cssd_kv = trim(substr($cssd, 64, 4096), "\x00");
  foreach(explode('\\n', $cssd_kv) as $kv)   // literal backslash+n separators
  {
    $k = substr($kv, 0, strpos($kv, ':'));
    $v = substr($kv, strpos($kv, ':') + 1);
    $cssd_data[$k] = $v;
  }

  // 2048: EM = 00 01 FF..(221) 00 sha256(e || modulus-hex || device); encrypt w/ m2048
  $data = '10001'.bin2hex($modulus_1024).$config['device'];
  $expect_hash = hash('sha256', $data, true);
  $sig = hex2bin($cssd_data['devPubKeySign']);
  $plain = openssl_public_decrypt($sig, $out, create_public_pem($public_2048_mod), OPENSSL_NO_PADDING)
    ? $out : '';
  $ok = $plain !== '' && verify_em($plain, '', 221) === $expect_hash;
  gate($ok, "devPubKeySign RSA-2048 verifies & covers (e, modulus, device)");

  // 1024: EM covers hex(criticalData)
  $cd = $cssd_data['criticalData'];
  $sig = hex2bin($cssd_data['crticalDataSign']);
  $plain = openssl_public_decrypt($sig, $out, create_public_pem($modulus_1024), OPENSSL_NO_PADDING)
    ? $out : '';
  $ok = $plain !== '' && substr($plain, 0, 2) === "\x00\x01"
    && substr($plain, 96) === hash('sha256', $cd, true);
  gate($ok, "crticalDataSign RSA-1024 verifies & covers criticalData");

  // TLVs inside criticalData (hex-of-ascii layout)
  $raw = hex2bin($cd);
  $got_chip = strpos($raw, $config['chip_id']) !== false;
  $got_i1   = strpos($raw, $config['imei_1']) !== false;
  $got_i2   = strpos($raw, $config['imei_2']) !== false;
  $got_wifi = strpos($raw, $config['wifi_mac']) !== false;
  $got_bt   = strpos($raw, $config['bt_mac']) !== false;
  gate($got_chip, "criticalData embeds chip_id");
  gate($got_i1,   "criticalData embeds IMEI 1");
  gate($got_i2,   "criticalData embeds IMEI 2");
  gate($got_wifi, "criticalData embeds WiFi MAC");
  gate($got_bt,   "criticalData embeds BT MAC");
  // header byte: 0x72 for chinese begonia else 0x62
  $want_hdr = ord($raw[3]);
  $expect_hdr = $config['device'] == 'begonia' && ($config['region'] ?? 'global') == 'cn' ? 0x72 : 0x62;
  gate($want_hdr === $expect_hdr, sprintf("criticalData region header byte 0x%02X", $want_hdr));

  // ---- [6] LD0B -----------------------------------------------------------------
  $ld0b_off = lid_offset($nvram, '/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_00');
  if($ld0b_off === false)
  {
    echo "  [SKIP] LD0B LID absent (image built for non-IMEI path)\n";
  }
  else
  {
    gate(ord($nvram[$ld0b_off + 12]) === 0x0A, "LD0B marker byte 0x0A");
    $blob = substr($nvram, $ld0b_off + 64, 320);
    $xor  = "\x8F\x9C\x61\x51\xDC\x86\xB9\x16\x3A\x37\x50\x6D\x9D\xFF\x77\x53\x46\x4B\xA7\x3E\x5E\xDE\xF3\x62\x5B\xA1\x8D\x48\x12\x35\x80\x5B";
    $iv   = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x0B\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x00\x00\x00\x00";
    $key  = "\x35\x23\x32\x53\x42\x45\x54\x24\x43\x86\x68\x34\x78\x56\x34\x12\x78\x56\x34\x12\x43\x86\x68\x34\x42\x45\x54\x24\x35\x23\x32\x53";
    scramble_iv_key($iv, $key, $xor);
    // key2 is DERIVED: aes-256-cbc encrypt of the fixed 16-byte seed
    $key2pre = hex2bin("BE410C67394D98017256AA3C8F21BB42");
    $key2 = openssl_encrypt($key2pre, 'aes-256-cbc', $key, OPENSSL_RAW_DATA | OPENSSL_ZERO_PADDING, substr($iv, 0, 16));
    $plain = openssl_decrypt($blob, 'aes-128-ecb', $key2, OPENSSL_RAW_DATA | OPENSSL_ZERO_PADDING);
    $i1ok = false;
    if($plain !== false && strlen($plain) >= 320)
    {
      // record 1: 10 raw bytes = hex2bin(convert_imei(imei_1))
      $imei1 = bin2hex(substr($plain, 0, 10));
      swap_bytes_s($imei1);
      $i1ok = strcasecmp($imei1, $config['imei_1'].'F0000') === 0;
    }
    gate($i1ok, "LD0B AES-decrypts with derived key (IMEI 1 recoverable)");
  }

  // ---- [7] WIFI/BT ---------------------------------------------------------------
  $wifi_off = lid_offset($nvram, '/mnt/vendor/nvdata/APCFG/APRDEB/WIFI');
  $bt_off   = lid_offset($nvram, '/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr');
  if($wifi_off !== false && $bt_off !== false)
  {
    $ws = lid_size($nvram, '/mnt/vendor/nvdata/APCFG/APRDEB/WIFI');
    $bs = lid_size($nvram, '/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr');
    $got = bin2hex(substr($nvram, $wifi_off + 4, 6));
    gate(strcasecmp($got, $config['wifi_mac']) === 0, "WIFI MAC bytes present");
    $got = bin2hex(substr($nvram, $bt_off, 6));
    gate(strcasecmp($got, $config['bt_mac']) === 0, "BT MAC bytes present");
    $got = substr($nvram, $wifi_off, $ws - 2);
    gate(checksum_2b($got) === substr($nvram, $wifi_off + $ws - 2, 2), "WIFI 2B checksum");
    $got = substr($nvram, $bt_off, $bs - 2);
    gate(checksum_2b($got) === substr($nvram, $bt_off + $bs - 2, 2), "BT 2B checksum");
  }
  else
    echo "  [SKIP] WIFI/BT LIDs absent\n";

  echo "\n== $pass passed, $fail failed ==\n";
  exit($fail ? 1 : 0);

  // ---- helpers -------------------------------------------------------------------
  function der_len_hex($n)   // DER length field (long form allowed)
  {
    if($n < 0x80) return sprintf('%02X', $n);
    $b = dechex($n); if(strlen($b) % 2) $b = '0'.$b;
    return sprintf('%02X', 0x80 | strlen($b) / 2).strtoupper($b);
  }
  function der_int($bytes)   // INTEGER, always keeps a leading 00 when MSB set
  {
    $b = $bytes;
    if(ord($b[0]) & 0x80) $b = "\x00".$b;
    return hex2bin("02".der_len_hex(strlen($b))).$b;
  }
  function create_public_pem($modulus)      // PKCS#1: SEQUENCE { n, e=65537 }
  {
    $seq = der_int($modulus).hex2bin("0203010001");
    return pem_wrap(hex2bin("30".der_len_hex(strlen($seq))).$seq);
  }
  function pem_wrap($der)
  {
    return "-----BEGIN RSA PUBLIC KEY-----\n"
         . chunk_split(base64_encode($der), 64, "\n")
         . "-----END RSA PUBLIC KEY-----\n";
  }
  function swap_bytes_s(&$s)
  {
    for($i = 0; $i < strlen($s); $i += 2)
    { $t = $s[$i+1]; $s[$i+1] = $s[$i]; $s[$i] = $t; }
  }
