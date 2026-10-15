import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 密钥加密存储服务
///
/// 安全设计要点：
///   1. 令牌 Secret 明文 **绝不** 直接落盘，一律 AES-256-CBC 加密后存储
///   2. 主密钥（MasterKey）保存在系统安全区（Android Keystore / iOS Keychain）
///      —— 由 flutter_secure_storage 封装，硬件级保护
///   3. 首次启动生成随机主密钥，之后只读不写
///   4. 即使数据库文件被复制到其他设备，缺少 Keystore 中的主密钥也无法解密
class SecretStore {
  SecretStore._internal();
  static final SecretStore instance = SecretStore._internal();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const String _keyAlias = 'bodhi_master_key_v1';

  enc.Key? _masterKey;

  /// 初始化：取出或生成主密钥
  ///
  /// 必须在应用启动早期调用一次。
  Future<void> init() async {
    try {
      final existing = await _storage.read(key: _keyAlias);
      if (existing != null && existing.length == 64) {
        _masterKey = enc.Key.fromBase64(_base64FromHex(existing));
        return;
      }
      // 生成 32 字节（256 位）随机主密钥
      final keyBytes = _randomBytes(32);
      final hexKey = _hexFromBytes(keyBytes);
      await _storage.write(key: _keyAlias, value: hexKey);
      _masterKey = enc.Key(keyBytes);
    } catch (e) {
      // 安全区不可用时，退化为会话内临时密钥。
      // 此时数据仅在本次运行期间可解密，重启后需重新录入密钥。
      // 注意：这会导致数据库口令每次启动都不同（令牌丢失），必须大声
      // 记录原因，绝不能静默——否则问题无从排查。
      // ignore: avoid_print
      print('SecretStore: secure storage UNAVAILABLE, '
          'falling back to ephemeral key: $e');
      _masterKey ??= enc.Key(_randomBytes(32));
    }
  }

  bool get isReady => _masterKey != null;

  /// 从主密钥确定性派生数据库口令
  ///
  /// 必须是「同一主密钥 → 同一口令」的纯函数。绝不能用 encrypt()
  /// （AES-CBC 随机 IV）来派生——那样口令每次启动都不同，数据库
  /// 永远打不开（表现为 open_failed / hmac check failed）。
  String deriveDbPassword() {
    final mk = _masterKey;
    if (mk == null) return '';
    final mac = Hmac(sha256, mk.bytes)
        .convert(utf8.encode('bodhi_db_password_v1'));
    return mac.toString().substring(0, 48);
  }

  // ── 加解密 ───────────────────────────────────────────

  /// 加密明文 Secret
  ///
  /// 返回格式：`base64(iv) + ":" + base64(cipherText)`
  /// 每次加密使用随机 IV，相同明文产生不同密文
  String? encrypt(String plainText) {
    if (_masterKey == null || plainText.isEmpty) return null;
    try {
      final iv = enc.IV(_randomBytes(16));
      final encrypter = enc.Encrypter(enc.AES(_masterKey!, mode: enc.AESMode.cbc));
      final encrypted = encrypter.encrypt(plainText, iv: iv);
      return '${iv.base64}:${encrypted.base64}';
    } catch (_) {
      return null;
    }
  }

  /// 解密
  String? decrypt(String cipherText) {
    if (_masterKey == null || cipherText.isEmpty) return null;
    try {
      final parts = cipherText.split(':');
      if (parts.length != 2) return null;
      final iv = enc.IV.fromBase64(parts[0]);
      final data = enc.Encrypted.fromBase64(parts[1]);
      final encrypter = enc.Encrypter(enc.AES(_masterKey!, mode: enc.AESMode.cbc));
      return encrypter.decrypt(data, iv: iv);
    } catch (_) {
      // 主密钥变更或数据损坏，返回 null 由上层处理
      return null;
    }
  }

  // ── 备份口令加密（用户自定义密码）────────────────────

  /// 使用用户密码加密备份数据（用于 FTP 备份文件）
  ///
  /// 采用 PBKDF2 派生密钥，避免弱密码被暴力破解
  static String encryptWithPassword(String plainText, String password) {
    final salt = _randomBytes(16);
    final key = _pbkdf2(password, salt, 10000, 32);
    final iv = _randomBytes(16);
    final encrypter = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.cbc));
    final encrypted = encrypter.encrypt(plainText, iv: enc.IV(iv));

    // 格式：BODHI1 + base64(salt) + ":" + base64(iv) + ":" + base64(data)
    return 'BODHI1:${_b64(salt)}:${_b64(iv)}:${encrypted.base64}';
  }

  /// 使用用户密码解密备份数据
  static String? decryptWithPassword(String cipherText, String password) {
    try {
      final parts = cipherText.split(':');
      if (parts.length != 4 || parts[0] != 'BODHI1') return null;

      final salt = _b64d(parts[1]);
      final iv = _b64d(parts[2]);
      final data = enc.Encrypted.fromBase64(parts[3]);

      final key = _pbkdf2(password, salt, 10000, 32);
      final encrypter = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.cbc));
      return encrypter.decrypt(data, iv: enc.IV(iv));
    } catch (_) {
      return null;
    }
  }

  // ── 数据擦除 ─────────────────────────────────────────

  /// 清除主密钥（用于「恢复出厂设置」）
  ///
  /// 调用后所有已加密数据将永久无法解密
  Future<void> wipeMasterKey() async {
    try {
      await _storage.delete(key: _keyAlias);
    } catch (_) {}
    _masterKey = null;
  }

  // ── 工具方法 ─────────────────────────────────────────

  static final Random _rng = Random.secure();

  static Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _rng.nextInt(256)),
    );
  }

  static String _hexFromBytes(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _base64FromHex(String hex) {
    final bytes = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return _b64(bytes);
  }

  static String _b64(List<int> bytes) => base64Encode(bytes);
  static Uint8List _b64d(String s) => Uint8List.fromList(base64Decode(s));

  /// PBKDF2-HMAC-SHA256 密钥派生（简化实现，10,000 轮）
  ///
  /// 说明：生产环境若需更高强度可替换为 pointycastle 的 PBKDF2，
  /// 此处实现避免引入过重依赖，同时保证基本安全强度。
  static Uint8List _pbkdf2(
    String password,
    List<int> salt,
    int iterations,
    int keyLength,
  ) {
    final passwordBytes = utf8.encode(password);
    final hmacKey = passwordBytes;

    final derived = <int>[];
    var blockIndex = 1;

    while (derived.length < keyLength) {
      // U1 = HMAC(password, salt || INT_32_BE(blockIndex))
      final block = <int>[...salt];
      block.add((blockIndex >> 24) & 0xFF);
      block.add((blockIndex >> 16) & 0xFF);
      block.add((blockIndex >> 8) & 0xFF);
      block.add(blockIndex & 0xFF);

      var u = Hmac(sha256, hmacKey).convert(block).bytes;
      final result = List<int>.from(u);

      for (var i = 1; i < iterations; i++) {
        u = Hmac(sha256, hmacKey).convert(u).bytes;
        for (var j = 0; j < result.length; j++) {
          result[j] ^= u[j];
        }
      }

      derived.addAll(result);
      blockIndex++;
    }

    return Uint8List.fromList(derived.sublist(0, keyLength));
  }
}
