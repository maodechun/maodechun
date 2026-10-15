import 'dart:convert';

import 'package:characters/characters.dart';

import '../../core/totp/generator.dart';
import '../../core/totp/uri_parser.dart';

/// 令牌数据模型
///
/// 注意：`secretEncrypted` 为加密后的密文，
/// 明文密钥只在内存中短暂存在，绝不持久化。
class Token {
  final String id;
  final String issuer;   // 服务名，如 GitHub
  final String account;  // 账号，如 octocat@gmail.com
  final String secretEncrypted; // AES 加密后的密钥密文
  final String algorithm; // SHA1 / SHA256 / SHA512
  final int digits;       // 6 / 8
  final int period;       // 15 / 30 / 60
  final int colorTag;     // 卡片色标索引
  final int sortOrder;
  final int createdAt;    // Unix 毫秒

  const Token({
    required this.id,
    required this.issuer,
    required this.account,
    required this.secretEncrypted,
    this.algorithm = 'SHA1',
    this.digits = 6,
    this.period = 30,
    this.colorTag = 0,
    this.sortOrder = 0,
    required this.createdAt,
  });

  /// 展示用标题
  String get title => issuer.isEmpty ? account : issuer;

  /// 展示用副标题
  String get subtitle => issuer.isEmpty ? '' : account;

  /// 首字母（无图标时的占位）
  String get initial {
    final source = title.trim();
    if (source.isEmpty) return '令';
    return source.characters.first;
  }

  /// 是否为非标准参数（需在 UI 上有别于常规令牌）
  bool get isNonStandard => algorithm != 'SHA1' || digits != 6 || period != 30;

  // ── 序列化 ───────────────────────────────────────────

  Map<String, Object?> toMap() => {
        'id': id,
        'issuer': issuer,
        'account': account,
        'secret_encrypted': secretEncrypted,
        'algorithm': algorithm,
        'digits': digits,
        'period': period,
        'color_tag': colorTag,
        'sort_order': sortOrder,
        'created_at': createdAt,
      };

  factory Token.fromMap(Map<String, Object?> map) => Token(
        id: map['id'] as String,
        issuer: (map['issuer'] as String?) ?? '',
        account: (map['account'] as String?) ?? '',
        secretEncrypted: (map['secret_encrypted'] as String?) ?? '',
        algorithm: (map['algorithm'] as String?) ?? 'SHA1',
        digits: (map['digits'] as int?) ?? 6,
        period: (map['period'] as int?) ?? 30,
        colorTag: (map['color_tag'] as int?) ?? 0,
        sortOrder: (map['sort_order'] as int?) ?? 0,
        createdAt: (map['created_at'] as int?) ?? 0,
      );

  /// 备份文件用的明文结构（仅在内存中构建，随即加密）
  Map<String, Object?> toBackupMap(String plainSecret) => {
        'id': id,
        'issuer': issuer,
        'account': account,
        'secret': plainSecret,
        'algorithm': algorithm,
        'digits': digits,
        'period': period,
        'colorTag': colorTag,
        'sortOrder': sortOrder,
        'createdAt': createdAt,
      };

  Token copyWith({
    String? id,
    String? issuer,
    String? account,
    String? secretEncrypted,
    String? algorithm,
    int? digits,
    int? period,
    int? colorTag,
    int? sortOrder,
    int? createdAt,
  }) {
    return Token(
      id: id ?? this.id,
      issuer: issuer ?? this.issuer,
      account: account ?? this.account,
      secretEncrypted: secretEncrypted ?? this.secretEncrypted,
      algorithm: algorithm ?? this.algorithm,
      digits: digits ?? this.digits,
      period: period ?? this.period,
      colorTag: colorTag ?? this.colorTag,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// 生成 otpauth URI（需要明文密钥，调用方负责生命周期）
  String toOtpAuthUri(String plainSecret) {
    return OtpAuthData(
      issuer: issuer,
      account: account,
      secret: plainSecret,
      algorithm: TotpAlgorithm.fromString(algorithm),
      digits: digits,
      period: period,
    ).toUri();
  }

  @override
  String toString() => 'Token($id, $issuer/$account)';
}

/// 令牌生成辅助（从解析结果构建新令牌）
class TokenFactory {
  TokenFactory._();

  /// 从 otpauth 解析结果创建令牌
  ///
  /// [encrypt] 由 SecretStore 提供的加密函数
  static Token fromOtpAuth({
    required OtpAuthData data,
    required String id,
    required String encryptedSecret,
    int colorTag = 0,
    int sortOrder = 0,
  }) {
    return Token(
      id: id,
      issuer: data.issuer,
      account: data.account,
      secretEncrypted: encryptedSecret,
      algorithm: data.algorithm.label,
      digits: data.digits,
      period: data.period,
      colorTag: colorTag,
      sortOrder: sortOrder,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 从备份数据恢复令牌
  static Token? fromBackupMap(
    Map<String, Object?> map,
    String Function(String plain) encrypt,
  ) {
    try {
      final plain = map['secret'] as String?;
      if (plain == null || plain.isEmpty) return null;
      return Token(
        id: (map['id'] as String?) ?? DateTime.now().microsecondsSinceEpoch.toString(),
        issuer: (map['issuer'] as String?) ?? '',
        account: (map['account'] as String?) ?? '',
        secretEncrypted: encrypt(plain),
        algorithm: (map['algorithm'] as String?) ?? 'SHA1',
        digits: (map['digits'] as int?) ?? 6,
        period: (map['period'] as int?) ?? 30,
        colorTag: (map['colorTag'] as int?) ?? 0,
        sortOrder: (map['sortOrder'] as int?) ?? 0,
        createdAt: (map['createdAt'] as int?) ??
            DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 备份文件结构
class BackupPayload {
  final String app;      // 固定 'bodhi_token'
  final int version;     // 备份格式版本
  final int exportedAt;  // 导出时间
  final String deviceTag; // 设备标识（用于绑定校验）
  final List<Map<String, Object?>> tokens;

  const BackupPayload({
    this.app = 'bodhi_token',
    this.version = 1,
    required this.exportedAt,
    required this.deviceTag,
    required this.tokens,
  });

  String toJson() => jsonEncode({
        'app': app,
        'version': version,
        'exportedAt': exportedAt,
        'deviceTag': deviceTag,
        'tokens': tokens,
      });

  static BackupPayload? fromJson(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      final list = (map['tokens'] as List<Object?>?) ?? const [];
      return BackupPayload(
        app: (map['app'] as String?) ?? 'bodhi_token',
        version: (map['version'] as int?) ?? 1,
        exportedAt: (map['exportedAt'] as int?) ?? 0,
        deviceTag: (map['deviceTag'] as String?) ?? '',
        tokens: list
            .whereType<Map<String, Object?>>()
            .map((e) => Map<String, Object?>.from(e))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}
