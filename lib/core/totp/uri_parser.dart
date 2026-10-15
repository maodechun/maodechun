import '../totp/generator.dart';
import 'migration_parser.dart';

/// otpauth:// URI 解析结果
class OtpAuthData {
  final String issuer;
  final String account;
  final String secret;
  final TotpAlgorithm algorithm;
  final int digits;
  final int period;

  const OtpAuthData({
    required this.issuer,
    required this.account,
    required this.secret,
    this.algorithm = TotpAlgorithm.sha1,
    this.digits = 6,
    this.period = 30,
  });

  /// 生成 otpauth URI（用于导出）
  String toUri() {
    final label = issuer.isEmpty ? account : '$issuer:$account';
    final encodedLabel = Uri.encodeComponent(label);
    final params = <String, String>{
      'secret': secret,
      'issuer': issuer,
      'algorithm': algorithm.label,
      'digits': digits.toString(),
      'period': period.toString(),
    };
    final query = params.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'otpauth://totp/$encodedLabel?$query';
  }

  /// 用于二维码展示的简短标签
  String get displayLabel => issuer.isEmpty ? account : issuer;
}

/// otpauth URI / 裸 Base32 解析器
///
/// 支持三类输入：
///   1. 完整 otpauth://totp/... URI
///   2. 裸 Base32 密钥（用户手动输入）
///   3. 带空格的 Base32（如 "JBSW Y3DP EHPK 3PXP"）
class OtpAuthParser {
  OtpAuthParser._();

  /// 解析结果状态
  static const String errEmpty = '密钥内容不能为空';
  static const String errNotTotp = '仅支持 TOTP 类型的令牌';
  static const String errBadSecret = '密钥格式不正确，请检查是否为有效的 Base32 编码';
  static const String errBadScheme = '链接格式不正确，应以 otpauth:// 开头';

  /// 统一入口解析
  ///
  /// 成功返回 [OtpAuthData]，失败返回 [ParseError]（含可读中文提示）
  static ParseResult parse(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return ParseResult.failure(errEmpty);
    }

    if (input.toLowerCase().startsWith('otpauth://')) {
      return _parseUri(input);
    }

    // 视为裸 Base32 密钥
    return _parseRawSecret(input);
  }

  /// 批量入口解析（扫码 / 相册 / 粘贴统一走这里）
  ///
  /// 支持一次导入多个账号的来源：
  ///   1. Google Authenticator 迁移二维码 `otpauth-migration://offline?data=...`
  ///      —— 一次可携带几十个账号，[ParseBatchResult.items] 会全部返回
  ///   2. 单条 `otpauth://totp/...`
  ///   3. 裸 Base32 密钥
  static ParseBatchResult parseBatch(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return ParseBatchResult.failure(errEmpty);
    }

    // Google Authenticator 批量导出
    if (MigrationParser.looksLikeMigration(input)) {
      return MigrationParser.parse(input);
    }

    final single = parse(input);
    if (!single.ok) {
      return ParseBatchResult.failure(single.error ?? errBadSecret);
    }
    return ParseBatchResult.success([single.data!]);
  }

  // ── otpauth URI 解析 ─────────────────────────────────
  static ParseResult _parseUri(String input) {
    final Uri uri;
    try {
      uri = Uri.parse(input);
    } catch (_) {
      return ParseResult.failure(errBadScheme);
    }

    // 校验 host 必须为 totp
    final host = uri.host.toLowerCase();
    if (host != 'totp') {
      return ParseResult.failure(errNotTotp);
    }

    final params = uri.queryParameters;

    // 密钥
    final secret = params['secret'] ?? '';
    if (secret.isEmpty || !TotpGenerator.isValidSecret(secret)) {
      return ParseResult.failure(errBadSecret);
    }

    // label 形如：issuer:account 或 account
    var issuer = params['issuer'] ?? '';
    var account = '';

    // path 会以 / 开头
    var label = uri.path;
    if (label.startsWith('/')) label = label.substring(1);
    label = Uri.decodeComponent(label);

    if (label.contains(':')) {
      final parts = label.split(':');
      if (issuer.isEmpty) issuer = parts.first.trim();
      account = parts.sublist(1).join(':').trim();
    } else {
      account = label.trim();
    }

    // 参数越界时降级为默认值（不报错，避免用户无法导入）
    final digitsRaw = int.tryParse(params['digits'] ?? '') ?? 6;
    final digits = (digitsRaw == 6 || digitsRaw == 8) ? digitsRaw : 6;

    final periodRaw = int.tryParse(params['period'] ?? '') ?? 30;
    final period = (periodRaw == 15 || periodRaw == 30 || periodRaw == 60)
        ? periodRaw
        : 30;

    final algorithm = TotpAlgorithm.fromString(params['algorithm']);

    if (account.isEmpty && issuer.isEmpty) {
      account = '未命名令牌';
    }

    return ParseResult.success(OtpAuthData(
      issuer: issuer,
      account: account,
      secret: secret.toUpperCase().replaceAll(RegExp(r'[\s\-=]'), ''),
      algorithm: algorithm,
      digits: digits,
      period: period,
    ));
  }

  // ── 裸 Base32 解析 ───────────────────────────────────
  static ParseResult _parseRawSecret(String input) {
    final cleaned = input.toUpperCase().replaceAll(RegExp(r'[\s\-=]'), '');
    if (!TotpGenerator.isValidSecret(cleaned)) {
      return ParseResult.failure(errBadSecret);
    }
    return ParseResult.success(OtpAuthData(
      issuer: '',
      account: '未命名令牌',
      secret: cleaned,
      algorithm: TotpAlgorithm.sha1,
      digits: 6,
      period: 30,
    ));
  }

  /// 实时校验输入（供输入框边输入边提示）
  static bool looksValid(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return false;
    if (MigrationParser.looksLikeMigration(trimmed)) {
      return MigrationParser.parse(trimmed).ok;
    }
    if (trimmed.toLowerCase().startsWith('otpauth://')) {
      return _parseUri(trimmed).ok;
    }
    final cleaned = trimmed.toUpperCase().replaceAll(RegExp(r'[\s\-=]'), '');
    return TotpGenerator.isValidSecret(cleaned);
  }
}

/// 批量解析结果
///
/// 单条 otpauth / 裸 Base32 与 Google 迁移二维码共用此结构，
/// 使扫码、相册、手动输入三条链路能走同一套批量导入逻辑。
class ParseBatchResult {
  /// 可导入的账号列表（顺序与二维码内一致）
  final List<OtpAuthData> items;

  /// 解析失败原因（[ok] 为 true 时必为 null）
  final String? error;

  /// 被跳过的条目数（如 HOTP 计数器型账号）
  final int skipped;

  /// Google 迁移二维码的批次序号（0 起）。非迁移码固定为 0。
  final int batchIndex;

  /// Google 迁移二维码的总批次数。非迁移码固定为 1。
  ///
  /// 账号较多时 Google Authenticator 会把导出内容拆成多张二维码，
  /// 每张的 `batch_size` 相同、`batch_index` 递增。
  final int batchSize;

  const ParseBatchResult._(
    this.items,
    this.error,
    this.skipped,
    this.batchIndex,
    this.batchSize,
  );

  factory ParseBatchResult.success(
    List<OtpAuthData> items, {
    int skipped = 0,
    int batchIndex = 0,
    int batchSize = 1,
  }) =>
      ParseBatchResult._(items, null, skipped, batchIndex, batchSize);

  factory ParseBatchResult.failure(String error) =>
      ParseBatchResult._(const [], error, 0, 0, 1);

  bool get ok => items.isNotEmpty;

  /// 是否属于批量导入（用于提示文案）
  bool get isBatch => items.length > 1;

  /// 是否还有下一张二维码没扫（Google 迁移码分多张导出时）
  bool get hasMoreBatches => batchIndex + 1 < batchSize;

  /// 「第 2/3 张」这样的批次文案；单张时返回 null
  String? get batchLabel =>
      batchSize > 1 ? '第 ${batchIndex + 1}/$batchSize 张' : null;
}

/// 解析结果包装
class ParseResult {
  final OtpAuthData? data;
  final String? error;

  const ParseResult._(this.data, this.error);

  factory ParseResult.success(OtpAuthData data) => ParseResult._(data, null);
  factory ParseResult.failure(String error) => ParseResult._(null, error);

  bool get ok => data != null;
}
