import 'dart:convert';
import 'package:flutter/services.dart';

import '../../core/security/dt_cipher.dart';
import '../repository/token_repository.dart';

/// 本地密钥备份服务
///
/// 将令牌数据经用户密码加密（DT 专有强加密容器，见 DtCipher），
/// 写入系统「下载/菩提护令备份」目录。
///
/// 特性：
///   - 写入公共下载目录（MediaStore），卸载重装后文件依然存在
///   - 原生侧三级写入兜底，任一位置可写即成功，并如实上报落盘位置
///   - 无备份密码（至少 6 位）任何人无法解密
///
/// 约定：**任何失败都必须返回可读原因**，不允许静默返回 null。
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
        message: '备份失败：当前没有任何令牌，请先添加令牌再备份',
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

    // DT 专有强加密容器（AES-256-GCM + PBKDF2 高轮次 + HMAC 防篡改），
    // 以 base64 文本写入（原生存储通道要求字符串内容）
    final String encrypted;
    final String fileName;
    try {
      encrypted = DtCipher.encryptToText(plainJson, password);
      fileName = TokenRepository.buildBackupFileName();
    } catch (e) {
      return LocalBackupResult(
        success: false,
        message: '备份失败：加密过程出错（$e）',
      );
    }

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
        message: '备份失败：${e.message ?? e.code}',
      );
    } on MissingPluginException {
      return const LocalBackupResult(
        success: false,
        message: '备份失败：本机不支持（缺少存储通道 bodhi/local_backup，'
            '说明安装的应用包不完整，请重新安装最新版）',
      );
    } catch (e) {
      return LocalBackupResult(
        success: false,
        message: '备份失败：$e',
      );
    }
  }

  /// 列出本机备份文件（按时间倒序）
  ///
  /// 原生侧会同时扫描 MediaStore 索引与多个下载目录并去重，
  /// 避免「重装后索引被清空、找不到备份」。
  Future<List<LocalBackupFile>> listBackups() async {
    try {
      final list = await _channel.invokeListMethod<Map>('listBackups');
      if (list == null) return [];
      return list
          .map((m) => LocalBackupFile(
                id: (m['id'] ?? '') as String,
                name: (m['name'] ?? '') as String,
                size: (m['size'] as num?)?.toInt() ?? 0,
              ))
          .where((f) =>
              f.id.isNotEmpty &&
              (f.name.endsWith('.dt') || f.name.endsWith('.btk')))
          .toList();
    } on PlatformException {
      return [];
    } on MissingPluginException {
      return [];
    }
  }

  /// 本机存储自检：把「哪一步坏了」直接取回来给用户看
  Future<StorageDiagnostics> selfTest() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('selfTest');
      if (m == null) {
        return const StorageDiagnostics(lines: ['自检未返回数据（原生通道无响应）']);
      }
      final lines = <String>[
        '存储通道：${m['channel']}',
        '系统版本：Android API ${m['sdkInt']}',
        'MediaStore 写入：${m['mediaStore']}',
        '候选目录（共 ${m['dirCount']} 个）：',
        ...((m['dirs'] as List?) ?? const []).map((e) => '  · $e'),
        '已找到的备份文件：${((m['found'] as List?) ?? const []).isEmpty ? "无" : (m['found'] as List).join("、")}',
      ];
      return StorageDiagnostics(lines: lines);
    } on PlatformException catch (e) {
      return StorageDiagnostics(
        lines: ['自检失败：${e.message ?? e.code}'],
      );
    } on MissingPluginException {
      return const StorageDiagnostics(
        lines: ['自检失败：本机不支持（缺少存储通道 bodhi/local_backup）'],
      );
    }
  }

  /// 拉起系统文件管理器选择备份文件（SAF）
  ///
  /// 返回值区分三种情况：
  ///   - [LocalPickResult.file] 非空 → 用户选中了文件
  ///   - [LocalPickResult.error] 非空 → 选择器无法打开（附具体原因）
  ///   - 两者都为空 → 用户主动取消
  Future<LocalPickResult> pickBackup() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('pickBackup');
      if (m == null) return const LocalPickResult(); // 用户取消
      return LocalPickResult(
        file: LocalBackupFile(
          id: (m['id'] ?? '') as String,
          name: (m['name'] ?? '') as String,
          size: (m['size'] as num?)?.toInt() ?? 0,
        ),
      );
    } on PlatformException catch (e) {
      return LocalPickResult(
        error: e.message ?? '无法打开系统文件选择器（${e.code}）',
      );
    } on MissingPluginException {
      return const LocalPickResult(
        error: '本机不支持（缺少存储通道 bodhi/local_backup），请重新安装最新版',
      );
    } catch (e) {
      return LocalPickResult(error: '$e');
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
    if (id.trim().isEmpty) {
      return const LocalBackupResult(
        success: false,
        message: '恢复失败：未选择备份文件',
      );
    }

    final String content;
    try {
      content =
          await _channel.invokeMethod<String>('readBackup', {'id': id}) ?? '';
    } on PlatformException catch (e) {
      return LocalBackupResult(
        success: false,
        message: '恢复失败：无法读取备份文件（${e.message ?? e.code}）',
      );
    } on MissingPluginException {
      return const LocalBackupResult(
        success: false,
        message: '恢复失败：本机不支持（缺少存储通道 bodhi/local_backup），'
            '请重新安装最新版',
      );
    } catch (e) {
      return LocalBackupResult(
        success: false,
        message: '恢复失败：无法读取备份文件（$e）',
      );
    }

    if (content.trim().isEmpty) {
      return const LocalBackupResult(
        success: false,
        message: '恢复失败：备份文件内容为空（可能不是本应用生成的备份）',
      );
    }

    final String? plain;
    try {
      plain = DtCipher.decryptAny(utf8.encode(content), password);
    } catch (e) {
      return LocalBackupResult(
        success: false,
        message: '恢复失败：解密过程出错（$e）',
      );
    }
    if (plain == null) {
      return const LocalBackupResult(
        success: false,
        message: '恢复失败：备份密码错误，或文件已损坏/被篡改',
      );
    }

    try {
      final result =
          await TokenRepository.instance.restoreFromJson(plain, merge: merge);
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
    } on MissingPluginException {
      return false;
    }
  }
}

/// 系统文件选择结果（区分「取消」与「打开失败」）
class LocalPickResult {
  final LocalBackupFile? file;
  final String? error;

  const LocalPickResult({this.file, this.error});

  /// 用户主动取消
  bool get cancelled => file == null && error == null;
}

/// 本机存储自检报告
class StorageDiagnostics {
  final List<String> lines;

  const StorageDiagnostics({required this.lines});
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
