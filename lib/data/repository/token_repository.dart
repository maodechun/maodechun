import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/security/secret_store.dart';
import '../../core/totp/generator.dart';
import '../../core/totp/uri_parser.dart';
import '../models/token.dart';

/// 令牌仓库
///
/// 职责：
///   - 令牌的增删改查（SQLite 加密库）
///   - 密钥进出库自动加解密（明文绝不落盘）
///   - 备份数据的组装与恢复
class TokenRepository extends ChangeNotifier {
  TokenRepository._internal();
  static final TokenRepository instance = TokenRepository._internal();

  static const String _dbName = 'bodhi_tokens.db';
  static const int _dbVersion = 1;
  static const String _table = 'tokens';

  /// 数据库口令（由主密钥派生，防止数据库文件被离线打开）
  String _dbPassword = '';

  Database? _db;
  final List<Token> _tokens = [];
  bool _loaded = false;

  List<Token> get tokens => List.unmodifiable(_tokens);
  bool get isLoaded => _loaded;
  bool get isEmpty => _tokens.isEmpty;

  // ── 初始化 ───────────────────────────────────────────

  Future<Database> _openOrThrow(String path) {
    return openDatabase(
      path,
      password: _dbPassword,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id TEXT PRIMARY KEY,
            issuer TEXT NOT NULL DEFAULT '',
            account TEXT NOT NULL DEFAULT '',
            secret_encrypted TEXT NOT NULL,
            algorithm TEXT NOT NULL DEFAULT 'SHA1',
            digits INTEGER NOT NULL DEFAULT 6,
            period INTEGER NOT NULL DEFAULT 30,
            color_tag INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_sort ON $_table(sort_order, created_at)',
        );
      },
    );
  }

  Future<void> init() async {
    if (_loaded) return;

    await SecretStore.instance.init();

    // 数据库口令：由主密钥的派生值保证唯一性
    _dbPassword = _deriveDbPassword();

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);

    try {
      _db = await _openOrThrow(path);
    } on DatabaseException catch (e) {
      // 旧版本残留 / 损坏的数据库文件（密钥或格式对不上）会导致
      // open_failed："file is not a database" / "hmac check failed"。
      // 自愈：把坏文件改名备份（保留现场、不直接删除），重建空库。
      // 应用从未成功启动过时残留库基本无有效数据；即使有，备份仍可取回。
      final msg = e.toString();
      final recoverable = msg.contains('open_failed') ||
          msg.contains('not a database') ||
          msg.contains('hmac') ||
          msg.contains('file is encrypted');
      if (!recoverable) rethrow;
      // ignore: avoid_print
      print('TokenRepository: DB open failed, recovering: $msg');
      final bak = '$path.corrupt-${DateTime.now().millisecondsSinceEpoch}.bak';
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.rename(bak);
        }
      } catch (_) {
        // 改名失败（如跨挂载点）则复制后删除原文件
        try {
          final f = File(path);
          await f.copy(bak);
          await f.delete();
        } catch (_) {}
      }
      // WAL/SHM 伴生文件一并清理
      for (final suffix in ['-wal', '-shm']) {
        try {
          final f = File('$path$suffix');
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      _db = await _openOrThrow(path);
    }

    await _reload();
    _loaded = true;
    notifyListeners();
  }

  /// 派生数据库口令
  ///
  /// 必须确定性：同一主密钥每次启动派生出相同口令，否则数据库永远
  /// 打不开。此前用 encrypt()（随机 IV）派生是致命 bug——口令每次
  /// 启动都变，令牌库每次重启都被判"损坏"。
  String _deriveDbPassword() {
    final derived = SecretStore.instance.deriveDbPassword();
    if (derived.isEmpty) {
      // 安全区不可用：使用设备相关固定串，保证本次运行可用
      return 'bodhi_fallback_${Platform.operatingSystem}';
    }
    return derived;
  }

  Future<void> _reload() async {
    final db = _db;
    if (db == null) return;
    final rows = await db.query(_table, orderBy: 'sort_order ASC, created_at ASC');
    _tokens
      ..clear()
      ..addAll(rows.map((e) => Token.fromMap(Map<String, Object?>.from(e))));
  }

  // ── 增删改 ───────────────────────────────────────────

  /// 新增令牌（从扫码或手动输入解析结果）
  ///
  /// 重复检测：同 issuer + account 已存在时返回该令牌 id 并标记重复
  Future<AddTokenResult> addFromOtpAuth(OtpAuthData data) async {
    final existing = _tokens.indexWhere(
      (t) =>
          t.issuer.toLowerCase() == data.issuer.toLowerCase() &&
          t.account.toLowerCase() == data.account.toLowerCase(),
    );
    if (existing >= 0) {
      return AddTokenResult(duplicated: true, token: _tokens[existing]);
    }

    final encrypted = SecretStore.instance.encrypt(data.secret);
    if (encrypted == null) {
      return AddTokenResult(
        success: false,
        error: '密钥加密失败，请重启应用后重试',
      );
    }

    final sortOrder = _tokens.isEmpty
        ? 0
        : (_tokens.map((t) => t.sortOrder).reduce((a, b) => a > b ? a : b) + 1);

    final token = TokenFactory.fromOtpAuth(
      data: data,
      id: const Uuid().v4(),
      encryptedSecret: encrypted,
      colorTag: _tokens.length % 6,
      sortOrder: sortOrder,
    );

    await _db!.insert(_table, token.toMap());
    _tokens.add(token);
    notifyListeners();

    return AddTokenResult(success: true, token: token);
  }

  /// 从原始输入（otpauth URI / Base32）添加
  Future<AddTokenResult> addFromRawInput(String raw) async {
    final parsed = OtpAuthParser.parse(raw);
    if (!parsed.ok) {
      return AddTokenResult(success: false, error: parsed.error);
    }
    return addFromOtpAuth(parsed.data!);
  }

  /// 更新令牌信息（不含密钥）
  Future<void> updateToken(
    String id, {
    String? issuer,
    String? account,
    int? colorTag,
  }) async {
    final index = _tokens.indexWhere((t) => t.id == id);
    if (index < 0) return;

    final updated = _tokens[index].copyWith(
      issuer: issuer,
      account: account,
      colorTag: colorTag,
    );
    await _db!.update(
      _table,
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
    _tokens[index] = updated;
    notifyListeners();
  }

  /// 删除令牌
  Future<void> deleteToken(String id) async {
    await _db!.delete(_table, where: 'id = ?', whereArgs: [id]);
    _tokens.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  /// 删除全部令牌
  Future<void> deleteAll() async {
    await _db!.delete(_table);
    _tokens.clear();
    notifyListeners();
  }

  /// 调整排序
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _tokens.length) return;
    final item = _tokens.removeAt(oldIndex);
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    _tokens.insert(target.clamp(0, _tokens.length), item);

    final batch = _db!.batch();
    for (var i = 0; i < _tokens.length; i++) {
      batch.update(
        _table,
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [_tokens[i].id],
      );
    }
    await batch.commit(noResult: true);
    await _reload();
    notifyListeners();
  }

  // ── 敏感操作：读取明文密钥 ───────────────────────────

  /// 获取令牌明文密钥
  ///
  /// ⚠️ 返回的字符串生命周期应尽可能短，用后即弃，
  /// 严禁写入日志、截图或任何持久化位置。
  String? plainSecret(Token token) {
    return SecretStore.instance.decrypt(token.secretEncrypted);
  }

  /// 生成动态验证码
  ///
  /// 内部完成解密 → 计算 → 释放明文，调用方拿不到密钥
  String? generateCode(Token token, {DateTime? now}) {
    final secret = plainSecret(token);
    if (secret == null) return null;

    final code = TotpGenerator.generate(
      secret: secret,
      algorithm: TotpAlgorithm.fromString(token.algorithm),
      digits: token.digits,
      period: token.period,
      now: now,
    );
    return code;
  }

  /// 生成导出用 otpauth URI（用于 S6 导出密钥页二维码）
  String? exportUri(Token token) {
    final secret = plainSecret(token);
    if (secret == null) return null;
    return token.toOtpAuthUri(secret);
  }

  // ── 备份 / 恢复 ──────────────────────────────────────

  /// 组装备份数据（明文 JSON，调用方负责加密后传输）
  ///
  /// ⚠️ 返回值含明文密钥，仅在内存中流转，不得落盘
  String buildBackupPayload({required String deviceTag}) {
    final entries = <Map<String, Object?>>[];
    for (final token in _tokens) {
      final secret = plainSecret(token);
      if (secret == null) continue; // 解密失败的条目跳过，不阻断备份
      entries.add(token.toBackupMap(secret));
    }

    final payload = BackupPayload(
      exportedAt: DateTime.now().millisecondsSinceEpoch,
      deviceTag: deviceTag,
      tokens: entries,
    );
    return payload.toJson();
  }

  /// 从备份数据恢复
  ///
  /// [merge] true = 合并（跳过重复），false = 覆盖（先清空）
  Future<RestoreResult> restoreFromJson(
    String json, {
    bool merge = true,
  }) async {
    final payload = BackupPayload.fromJson(json);
    if (payload == null) {
      return const RestoreResult(success: false, error: '备份文件格式不正确或已损坏');
    }

    if (!merge) {
      await deleteAll();
    }

    var added = 0;
    var skipped = 0;

    for (final entry in payload.tokens) {
      final recovered = TokenFactory.fromBackupMap(
        entry,
        (plain) => SecretStore.instance.encrypt(plain) ?? '',
      );
      if (recovered == null || recovered.secretEncrypted.isEmpty) {
        skipped++;
        continue;
      }

      final dup = _tokens.any(
        (t) =>
            t.issuer.toLowerCase() == recovered.issuer.toLowerCase() &&
            t.account.toLowerCase() == recovered.account.toLowerCase(),
      );
      if (dup && merge) {
        skipped++;
        continue;
      }

      await _db!.insert(_table, recovered.toMap());
      _tokens.add(recovered);
      added++;
    }

    await _reload();
    notifyListeners();

    return RestoreResult(
      success: true,
      added: added,
      skipped: skipped,
      exportedAt: payload.exportedAt,
    );
  }

  /// 生成备份文件名（DT 专有加密格式）
  static String buildBackupFileName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'bodhi_token_backup_'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.dt';
  }

  @override
  void dispose() {
    _db?.close();
    _db = null;
    super.dispose();
  }
}

/// 添加令牌结果
class AddTokenResult {
  final bool success;
  final bool duplicated;
  final Token? token;
  final String? error;

  const AddTokenResult({
    this.success = false,
    this.duplicated = false,
    this.token,
    this.error,
  });
}

/// 恢复结果
class RestoreResult {
  final bool success;
  final int added;
  final int skipped;
  final int exportedAt;
  final String? error;

  const RestoreResult({
    required this.success,
    this.added = 0,
    this.skipped = 0,
    this.exportedAt = 0,
    this.error,
  });
}
