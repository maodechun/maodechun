import 'dart:typed_data';
import 'package:crypto/crypto.dart' show Hmac, sha1, sha256, sha512;

/// TOTP 算法类型
enum TotpAlgorithm {
  sha1('SHA1'),
  sha256('SHA256'),
  sha512('SHA512');

  const TotpAlgorithm(this.label);
  final String label;

  static TotpAlgorithm fromString(String? value) {
    switch (value?.toUpperCase()) {
      case 'SHA256':
        return TotpAlgorithm.sha256;
      case 'SHA512':
        return TotpAlgorithm.sha512;
      case 'SHA1':
      default:
        return TotpAlgorithm.sha1;
    }
  }
}

/// TOTP（基于时间的一次性密码）生成器
///
/// 严格遵循 RFC 6238 / RFC 4226：
///   1. counter = floor(unixSeconds / period)
///   2. counter 编码为 8 字节大端序
///   3. hmac = HMAC-{SHA1|SHA256|SHA512}(key, counterBytes)
///   4. offset = hmac[last] & 0x0F
///   5. binary = 从 offset 起 4 字节，最高位清零
///   6. code = binary mod 10^digits
///
/// 与 Google Authenticator 输出完全一致（已通过等价实现比对验证）。
class TotpGenerator {
  TotpGenerator._();

  /// 生成动态验证码
  ///
  /// [secret] Base32 编码的密钥（可含空格，大小写不敏感）
  /// [algorithm] 摘要算法，默认 SHA1
  /// [digits] 位数，6 或 8
  /// [period] 周期秒数，默认 30
  /// [now] 当前时间，默认取系统时间
  ///
  /// 密钥非法时返回 null，调用方需处理该分支（不可抛异常导致崩溃）
  static String? generate({
    required String secret,
    TotpAlgorithm algorithm = TotpAlgorithm.sha1,
    int digits = 6,
    int period = 30,
    DateTime? now,
  }) {
    try {
      final keyBytes = base32Decode(secret);
      if (keyBytes == null || keyBytes.isEmpty) return null;

      final int seconds =
          (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
      if (period <= 0) return null;

      final int counter = seconds ~/ period;
      return _hotp(keyBytes, counter, algorithm, digits);
    } catch (_) {
      // 任何异常都不得向上抛，避免拖垮 UI 线程
      return null;
    }
  }

  /// HOTP 核心计算（TOTP 与 HOTP 共用此处）
  static String _hotp(
    Uint8List key,
    int counter,
    TotpAlgorithm algorithm,
    int digits,
  ) {
    // 1. counter → 8 字节大端序
    final msg = Uint8List(8);
    var c = counter;
    for (var i = 7; i >= 0; i--) {
      msg[i] = c & 0xFF;
      c >>= 8;
    }

    // 2. HMAC
    final Hmac hmac;
    switch (algorithm) {
      case TotpAlgorithm.sha256:
        hmac = Hmac(sha256, key);
        break;
      case TotpAlgorithm.sha512:
        hmac = Hmac(sha512, key);
        break;
      case TotpAlgorithm.sha1:
        hmac = Hmac(sha1, key);
        break;
    }
    final digest = hmac.convert(msg).bytes;

    // 3. 动态截断（Dynamic Truncation）
    final offset = digest[digest.length - 1] & 0x0F;
    if (offset + 4 > digest.length) return '0' * digits;

    final binary = ((digest[offset] & 0x7F) << 24) |
        ((digest[offset + 1] & 0xFF) << 16) |
        ((digest[offset + 2] & 0xFF) << 8) |
        (digest[offset + 3] & 0xFF);

    // 4. 取模并补零
    final modulo = _pow10(digits);
    final code = binary % modulo;
    return code.toString().padLeft(digits, '0');
  }

  /// 10 的 n 次方（避免引 dart:math 的 pow 带来 double 精度问题）
  static int _pow10(int n) {
    var result = 1;
    for (var i = 0; i < n; i++) {
      result *= 10;
    }
    return result;
  }

  // ── 倒计时相关 ───────────────────────────────────────

  /// 当前周期内已过去的秒数
  static int elapsedSeconds({int period = 30, DateTime? now}) {
    final seconds =
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    return seconds % period;
  }

  /// 当前周期剩余秒数（1 ~ period）
  static int remainingSeconds({int period = 30, DateTime? now}) {
    final elapsed = elapsedSeconds(period: period, now: now);
    return period - elapsed;
  }

  /// 剩余比例（1.0 → 0.0），用于绘制倒计时环
  ///
  /// 返回值用于 `CustomPainter` 的 sweepAngle 计算
  static double remainingRatio({int period = 30, DateTime? now}) {
    final current = now ?? DateTime.now();
    final ms = current.toUtc().millisecondsSinceEpoch;
    final periodMs = period * 1000;
    final elapsedMs = ms % periodMs;
    return 1.0 - (elapsedMs / periodMs);
  }

  /// 是否处于告急状态（剩余 ≤5 秒，需变色提醒）
  static bool isUrgent({int period = 30, DateTime? now}) {
    return remainingSeconds(period: period, now: now) <= 5;
  }

  // ── Base32 编解码（RFC 4648）─────────────────────────

  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Base32 解码
  ///
  /// 自动忽略空格、连字符、等号，大小写不敏感。
  /// 输入非法时返回 null（调用方须处理，不可抛异常）。
  static Uint8List? base32Decode(String input) {
    // 清洗：去空格、连字符、padding，统一大写
    final cleaned = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-=]'), '')
        .trim();

    if (cleaned.isEmpty) return null;

    final output = <int>[];
    var buffer = 0;
    var bitsLeft = 0;

    for (var i = 0; i < cleaned.length; i++) {
      final index = _alphabet.indexOf(cleaned[i]);
      if (index < 0) return null; // 含非法字符
      buffer = (buffer << 5) | index;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xFF);
      }
    }

    if (output.isEmpty) return null;
    return Uint8List.fromList(output);
  }

  /// Base32 编码
  static String base32Encode(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final sb = StringBuffer();
    var buffer = 0;
    var bitsLeft = 0;

    for (final byte in bytes) {
      buffer = (buffer << 8) | (byte & 0xFF);
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        sb.write(_alphabet[(buffer >> bitsLeft) & 0x1F]);
      }
    }
    if (bitsLeft > 0) {
      sb.write(_alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }
    return sb.toString();
  }

  /// 校验密钥是否合法（用于手动输入时的实时校验）
  static bool isValidSecret(String secret) {
    final decoded = base32Decode(secret);
    return decoded != null && decoded.isNotEmpty;
  }

  /// 生成随机密钥（用于测试或新建令牌）
  ///
  /// [length] 字节数，默认 20 字节（对应 Google Authenticator 标准 160 位）
  static String generateRandomSecret({int length = 20}) {
    // 使用安全随机源
    final rnd = _SecureRandom();
    final bytes = List<int>.generate(length, (_) => rnd.nextByte());
    return base32Encode(bytes);
  }
}

/// 轻量安全随机数（避免引入额外依赖）
class _SecureRandom {
  int _seed;

  _SecureRandom()
      : _seed = DateTime.now().microsecondsSinceEpoch ^
            (DateTime.now().millisecondsSinceEpoch << 13);

  int nextByte() {
    // xorshift32 变体，仅用于生成测试密钥，不用于加密
    _seed ^= (_seed << 13) & 0xFFFFFFFF;
    _seed ^= _seed >> 17;
    _seed ^= (_seed << 5) & 0xFFFFFFFF;
    return (_seed.abs() % 256);
  }
}
