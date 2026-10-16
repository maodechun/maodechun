import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:encrypt/encrypt.dart' as enc;

import 'secret_store.dart';

/// 菩提护令专有备份加密容器（DT 格式，.dt 文件）
///
/// 二进制布局：
///   [0..5]    魔数 "DTBKV1"（6 字节）
///   [6..37]   salt（32 字节随机）
///   [38..49]  nonce（12 字节随机，GCM）
///   [50..N]   密文（AES-256-GCM，末尾自带 16 字节认证标签）
///   [N..N+31] HMAC-SHA256（Encrypt-then-MAC，覆盖之前全部字节）
///
/// 安全设计（防篡改 + 防逆向）：
///   1. PBKDF2-HMAC-SHA256 100,000 轮派生 64 字节：
///      前 32 字节作 AES-256 加密密钥，后 32 字节作 HMAC 鉴权密钥
///      —— 暴力破解成本被 KDF 轮次硬性拉高
///   2. AES-256-GCM：机密性 + 内置完整性认证（认证标签）
///   3. 外层 HMAC-SHA256 Encrypt-then-MAC 双重防篡改：
///      密文任意一字节被修改，HMAC 校验即失败，拒绝解密
///   4. 专有容器格式 + 派生过程域分隔（domain separation），
///      通用解密工具既不识别格式，也无法直接套用标准流程
///   5. 仅当用户通过 App 内身份验证（输入备份密码 / 云备份手机号），
///      本应用才会执行解密与恢复
class DtCipher {
  DtCipher._();

  /// 魔数 "DTBKV1"
  static const int _magic0 = 0x44; // D
  static const int _magic1 = 0x54; // T
  static const int _magic2 = 0x42; // B
  static const int _magic3 = 0x4B; // K
  static const int _magic4 = 0x56; // V
  static const int _magic5 = 0x31; // 1

  static const int _headerLen = 6 + 32 + 12; // 魔数 + salt + nonce
  static const int _minLen = _headerLen + 16 + 32; // 至少 1 块密文 + 标签 + mac
  static const int _kdfIterations = 100000;
  static const String _domain = 'daotuo/bodhi/backup/dt/v1';

  // ── 加密 ─────────────────────────────────────────────

  /// 加密为二进制容器（FTP / 云备份直接写盘或上传）
  static Uint8List encryptToBytes(String plainText, String password) {
    final salt = _random(32);
    final nonce = _random(12);
    final keys = _deriveKeys(password, salt);
    final encKey = enc.Key(Uint8List.sublistView(keys, 0, 32));
    final macKey = Uint8List.sublistView(keys, 32, 64);

    final encrypter = enc.Encrypter(
      enc.AES(encKey, mode: enc.AESMode.gcm, padding: null),
    );
    final cipherText = encrypter.encrypt(plainText, iv: enc.IV(nonce)).bytes;

    final body = BytesBuilder()
      ..add(_magicBytes())
      ..add(salt)
      ..add(nonce)
      ..add(cipherText);
    final bodyBytes = body.toBytes();

    final mac = Hmac(sha256, macKey).convert(bodyBytes).bytes;

    final out = BytesBuilder()
      ..add(bodyBytes)
      ..add(mac);
    return out.toBytes();
  }

  /// 加密为文本（本机备份走原生存储通道，内容必须是字符串）
  static String encryptToText(String plainText, String password) =>
      base64Encode(encryptToBytes(plainText, password));

  // ── 解密 ─────────────────────────────────────────────

  /// 解密二进制容器；任何失败（密码错误 / 被篡改 / 格式不符）返回 null
  static String? decryptBytes(Uint8List data, String password) {
    try {
      if (data.length < _minLen) return null;
      if (!_hasMagic(data)) return null;

      final salt = Uint8List.sublistView(data, 6, 38);
      final nonce = Uint8List.sublistView(data, 38, 50);
      final macStart = data.length - 32;
      final cipherText = Uint8List.sublistView(data, 50, macStart);
      final mac = Uint8List.sublistView(data, macStart);

      final keys = _deriveKeys(password, salt);
      final encKey = enc.Key(Uint8List.sublistView(keys, 0, 32));
      final macKey = Uint8List.sublistView(keys, 32, 64);

      // 第一道防线：外层 HMAC 防篡改校验
      final expectMac = Hmac(sha256, macKey)
          .convert(Uint8List.sublistView(data, 0, macStart))
          .bytes;
      if (!_constTimeEquals(mac, expectMac)) return null;

      // 第二道防线：AES-256-GCM 认证解密
      final encrypter = enc.Encrypter(
        enc.AES(encKey, mode: enc.AESMode.gcm, padding: null),
      );
      return encrypter.decrypt(
        enc.Encrypted(cipherText),
        iv: enc.IV(nonce),
      );
    } catch (_) {
      return null;
    }
  }

  /// 通用解密：自动识别 DT 容器与旧版 BODHI1 文本格式（向后兼容旧备份）
  static String? decryptAny(List<int> raw, String password) {
    if (raw.isEmpty) return null;

    final bytes =
        raw is Uint8List ? raw : Uint8List.fromList(raw);

    // 1) DT 二进制容器
    if (_hasMagic(bytes)) {
      return decryptBytes(bytes, password);
    }

    // 2) 文本：可能是旧 BODHI1，也可能是 base64 包装的 DT 容器
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      return null;
    }
    final trimmed = text.trim();

    if (trimmed.startsWith('BODHI1:')) {
      return SecretStore.decryptWithPassword(trimmed, password);
    }

    try {
      final decoded = base64Decode(trimmed);
      if (_hasMagic(decoded)) {
        return decryptBytes(decoded, password);
      }
    } catch (_) {
      // 非 base64，忽略
    }
    return null;
  }

  // ── 内部工具 ─────────────────────────────────────────

  static bool _hasMagic(List<int> d) =>
      d.length > 6 &&
      d[0] == _magic0 &&
      d[1] == _magic1 &&
      d[2] == _magic2 &&
      d[3] == _magic3 &&
      d[4] == _magic4 &&
      d[5] == _magic5;

  static Uint8List _magicBytes() =>
      Uint8List.fromList([_magic0, _magic1, _magic2, _magic3, _magic4, _magic5]);

  /// PBKDF2-HMAC-SHA256，salt 拼接专有域分隔串，派生 64 字节
  static Uint8List _deriveKeys(String password, Uint8List salt) {
    final domainBytes = utf8.encode(_domain);
    final fullSalt = Uint8List.fromList([...salt, ...domainBytes]);
    return _pbkdf2(password, fullSalt, _kdfIterations, 64);
  }

  static Uint8List _pbkdf2(
    String password,
    List<int> salt,
    int iterations,
    int dkLen,
  ) {
    final passwordBytes = utf8.encode(password);
    final hmacKey = passwordBytes;
    final blocks = (dkLen / 32).ceil();
    final result = <int>[];

    for (var block = 1; block <= blocks; block++) {
      final blockBytes = Uint8List(4);
      blockBytes[0] = (block >> 24) & 0xFF;
      blockBytes[1] = (block >> 16) & 0xFF;
      blockBytes[2] = (block >> 8) & 0xFF;
      blockBytes[3] = block & 0xFF;

      var u = Uint8List.fromList([...salt, ...blockBytes]);
      var t = List<int>.filled(32, 0);
      final hmac = Hmac(sha256, hmacKey);

      for (var i = 0; i < iterations; i++) {
        u = Uint8List.fromList(hmac.convert(u).bytes);
        for (var j = 0; j < 32; j++) {
          t[j] ^= u[j];
        }
      }
      result.addAll(t);
    }

    return Uint8List.fromList(result.sublist(0, dkLen));
  }

  /// 常数时间比较，防时序侧信道
  static bool _constTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }
}
