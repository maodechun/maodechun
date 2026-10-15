import 'package:flutter/services.dart';

import '../../core/security/secret_store.dart';
import '../repository/token_repository.dart';

/// 本地密钥备份服务
///
/// 将令牌数据经用户密码加密（与 FTP 备份同格式：PBKDF2 派生密钥 +
/// AES-256-CBC），写入系统「下载/菩提护令备份」目录。
///
/// 特性：
///   - 写入公共下载目录（MediaStore），卸载重装后文件依然存在
///   - 本应用作为文件 owner 始终可读，重装后可直接恢复
///   - 无备份密码（至少 6 位）任何人无法解密
class LocalBackupService {
  LocalBackupService._internal();
  static final LocalBackupService instance = LocalBackupService._internal();

  static const MethodChannel _channel = MethodChannel('bodhi/local_backup');

  /// 备份到本机
  ///
  /// [password] 备份密码（≥6 位），用于加密备份文件
  Future<LocalBackupResult> backup(String password) async {
    if (password.length < 6) {
      return const LocalBackupResult(
        success: false,
        message: '备份失败：备份密码至少 6 位',
      );
    }

    final repo = TokenRepository.instance;
    if (repo.isEmpty) {
      return const LocalBackupResult(
        success: false,
        message: '备份失败：当前没有任何令牌',
      );
    }

    final String plainJson;
    try {
      plainJson = repo.buildBackupPayload(deviceTag: 'local');
    } catch (e) {
      return LocalBackupResult(
        success: false,
        message: '备份失败：无法读取令牌数据（$e）',
      );
    }
    if (plainJson.isEmpty) {
      return const LocalBackupResult(
        success: false,
        message: '备份失败：无法读取令牌数据',
      );
    }

    final encrypted = SecretStore.encryptWithPassword(plainJson, password);
    final fileName = TokenRepository.buildBackupFileName();

    try {
      final r = await _channel.invokeMethod<Map>('saveBackup', {
        'name': fileName,
        'content': encrypted,
      });
      final location = (r?['location'] as String?) ?? fileName;
      return LocalBackupResult(
        success: true,
        message: '备份成功，已保存到 $location',
        fileName: fileName,
      );
    } on PlatformException catch (e) {
      return LocalBackupResult(
        success: false,
        message: '备份失败：${e.message ?? "存储不可用"}',
      );
    } on MissingPluginException {
      return const LocalBackupResult(
        success: false,
        message: '备份失败：本机不支持（缺少存储通道）',
      );
    }
  }

  /// 列出本机备份文件（按时间倒序）
  Future<List<LocalBackupFile>> listBackups() async {
    // ignore: avoid_print
    print('[LocalBackup] listBackups begin');
    try {
      final list = await _channel.invokeListMethod<Map>('listBackups');
      // ignore: avoid_print
      print('[LocalBackup] listBackups raw=${list?.length}');
      if (list == null) return [];
      final files = list
          .map((m) => LocalBackupFile(
                id: (m['id'] ?? '') as String,
                name: (m['name'] ?? '') as String,
                size: (m['size'] as num?)?.toInt() ?? 0,
              ))
          .where((f) => f.id.isNotEmpty && f.name.endsWith('.btk'))
          .toList();
      // ignore: avoid_print
      print('[LocalBackup] listBackups files=${files.length}');
      return files;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[LocalBackup] listBackups PlatformException: ${e.code} ${e.message}');
      return [];
    } on MissingPluginException {
      // ignore: avoid_print
      print('[LocalBackup] listBackups MissingPluginException');
      return [];
    }
  }

  /// 拉起系统文件管理器选择备份文件（SAF）
  ///
  /// 卸载重装后 MediaStore 索引被清空、查询不到旧备份时，
  /// 用系统文件选择器直接读取下载目录中的 .btk 文件。
  /// 返回 null = 用户取消。
  Future<LocalBackupFile?> pickBackup() async {
    try {
      // ignore: avoid_print
      print('[LocalBackup] pickBackup begin');
      final m = await _channel.invokeMapMethod<String, dynamic>('pickBackup');
      if (m == null) {
        // ignore: avoid_print
        print('[LocalBackup] pickBackup cancelled');
        return null;
      }
      final f = LocalBackupFile(
        id: (m['id'] ?? '') as String,
        name: (m['name'] ?? '') as String,
        size: (m['size'] as num?)?.toInt() ?? 0,
      );
      // ignore: avoid_print
      print('[LocalBackup] pickBackup picked: ${f.name}');
      return f;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[LocalBackup] pickBackup PlatformException: ${e.code}');
      return null;
    } on MissingPluginException {
      // ignore: avoid_print
      print('[LocalBackup] pickBackup MissingPluginException');
      return null;
    }
  }

  /// 从本机备份文件恢复
  ///
  /// [merge] true 时与现有令牌合并（重复跳过）
  Future<LocalBackupResult> restore(
    String id,
    String password, {
    bool merge = true,
  }) async {
    final String content;
    try {
      content =
          await _channel.invokeMethod<String>('readBackup', {'id': id}) ?? '';
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[LocalBackup] restore readBackup PlatformException: ${e.code} ${e.message}');
      return LocalBackupResult(
        success: false,
        message: '恢复失败：无法读取备份文件（${e.message ?? "未知"}）',
      );
    } on MissingPluginException {
      return const LocalBackupResult(
        success: false,
        message: '恢复失败：本机不支持（缺少存储通道）',
      );
    }

    // ignore: avoid_print
    print('[LocalBackup] restore contentLen=${content.length} head=${content.substring(0, content.length > 24 ? 24 : content.length)}');

    if (content.isEmpty) {
      return const LocalBackupResult(
        success: false,
        message: '恢复失败：备份文件为空',
      );
    }

    final plain = SecretStore.decryptWithPassword(content, password);
    // ignore: avoid_print
    print('[LocalBackup] restore decrypt ${plain == null ? "FAILED" : "ok len=${plain.length}"}');
    if (plain == null) {
      return const LocalBackupResult(
        success: false,
        message: '恢复失败：备份密码错误，或文件已损坏',
      );
    }

    try {
      final result =
          await TokenRepository.instance.restoreFromJson(plain, merge: merge);
      // ignore: avoid_print
      print('[LocalBackup] restore repo result success=${result.success} added=${result.added} skipped=${result.skipped} err=${result.error}');
      if (!result.success) {
        return LocalBackupResult(
          success: false,
          message: '恢复失败：${result.error ?? "未知错误"}',
        );
      }
      final msg = result.skipped > 0
          ? '恢复成功：新增 ${result.added} 条，跳过重复 ${result.skipped} 条'
          : '恢复成功：新增 ${result.added} 条';
      return LocalBackupResult(success: true, message: msg);
    } catch (e) {
      // ignore: avoid_print
      print('[LocalBackup] restore repo EXCEPTION: $e');
      return LocalBackupResult(success: false, message: '恢复失败：$e');
    }
  }

  /// 删除本机备份文件
  Future<bool> delete(String id) async {
    try {
      return await _channel.invokeMethod<bool>('deleteBackup', {'id': id}) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}

/// 本机备份文件条目
class LocalBackupFile {
  final String id;
  final String name;
  final int size;

  const LocalBackupFile({
    required this.id,
    required this.name,
    required this.size,
  });

  String get humanSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 本地备份 / 恢复结果
class LocalBackupResult {
  final bool success;
  final String message;
  final String? fileName;

  const LocalBackupResult({
    required this.success,
    required this.message,
    this.fileName,
  });
}
