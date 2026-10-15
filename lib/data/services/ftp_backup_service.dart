import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/security/secret_store.dart';
import '../repository/token_repository.dart';

/// FTP 服务器配置
class FtpConfig {
  final String host;
  final int port;
  final String username;
  final String password;
  final bool useFtps; // 显式 TLS

  const FtpConfig({
    this.host = '',
    this.port = 21,
    this.username = '',
    this.password = '',
    this.useFtps = true,
  });

  bool get isValid =>
      host.trim().isNotEmpty &&
      port > 0 &&
      port <= 65535 &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  Map<String, String> toPrefs() => {
        'ftp_host': host,
        'ftp_port': port.toString(),
        'ftp_user': username,
        'ftp_pass': password,
        'ftp_ftps': useFtps ? '1' : '0',
      };

  static FtpConfig fromPrefs(SharedPreferences prefs) => FtpConfig(
        host: prefs.getString('ftp_host') ?? '',
        port: int.tryParse(prefs.getString('ftp_port') ?? '21') ?? 21,
        username: prefs.getString('ftp_user') ?? '',
        password: prefs.getString('ftp_pass') ?? '',
        useFtps: (prefs.getString('ftp_ftps') ?? '1') == '1',
      );

  FtpConfig copyWith({
    String? host,
    int? port,
    String? username,
    String? password,
    bool? useFtps,
  }) =>
      FtpConfig(
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        useFtps: useFtps ?? this.useFtps,
      );
}

/// FTP 备份服务
///
/// 安全设计：
///   - 备份文件在本地先经 AES-256 加密，再上传至用户自有服务器
///   - 服务器信息仅保存在本机，不上传任何第三方
///   - 优先 FTPS（显式 TLS），不可用时降级并明确提示风险
class FtpBackupService {
  FtpBackupService._internal();
  static final FtpBackupService instance = FtpBackupService._internal();

  static const String _remoteDir = '/bodhi_backup';
  static const int _maxBackups = 7; // 保留最近 7 份

  FTPConnect? _client;

  // ── 配置读写 ─────────────────────────────────────────

  Future<FtpConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return FtpConfig.fromPrefs(prefs);
  }

  Future<void> saveConfig(FtpConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final data = config.toPrefs();
    for (final entry in data.entries) {
      await prefs.setString(entry.key, entry.value);
    }
  }

  // ── 连接 ─────────────────────────────────────────────

  /// 测试连接
  Future<TestResult> testConnection(FtpConfig config) async {
    if (!config.isValid) {
      return const TestResult(
        success: false,
        message: '请完整填写服务器地址、端口、账号与密码',
      );
    }

    final client = FTPConnect(
      config.host,
      port: config.port,
      user: config.username,
      pass: config.password,
      timeout: 10,
      securityType:          config.useFtps ? SecurityType.ftps : SecurityType.ftp,
      showLog: false,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 12));
      await client.changeDirectory(_remoteDir);

      final pwd = await client.currentDirectory();
      await client.disconnect();

      return TestResult(
        success: true,
        message: '连接成功（${pwd.isNotEmpty ? pwd : '/'}）',
        secured: config.useFtps,
      );
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}

      return TestResult(
        success: false,
        message: _readableError(e),
      );
    }
  }

  // ── 备份 ─────────────────────────────────────────────

  /// 执行备份
  ///
  /// [password] 用户设置的备份密码，用于加密备份文件
  /// [progress] 进度回调（0.0 ~ 1.0）
  Future<BackupResult> backup({
    required FtpConfig config,
    required String password,
    void Function(double progress, String stage)? progress,
  }) async {
    if (!config.isValid) {
      return const BackupResult(
        success: false,
        message: '备份失败：服务器信息不完整，请先在设置中填写',
      );
    }
    if (password.length < 6) {
      return const BackupResult(
        success: false,
        message: '备份失败：备份密码至少 6 位',
      );
    }

    final repo = TokenRepository.instance;
    if (repo.isEmpty) {
      return const BackupResult(
        success: false,
        message: '备份失败：当前没有任何令牌',
      );
    }

    progress?.call(0.1, '正在整理令牌数据');
    final deviceTag = await _deviceTag();
    final plainJson = repo.buildBackupPayload(deviceTag: deviceTag);
    if (plainJson.isEmpty) {
      return const BackupResult(
        success: false,
        message: '备份失败：无法读取令牌数据',
      );
    }

    progress?.call(0.3, '正在加密备份数据');
    final encrypted = SecretStore.encryptWithPassword(plainJson, password);

    final fileName = TokenRepository.buildBackupFileName();
    final dir = await _tempDir();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(encrypted, flush: true);

    progress?.call(0.5, '正在连接服务器');

    final client = FTPConnect(
      config.host,
      port: config.port,
      user: config.username,
      pass: config.password,
      timeout: 15,
      securityType:          config.useFtps ? SecurityType.ftps : SecurityType.ftp,
      showLog: false,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 15));

      progress?.call(0.7, '正在创建备份目录');
      await client.createFolderIfNotExist(_remoteDir);
      await client.changeDirectory(_remoteDir);

      progress?.call(0.85, '正在上传备份文件');
      await client.uploadFile(
        file,
        sRemoteName: fileName,
        onProgress: (progressInPercent, totalReceived, fileSize) {
          // 上传阶段映射到 0.85 ~ 0.98
          final ratio = (progressInPercent / 100).clamp(0.0, 1.0);
          progress?.call(0.85 + ratio * 0.13, '上传中');
        },
      );

      progress?.call(0.98, '正在清理旧备份');
      await _cleanupOldBackups(client, fileName);

      await client.disconnect();
      progress?.call(1.0, '备份完成');

      // 清理本地临时文件（含加密数据）
      await _safeDelete(file);

      return BackupResult(
        success: true,
        message: '备份成功：$fileName',
        fileName: fileName,
        secured: config.useFtps,
      );
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      await _safeDelete(file);

      return BackupResult(
        success: false,
        message: '备份失败：${_readableError(e)}',
      );
    }
  }

  // ── 恢复 ─────────────────────────────────────────────

  /// 列出服务器上的备份文件（按时间倒序）
  Future<List<String>> listBackups(FtpConfig config) async {
    if (!config.isValid) return [];

    final client = FTPConnect(
      config.host,
      port: config.port,
      user: config.username,
      pass: config.password,
      timeout: 15,
      securityType:          config.useFtps ? SecurityType.ftps : SecurityType.ftp,
      showLog: false,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await client.changeDirectory(_remoteDir);
      final entries = await client.listDirectoryContent();
      await client.disconnect();

      final files = entries
          .where((e) => e.name.endsWith('.btk'))
          .map((e) => e.name)
          .toList()
        ..sort((a, b) => b.compareTo(a)); // 文件名含时间戳，倒序即最新在前

      return files;
    } catch (_) {
      try {
        await client.disconnect();
      } catch (_) {}
      return [];
    }
  }

  /// 从服务器下载并恢复
  Future<BackupResult> restore({
    required FtpConfig config,
    required String fileName,
    required String password,
    bool merge = true,
    void Function(double progress, String stage)? progress,
  }) async {
    if (!config.isValid) {
      return const BackupResult(
        success: false,
        message: '恢复失败：服务器信息不完整',
      );
    }

    progress?.call(0.2, '正在连接服务器');

    final client = FTPConnect(
      config.host,
      port: config.port,
      user: config.username,
      pass: config.password,
      timeout: 15,
      securityType:          config.useFtps ? SecurityType.ftps : SecurityType.ftp,
      showLog: false,
    );

    final dir = await _tempDir();
    final file = File('${dir.path}/$fileName');

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await client.changeDirectory(_remoteDir);

      progress?.call(0.5, '正在下载备份文件');
      await client.downloadFile(fileName, file);

      await client.disconnect();
      progress?.call(0.7, '正在解密数据');

      final encrypted = await file.readAsString();
      final plain = SecretStore.decryptWithPassword(encrypted, password);
      if (plain == null) {
        await _safeDelete(file);
        return const BackupResult(
          success: false,
          message: '恢复失败：备份密码错误，或文件已损坏',
        );
      }

      progress?.call(0.9, '正在导入令牌');
      final result = await TokenRepository.instance
          .restoreFromJson(plain, merge: merge);

      await _safeDelete(file);
      progress?.call(1.0, '恢复完成');

      if (!result.success) {
        return BackupResult(
          success: false,
          message: '恢复失败：${result.error ?? "未知错误"}',
        );
      }

      final msg = result.skipped > 0
          ? '恢复成功：新增 ${result.added} 条，跳过重复 ${result.skipped} 条'
          : '恢复成功：新增 ${result.added} 条';

      return BackupResult(success: true, message: msg, fileName: fileName);
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      await _safeDelete(file);
      return BackupResult(
        success: false,
        message: '恢复失败：${_readableError(e)}',
      );
    }
  }

  // ── 内部工具 ─────────────────────────────────────────

  /// 清理超出保留数量的旧备份
  Future<void> _cleanupOldBackups(FTPConnect client, String justUploaded) async {
    try {
      final entries = await client.listDirectoryContent();
      final backups = entries
          .where((e) => e.name.endsWith('.btk'))
          .map((e) => e.name)
          .toList()
        ..sort((a, b) => b.compareTo(a)); // 最新在前

      if (backups.length <= _maxBackups) return;

      for (final name in backups.sublist(_maxBackups)) {
        if (name == justUploaded) continue;
        try {
          await client.deleteFile(name);
        } catch (_) {
          // 单个删除失败不影响整体
        }
      }
    } catch (_) {
      // 列表不可用则跳过清理
    }
  }

  Future<String> _deviceTag() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        return 'android-${android.model}-${android.id.hashCode.abs()}';
      } else if (Platform.isIOS) {
        final ios = await info.iosInfo;
        return 'ios-${ios.utsname.machine}-${ios.identifierForVendor ?? "unknown"}';
      }
    } catch (_) {}
    return 'unknown-device';
  }

  Future<Directory> _tempDir() async {
    final dir = Directory.systemTemp;
    final sub = Directory('${dir.path}/bodhi_tmp');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    return sub;
  }

  /// 安全删除（先覆写再删除，降低残留风险）
  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) {
        final len = await file.length();
        if (len > 0 && len < 1024 * 1024) {
          // 小于 1MB 时覆写一次
          await file.writeAsString('0' * len, flush: true);
        }
        await file.delete();
      }
    } catch (_) {}
  }

  /// 将底层异常转为用户可读提示
  String _readableError(Object e) {
    final text = e.toString().toLowerCase();
    if (text.contains('timeout') || text.contains('timed out')) {
      return '连接超时，请检查服务器地址与网络';
    }
    if (text.contains('auth') || text.contains('530') || text.contains('login')) {
      return '认证失败，请检查账号与密码';
    }
    if (text.contains('550') || text.contains('permission') || text.contains('denied')) {
      return '服务器拒绝了操作，请检查目录写入权限';
    }
    if (text.contains('socket') || text.contains('connect') || text.contains('refused')) {
      return '无法连接服务器，请检查地址、端口与网络';
    }
    if (text.contains('certificate') || text.contains('tls') || text.contains('ssl')) {
      return '加密握手失败，可尝试关闭 FTPS 或检查服务器证书';
    }
    return '操作失败，请稍后重试';
  }
}

/// 连接测试结果
class TestResult {
  final bool success;
  final String message;
  final bool secured;

  const TestResult({
    required this.success,
    required this.message,
    this.secured = false,
  });
}

/// 备份 / 恢复结果
class BackupResult {
  final bool success;
  final String message;
  final String? fileName;
  final bool secured;

  const BackupResult({
    required this.success,
    required this.message,
    this.fileName,
    this.secured = false,
  });
}
