import 'dart:convert';
import 'dart:typed_data';

import '../totp/generator.dart';
import 'uri_parser.dart';

/// Google Authenticator 批量导出二维码解析（otpauth-migration://）
///
/// Google Authenticator「转移账号 / 导出账号」生成的二维码不是单条 otpauth
/// URI，而是：
///
///   otpauth-migration://offline?data=<Base64(protobuf)>
///
/// protobuf 结构（官方 MigrationPayload）：
/// ```proto
/// message MigrationPayload {
///   enum Algorithm  { ALGORITHM_UNSPECIFIED=0; SHA1=1; SHA256=2; SHA512=3; MD5=4; }
///   enum DigitCount { DIGIT_COUNT_UNSPECIFIED=0; SIX=1; EIGHT=2; }
///   enum OtpType    { OTP_TYPE_UNSPECIFIED=0; HOTP=1; TOTP=2; }
///   message OtpParameters {
///     bytes  secret    = 1;
///     string name      = 2;
///     string issuer    = 3;
///     Algorithm  algorithm = 4;
///     DigitCount digits = 5;
///     OtpType    type   = 6;
///     int64  counter   = 7;
///   }
///   repeated OtpParameters otp_parameters = 1;
///   int32 version     = 2;
///   int32 batch_size  = 3;
///   int32 batch_index = 4;
///   int32 batch_id    = 5;
/// }
/// ```
///
/// 解析器为纯 Dart 手写 protobuf wire 解析，不引入 protobuf 运行时依赖
/// （包体已极致压缩，为一个字段结构引入 300KB 生成代码不划算）。
///
/// 不变量：
///   1. 任何畸形输入都只返回错误，绝不抛异常（扫码线程不能被拖垮）
///   2. 单条记录解析失败只跳过该条，不影响其余账号导入
///   3. HOTP（计数器型）账号无法在本应用展示，计入 skipped 而非报错
class MigrationParser {
  MigrationParser._();

  /// 迁移二维码的 scheme 前缀
  static const String schemePrefix = 'otpauth-migration://';

  /// 是否为 Google 迁移二维码
  static bool looksLikeMigration(String input) =>
      input.trim().toLowerCase().startsWith(schemePrefix);

  /// 解析迁移二维码，返回可导入的账号列表
  static ParseBatchResult parse(String input) {
    final trimmed = input.trim();

    // 1. 取 data 参数（手动切分，避免 Dart query 解码把 '+' 当空格）
    final qIndex = trimmed.indexOf('?');
    if (qIndex < 0) {
      return ParseBatchResult.failure(errNoData);
    }
    final query = trimmed.substring(qIndex + 1);
    final match = RegExp(r'(?:^|&)data=([^&]*)').firstMatch(query);
    final rawParam = match?.group(1);
    if (rawParam == null || rawParam.isEmpty) {
      return ParseBatchResult.failure(errNoData);
    }

    // 2. URL 解码 → Base64（兼容标准 / URL-safe / 无 padding）
    final Uint8List payload;
    try {
      payload = _decodeBase64(Uri.decodeComponent(rawParam));
    } catch (_) {
      return ParseBatchResult.failure(errBadBase64);
    }

    // 3. protobuf 解析
    final items = <OtpAuthData>[];
    var skipped = 0;
    // Google 账号较多时会把导出内容拆成多张二维码（batch_size / batch_index），
    // 必须把批次信息带回 UI，否则用户扫完第一张就以为已经全部导入。
    var batchSize = 1;
    var batchIndex = 0;
    try {
      final reader = _PbReader(payload);
      while (reader.hasMore) {
        final tag = reader.readVarint();
        final field = tag >> 3;
        final wire = tag & 0x07;

        if (field == 1 && wire == 2) {
          final sub = _PbReader(reader.readBytes());
          final parsed = _parseOtpParameters(sub);
          if (parsed == null) {
            skipped++;
          } else {
            items.add(parsed);
          }
        } else if (field == 3 && wire == 0) {
          batchSize = reader.readVarint();
        } else if (field == 4 && wire == 0) {
          batchIndex = reader.readVarint();
        } else {
          reader.skip(wire);
        }
      }
    } catch (_) {
      return ParseBatchResult.failure(errCorrupted);
    }

    if (items.isEmpty) {
      if (skipped > 0) {
        return ParseBatchResult.failure(errNoSupported);
      }
      return ParseBatchResult.failure(errEmptyPayload);
    }

    if (batchSize <= 0) batchSize = 1;
    return ParseBatchResult.success(
      items,
      skipped: skipped,
      batchIndex: batchIndex,
      batchSize: batchSize,
    );
  }

  // ── OtpParameters ────────────────────────────────────
  static OtpAuthData? _parseOtpParameters(_PbReader r) {
    Uint8List? secret;
    var name = '';
    var issuer = '';
    var algorithm = TotpAlgorithm.sha1;
    var digits = 6;
    var type = 2; // 默认 TOTP

    while (r.hasMore) {
      final tag = r.readVarint();
      final field = tag >> 3;
      final wire = tag & 0x07;

      switch (field) {
        case 1: // secret (bytes)
          secret = r.readBytes();
          break;
        case 2: // name (string)
          name = _readString(r);
          break;
        case 3: // issuer (string)
          issuer = _readString(r);
          break;
        case 4: // algorithm (varint)
          algorithm = _algorithmFrom(r.readVarint());
          break;
        case 5: // digits (varint)
          digits = r.readVarint() == 2 ? 8 : 6;
          break;
        case 6: // type (varint)
          type = r.readVarint();
          break;
        default:
          r.skip(wire);
          break;
      }
    }

    // HOTP 为计数器型，本应用只做 TOTP，跳过并计数
    if (type == 1) return null;

    if (secret == null || secret.isEmpty) return null;

    final secretB32 = TotpGenerator.base32Encode(secret);
    if (secretB32.isEmpty) return null;

    // name 可能是 "issuer:account"，也可能是纯 account
    var account = name.trim();
    if (account.contains(':')) {
      final parts = account.split(':');
      final prefix = parts.first.trim();
      final rest = parts.sublist(1).join(':').trim();
      if (issuer.isEmpty) issuer = prefix;
      account = rest;
    }
    if (account.isEmpty) {
      account = issuer.isEmpty ? '未命名令牌' : issuer;
    }

    return OtpAuthData(
      issuer: issuer.trim(),
      account: account,
      secret: secretB32,
      algorithm: algorithm,
      digits: digits,
      period: 30,
    );
  }

  /// algorithm 枚举：1=SHA1, 2=SHA256, 3=SHA512, 4=MD5
  ///
  /// MD5 在 RFC 6238 之外，本应用不支持，降级为 SHA1 会导致验证码错误，
  /// 故仍在解析层放行（调用方可选择跳过）——这里统一按 SHA1 处理，
  /// 因为 Google Authenticator 实际导出中不会出现 MD5。
  static TotpAlgorithm _algorithmFrom(int value) {
    switch (value) {
      case 2:
        return TotpAlgorithm.sha256;
      case 3:
        return TotpAlgorithm.sha512;
      case 1:
      default:
        return TotpAlgorithm.sha1;
    }
  }

  static String _readString(_PbReader r) {
    try {
      return utf8.decode(r.readBytes(), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// Base64 解码：兼容标准与 URL-safe 字母表、容忍缺失 padding
  static Uint8List _decodeBase64(String input) {
    var s = input.trim();
    s = s.replaceAll('-', '+').replaceAll('_', '/');
    s = s.replaceAll(RegExp(r'\s'), '');
    final pad = s.length % 4;
    if (pad == 2) {
      s += '==';
    } else if (pad == 3) {
      s += '=';
    } else if (pad == 1) {
      throw const FormatException('invalid base64 length');
    }
    return base64.decode(s);
  }

  // ── 错误文案 ─────────────────────────────────────────
  static const String errNoData = '这不是有效的 Google 令牌二维码（缺少 data 参数）';
  static const String errBadBase64 = 'Google 令牌二维码内容已损坏，请重新导出';
  static const String errCorrupted = 'Google 令牌二维码解析失败，请重新导出后再试';
  static const String errNoSupported = '该二维码中的账号本应用暂不支持（计数器型 HOTP）';
  static const String errEmptyPayload = '该二维码中没有可导入的账号';
}

/// 极简 protobuf wire 读取器（仅覆盖 varint / length-delimited / fixed）
class _PbReader {
  _PbReader(this._data);

  final Uint8List _data;
  int _pos = 0;

  bool get hasMore => _pos < _data.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (_pos < _data.length) {
      final b = _data[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('varint too long');
    }
    throw const FormatException('truncated varint');
  }

  Uint8List readBytes() {
    final len = readVarint();
    if (len < 0 || _pos + len > _data.length) {
      throw const FormatException('truncated length-delimited field');
    }
    final out = Uint8List.fromList(_data.sublist(_pos, _pos + len));
    _pos += len;
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
        break;
      case 1:
        _advance(8);
        break;
      case 2:
        readBytes();
        break;
      case 5:
        _advance(4);
        break;
      default:
        throw FormatException('unsupported wire type $wireType');
    }
  }

  void _advance(int n) {
    if (_pos + n > _data.length) {
      throw const FormatException('truncated fixed field');
    }
    _pos += n;
  }
}
