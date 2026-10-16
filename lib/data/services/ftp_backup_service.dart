import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/security/dt_cipher.dart';
import '../repository/token_repository.dart';

/// FTP 服务器配置
class FtpConfig {
  final String host;
  final int port;
  final String username;
  final String password;
  final bool useFtps; // 显式 TLS

  /// 备份存放目录（用户在服务器上自行选择）
  ///
  /// 默认 `/bodhi_backup`；用户可在设置里浏览服务器目录树自由指定，
  /// 例如 `/www/backup` 或 `/home/ftpuser/bodhi`。
  final String remoteDir;

  const FtpConfig({
    this.host = '',
    this.port = 21,
    this.username = '',
    this.password = '',
    this.useFtps = true,
    this.remoteDir = FtpBackupService.defaultRemoteDir,
  });

  bool get isValid =>
      host.trim().isNotEmpty &&
      port > 0 &&
      port <= 65535 &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  /// 归一化后的备份目录：始终以 `/` 开头、不带结尾 `/`
  ///
  /// FTP 服务器对相对路径的解析各不相同（有的相对登录主目录、
  /// 有的相对当前目录），统一成绝对路径最稳。
  String get normalizedRemoteDir {
    var d = remoteDir.trim().replaceAll('\\', '/');
    if (d.isEmpty) return FtpBackupService.defaultRemoteDir;
    if (!d.startsWith('/')) d = '/$d';
    while (d.length > 1 && d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    return d;
  }

  Map<String, String> toPrefs() => {
        'ftp_host': host,
        'ftp_port': port.toString(),
        'ftp_user': username,
        'ftp_pass': password,
        'ftp_ftps': useFtps ? '1' : '0',
        'ftp_dir': normalizedRemoteDir,
      };

  static FtpConfig fromPrefs(SharedPreferences prefs) => FtpConfig(
        host: prefs.getString('ftp_host') ?? '',
        port: int.tryParse(prefs.getString('ftp_port') ?? '21') ?? 21,
        username: prefs.getString('ftp_user') ?? '',
        password: prefs.getString('ftp_pass') ?? '',
        useFtps: (prefs.getString('ftp_ftps') ?? '1') == '1',
        remoteDir:
            prefs.getString('ftp_dir') ?? FtpBackupService.defaultRemoteDir,
      );

  FtpConfig copyWith({
    String? host,
    int? port,
    String? username,
    String? password,
    bool? useFtps,
    String? remoteDir,
  }) =>
      FtpConfig(
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        useFtps: useFtps ?? this.useFtps,
        remoteDir: remoteDir ?? this.remoteDir,
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

  /// 默认备份目录（用户未自行选择时使用）
  static const String defaultRemoteDir = '/bodhi_backup';

  static const int _maxBackups = 7; // 保留最近 7 份

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

  /// 最近一次 [listEntries] 失败的原因（供界面提示用）
  String? lastListError;

  /// 协商出「实际可用的加密模式」
  ///
  /// ftpconnect 2.x 的 [SecurityType] 有三种语义，容易混淆：
  ///   - `ftp`   ：明文 FTP
  ///   - `ftpes` ：**显式** TLS（连上后发 AUTH TLS 升级）——标准 FTPS 服务器走这个
  ///   - `ftps`  ：**隐式** TLS（一连接就是 TLS，默认端口 990）
  ///
  /// 历史问题：代码把所有「使用 FTPS」都当成 `ftps`（隐式/990），
  /// 而用户服务器基本都是「21 端口 + 显式 TLS」或「21 端口 + 明文」，
  /// 于是必然握手失败 —— 用户看到的现象就是「根本没有连接上 FTP 服务器」。
  ///
  /// 现在按 显式 TLS → 隐式 TLS(990) → 明文 的顺序自动探测，
  /// 只要有一种能通就用那一种，优先保证「能用」。
  Future<_FtpConn> _resolveConn(FtpConfig config) async {
    if (!config.useFtps) return _FtpConn(config, SecurityType.ftp);

    // 1) 显式 TLS（AUTH TLS），端口保持不变
    if (await _probeConnect(config, SecurityType.ftpes)) {
      return _FtpConn(config, SecurityType.ftpes);
    }
    // 2) 隐式 TLS，通常监听 990
    if (config.port != 990) {
      final implicit = config.copyWith(port: 990);
      if (await _probeConnect(implicit, SecurityType.ftps)) {
        return _FtpConn(implicit, SecurityType.ftps);
      }
    }
    // 3) 服务器不支持任何加密：降级明文 FTP
    //    备份文件本身已用 DT 强加密，明文只影响传输通道，内容依然安全
    return _FtpConn(config.copyWith(useFtps: false), SecurityType.ftp);
  }

  /// 用指定加密模式试连一次
  Future<bool> _probeConnect(FtpConfig config, SecurityType type) async {
    final probe = _newClient(config, type, timeout: 8);
    try {
      final ok = await probe.connect().timeout(const Duration(seconds: 10));
      try {
        await probe.disconnect();
      } catch (_) {}
      return ok;
    } catch (_) {
      try {
        await probe.disconnect();
      } catch (_) {}
      return false;
    }
  }

  FTPConnect _newClient(FtpConfig config, SecurityType type, {int timeout = 15}) =>
      FTPConnect(
        config.host,
        port: config.port,
        user: config.username,
        pass: config.password,
        timeout: timeout,
        securityType: type,
        showLog: false,
      );

  /// 纯 TCP 可达性探测
  ///
  /// 先确认「网络 + 端口」能不能通，把「服务器根本没连上」和
  /// 「连上了但账号/权限有问题」彻底分开，用户看提示就能自查。
  /// 返回 null 表示 TCP 可达，否则返回可读错误。
  Future<String?> _tcpProbe(FtpConfig config) async {
    Socket? s;
    try {
      s = await Socket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 8),
      );
      return null;
    } catch (e) {
      return _readableError(e);
    } finally {
      try {
        s?.destroy();
      } catch (_) {}
    }
  }

  String _modeLabel(FtpConfig requested, _FtpConn conn) {
    switch (conn.type) {
      case SecurityType.ftpes:
        return 'FTPS（显式 TLS 加密）';
      case SecurityType.ftps:
        return 'FTPS（隐式 TLS 加密，端口 990）';
      case SecurityType.ftp:
        return requested.useFtps
            ? '普通 FTP（服务器不支持 FTPS，已自动降级；备份文件仍为 DT 强加密）'
            : '普通 FTP（明文传输）';
    }
  }

  /// 测试连接
  ///
  /// 依次给出四类结果：
  ///   1. 网络/端口不通（与账号密码无关）
  ///   2. 登录成功且备份目录就绪
  ///   3. 登录成功但备份目录不可用（附原因）
  ///   4. 登录失败（附具体原因：530 认证 / 421 限流 / TLS 握手…）
  Future<TestResult> testConnection(FtpConfig config) async {
    if (!config.isValid) {
      return const TestResult(
        success: false,
        message: '请完整填写服务器地址、端口、账号与密码',
      );
    }

    // 第一步：网络与端口可达性（失败与账号密码无关）
    final tcpErr = await _tcpProbe(config);
    if (tcpErr != null) {
      return TestResult(
        success: false,
        message: '无法连接到 ${config.host}:${config.port}\n'
            '$tcpErr\n'
            '（此步失败说明网络或端口不通，与账号密码无关：'
            '请核对服务器地址与端口，并确认手机当前网络允许访问该端口）',
      );
    }

    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));

      String pwd = '/';
      try {
        pwd = await client.currentDirectory();
      } catch (_) {}

      // 备份目录：能进就进；不存在就逐级创建；仍失败只提示，不影响连接成功
      final remoteDir = config.normalizedRemoteDir;
      var dirReady = true;
      String dirNote = '';
      try {
        await _ensureDir(client, remoteDir);
      } catch (e) {
        dirReady = false;
        dirNote = '；但备份目录 $remoteDir 不可用（${_readableError(e)}）';
      }

      await client.disconnect();

      return TestResult(
        success: true,
        message: '登录成功，当前目录：${pwd.isNotEmpty ? pwd : "/"}'
            '${dirReady ? "，备份目录 $remoteDir 已就绪" : dirNote}'
            '\n传输模式：${_modeLabel(config, conn)}',
        secured: conn.type != SecurityType.ftp,
      );
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}

      return TestResult(
        success: false,
        message: '${_readableError(e)}\n'
            '传输模式：${_modeLabel(config, conn)}',
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

    progress?.call(0.3, '正在加密备份数据（DT 专有强加密）');
    final encryptedBytes = DtCipher.encryptToBytes(plainJson, password);

    final fileName = TokenRepository.buildBackupFileName();
    final remoteDir = config.normalizedRemoteDir;
    final dir = await _tempDir();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(encryptedBytes, flush: true);

    progress?.call(0.5, '正在连接服务器');

    // 自动协商加密模式（显式 TLS → 隐式 TLS → 明文），避免连不上
    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));

      progress?.call(0.7, '正在进入备份目录 $remoteDir');
      await _ensureDir(client, remoteDir);

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
        secured: conn.type != SecurityType.ftp,
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
    lastListError = null;
    if (!config.isValid) {
      lastListError = '服务器信息不完整';
      return [];
    }

    // 自动协商加密模式（显式 TLS → 隐式 TLS → 明文），避免连不上
    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await _ensureDir(client, config.normalizedRemoteDir);
      final entries = await client.listDirectoryContent();
      await client.disconnect();

      final files = entries
          .where((e) => e.name.endsWith('.dt') || e.name.endsWith('.btk'))
          .map((e) => e.name)
          .toList()
        ..sort((a, b) => b.compareTo(a)); // 文件名含时间戳，倒序即最新在前

      return files;
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      lastListError = _readableError(e);
      return [];
    }
  }

  /// 列出备份目录下全部条目（文件管理用）
  Future<List<FtpEntryInfo>> listEntries(FtpConfig config) async {
    lastListError = null;
    if (!config.isValid) {
      lastListError = '服务器信息不完整';
      return const [];
    }

    // 自动协商加密模式（显式 TLS → 隐式 TLS → 明文），避免连不上
    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await _ensureDir(client, config.normalizedRemoteDir);
      final entries = await client.listDirectoryContent();
      await client.disconnect();

      final list = entries
          .where((e) => e.name != '.' && e.name != '..')
          .map(
            (e) => FtpEntryInfo(
              name: e.name,
              isDir: e.type == FTPEntryType.dir,
              size: e.size ?? 0,
              modifyTime: e.modifyTime,
            ),
          )
          .toList()
        ..sort((a, b) {
          // 文件夹在前，其余按名称倒序（备份文件名含时间戳，新的在前）
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return b.name.compareTo(a.name);
        });
      return list;
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      // 记录失败原因，界面据此提示「读取失败」而不是「目录为空」
      lastListError = _readableError(e);
      return const [];
    }
  }

  /// 浏览服务器目录树 —— 供用户自行选择「备份到哪个目录」
  ///
  /// [path] 目标路径，缺省 `/`（服务器根，多数 FTP 账号会被限制在登录主目录）。
  /// 返回该路径下的子目录列表 + 服务器解析后的真实路径（便于上级跳转）。
  Future<FtpDirListing> listDirectories(
    FtpConfig config, {
    String path = '/',
  }) async {
    if (!config.isValid) {
      return const FtpDirListing(
        success: false,
        path: '/',
        dirs: [],
        error: '服务器信息不完整，请先填写地址、端口、账号与密码',
      );
    }

    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await client.changeDirectory(path);

      // 以服务器返回的真实路径为准（有的服务器把根映射到登录主目录）
      var real = path;
      try {
        real = await client.currentDirectory();
      } catch (_) {}

      final entries = await client.listDirectoryContent();
      await client.disconnect();

      final dirs = entries
          .where((e) => e.type == FTPEntryType.dir)
          .map((e) => e.name)
          .where((n) => n != '.' && n != '..' && n.trim().isNotEmpty)
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      return FtpDirListing(success: true, path: real, dirs: dirs);
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      return FtpDirListing(
        success: false,
        path: path,
        dirs: const [],
        error: _readableError(e),
      );
    }
  }

  /// 在服务器指定目录下新建子目录（供用户挑选目录时即时建目录）
  Future<BackupResult> createDirectoryAt(
    FtpConfig config, {
    required String parent,
    required String name,
  }) async {
    if (!config.isValid) {
      return const BackupResult(
        success: false,
        message: '新建失败：服务器信息不完整',
      );
    }
    final clean = name.trim();
    if (clean.isEmpty ||
        clean.contains('/') ||
        clean.contains('\\') ||
        clean == '.' ||
        clean == '..' ||
        clean.length > 64) {
      return const BackupResult(
        success: false,
        message: '新建失败：文件夹名不能为空，且不能包含 / \\ 等符号（64 字符以内）',
      );
    }

    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await client.changeDirectory(parent);
      await client.createFolderIfNotExist(clean);
      await client.disconnect();
      return BackupResult(
        success: true,
        message: '已创建文件夹：$clean',
        fileName: clean,
      );
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      return BackupResult(
        success: false,
        message: '新建失败：${_readableError(e)}',
      );
    }
  }

  /// 在备份目录下新增文件夹
  Future<BackupResult> createFolder(FtpConfig config, String name) async {
    if (!config.isValid) {
      return const BackupResult(
        success: false,
        message: '新增失败：服务器信息不完整',
      );
    }
    final clean = name.trim();
    if (clean.isEmpty ||
        clean.contains('/') ||
        clean.contains('\\') ||
        clean == '.' ||
        clean == '..' ||
        clean.length > 64) {
      return const BackupResult(
        success: false,
        message: '新增失败：文件夹名不能为空，且不能包含 / \\ 等符号（64 字符以内）',
      );
    }

    // 自动协商加密模式（显式 TLS → 隐式 TLS → 明文），避免连不上
    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await _ensureDir(client, config.normalizedRemoteDir);
      await client.createFolderIfNotExist(clean);
      await client.disconnect();
      return BackupResult(success: true, message: '已创建文件夹：$clean');
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      return BackupResult(
        success: false,
        message: '新增失败：${_readableError(e)}',
      );
    }
  }

  /// 删除备份目录下的文件或空文件夹
  Future<BackupResult> deleteRemote(
    FtpConfig config,
    String name, {
    required bool isDir,
  }) async {
    if (!config.isValid) {
      return const BackupResult(
        success: false,
        message: '删除失败：服务器信息不完整',
      );
    }
    final clean = name.trim();
    if (clean.isEmpty ||
        clean.contains('/') ||
        clean.contains('\\') ||
        clean == '.' ||
        clean == '..') {
      return const BackupResult(
        success: false,
        message: '删除失败：非法文件名',
      );
    }

    // 自动协商加密模式（显式 TLS → 隐式 TLS → 明文），避免连不上
    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await _ensureDir(client, config.normalizedRemoteDir);
      final ok =
          isDir ? await client.deleteDirectory(clean) : await client.deleteFile(clean);
      await client.disconnect();
      if (!ok) {
        return BackupResult(
          success: false,
          message: isDir
              ? '删除失败：服务器拒绝了该操作（文件夹可能不为空，或无删除权限）'
              : '删除失败：服务器拒绝了该操作，请检查删除权限',
        );
      }
      return BackupResult(success: true, message: '已删除：$clean');
    } catch (e) {
      try {
        await client.disconnect();
      } catch (_) {}
      return BackupResult(
        success: false,
        message: '删除失败：${_readableError(e)}',
      );
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

    // 自动协商加密模式（显式 TLS → 隐式 TLS → 明文），避免连不上
    final conn = await _resolveConn(config);
    final client = _newClient(conn.config, conn.type);

    final dir = await _tempDir();
    final file = File('${dir.path}/$fileName');

    try {
      await client.connect().timeout(const Duration(seconds: 15));
      await _ensureDir(client, config.normalizedRemoteDir);

      progress?.call(0.5, '正在下载备份文件');
      await client.downloadFile(fileName, file);

      await client.disconnect();
      progress?.call(0.7, '正在解密数据（DT 专有加密）');

      final raw = await file.readAsBytes();
      final plain = DtCipher.decryptAny(raw, password);
      await _safeDelete(file);
      if (plain == null) {
        return const BackupResult(
          success: false,
          message: '恢复失败：备份密码错误，或文件已被篡改/损坏',
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

  /// 确保服务器上的目标目录存在，并把当前目录切进去
  ///
  /// 用户可自选任意层级目录（如 `/www/backup/bodhi`），
  /// 一次性 MKD 深层路径并非所有服务器都支持，因此逐级创建：
  /// 已存在的层级直接进入，缺失的层级才新建。
  Future<void> _ensureDir(FTPConnect client, String path) async {
    // 1) 目录已存在：直接进入即可
    try {
      await client.changeDirectory(path);
      return;
    } catch (_) {}

    // 2) 逐级创建（先按绝对路径尝试，失败再退回相对当前目录）
    final parts = path.split('/').where((e) => e.trim().isNotEmpty).toList();
    final buf = <String>[];

    for (final part in parts) {
      buf.add(part);
      final abs = '/${buf.join('/')}';

      final exists = await _tryEnter(client, abs);
      if (exists) continue;

      var created = await client.makeDirectory(abs);
      if (!created) created = await client.makeDirectory(part);
      if (!created) {
        throw StateError(
          '无法在服务器上创建目录「$abs」，请检查该账号是否有写入权限，'
          '或改选一个已存在的目录',
        );
      }
      if (!await _tryEnter(client, abs)) {
        if (!await _tryEnter(client, part)) {
          throw StateError('目录「$abs」创建后无法进入，请改选其他目录');
        }
      }
    }
  }

  Future<bool> _tryEnter(FTPConnect client, String dir) async {
    try {
      return await client.changeDirectory(dir);
    } catch (_) {
      return false;
    }
  }

  /// 清理超出保留数量的旧备份
  Future<void> _cleanupOldBackups(FTPConnect client, String justUploaded) async {
    try {
      final entries = await client.listDirectoryContent();
      final backups = entries
          .where((e) => e.name.endsWith('.dt') || e.name.endsWith('.btk'))
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

  /// 将底层异常转为用户可读提示（尽量给出可自查的具体原因）
  String _readableError(Object e) {
    final raw = e.toString();
    final text = raw.toLowerCase();

    if (text.contains('timeout') || text.contains('timed out')) {
      return '连接超时——服务器地址或端口可能不对，也可能被网络/防火墙拦截';
    }
    if (text.contains('530') || text.contains('login incorrect') || text.contains('auth')) {
      return '认证失败（530）——账号或密码不正确，'
          '请确认 FTP 账号（部分服务器要求用完整账号如 user@域名）';
    }
    if (text.contains('421')) {
      return '服务器拒绝服务（421）——连接数超限或当前 IP 被限制';
    }
    if (text.contains('550') || text.contains('553') || text.contains('denied')) {
      return '服务器拒绝了操作（550）——账号没有该目录的写入/删除权限';
    }
    if (text.contains('certificate') || text.contains('tls') || text.contains('ssl') || text.contains('handshake')) {
      return '加密握手失败——服务器不支持 FTPS 或证书异常，请关闭「使用 FTPS」后重试';
    }
    if (text.contains('refused') || text.contains('econnrefused')) {
      return '连接被拒绝——端口不对或服务器未开启 FTP 服务';
    }
    if (text.contains('failed host lookup') || text.contains('unknown host') || text.contains('nodename')) {
      return '域名解析失败——服务器地址填写有误，或手机网络无法解析该域名';
    }
    if (text.contains('network is unreachable') || text.contains('no route')) {
      return '网络不可达——请检查手机网络（部分网络屏蔽了 FTP 端口 21）';
    }
    if (text.contains('socket') || text.contains('connect')) {
      return '无法建立连接——请检查地址、端口与网络';
    }
    // 未覆盖的错误：把底层原文带出来，便于用户反馈与排查
    final brief = raw.length > 80 ? '${raw.substring(0, 80)}…' : raw;
    return '操作失败：$brief';
  }
}

/// 一次连接使用的「配置 + 加密模式」
class _FtpConn {
  final FtpConfig config;
  final SecurityType type;

  const _FtpConn(this.config, this.type);
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

/// FTP 备份目录下的条目（文件管理用）
class FtpEntryInfo {
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modifyTime;

  const FtpEntryInfo({
    required this.name,
    required this.isDir,
    required this.size,
    this.modifyTime,
  });
}

/// 服务器目录浏览结果（选择备份目录用）
class FtpDirListing {
  final bool success;

  /// 服务器解析后的真实路径
  final String path;

  /// 该路径下的子目录名（已排序、已过滤 . 与 ..）
  final List<String> dirs;

  final String? error;

  const FtpDirListing({
    required this.success,
    required this.path,
    required this.dirs,
    this.error,
  });
}
