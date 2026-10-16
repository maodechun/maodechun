import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show md5;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 版本信息
class UpdateInfo {
  final String versionName;
  final int versionCode;
  final bool forceUpdate;
  final int minSupportVersion;
  final String downloadUrl;
  final String releaseNotes;
  final String md5;
  final String publishedAt;

  /// 老旧 32 位机型（纯 armv7）专用安装包地址，可为空
  final String downloadUrlArmv7;

  /// 32 位包 MD5，可为空
  final String md5Armv7;

  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    this.forceUpdate = false,
    this.minSupportVersion = 0,
    this.downloadUrl = '',
    this.releaseNotes = '',
    this.md5 = '',
    this.publishedAt = '',
    this.downloadUrlArmv7 = '',
    this.md5Armv7 = '',
  });

  factory UpdateInfo.fromJson(Map<String, Object?> json) {
    return UpdateInfo(
      versionName: (json['versionName'] as String?) ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      forceUpdate: (json['forceUpdate'] as bool?) ?? false,
      minSupportVersion: (json['minSupportVersion'] as num?)?.toInt() ?? 0,
      downloadUrl: (json['downloadUrl'] as String?) ?? '',
      releaseNotes: (json['releaseNotes'] as String?) ?? '',
      md5: (json['md5'] as String?) ?? '',
      publishedAt: (json['publishedAt'] as String?) ?? '',
      downloadUrlArmv7: (json['downloadUrlArmv7'] as String?) ?? '',
      md5Armv7: (json['md5Armv7'] as String?) ?? '',
    );
  }

  /// 更新说明按行拆分
  List<String> get notesList => releaseNotes
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// 在线更新服务
///
/// 更新服务器：https://apk.0499.com.cn
/// 安全要求：
///   - 仅允许 https 下载
///   - 下载完成后校验 MD5，校验失败拒绝安装
///   - 强制更新条件：forceUpdate == true 或 本机版本 < minSupportVersion
class UpdateService {
  UpdateService._internal();
  static final UpdateService instance = UpdateService._internal();

  static const String baseUrl = 'https://apk.0499.com.cn';

  /// 主版本接口（服务端动态接口）
  static const String versionEndpoint = '$baseUrl/api/version';

  /// 备用版本接口（七牛静态清单文件，主接口 404 时自动兜底）
  ///
  /// 该文件作为静态对象存放在 apk.0499.com.cn 对应的存储空间内，
  /// 即使服务器没有部署后端，在线更新也能正常工作。
  static const String versionEndpointBackup =
      '$baseUrl/bodhi/version/android.json';

  /// 官网（内置浏览器打开）
  static const String websiteUrl = 'https://m.0499.com.cn';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {'Accept': 'application/json'},
  ));

  /// 本机版本缓存
  PackageInfo? _pkg;

  Future<PackageInfo> _packageInfo() async {
    return _pkg ??= await PackageInfo.fromPlatform();
  }

  /// 本机版本号（用于「关于」展示）
  Future<String> currentVersionLabel() async {
    final pkg = await _packageInfo();
    return 'v${pkg.version}';
  }

  /// 抓取版本清单
  ///
  /// 依次尝试「主接口 → 静态兜底文件」。
  /// 用 [ResponseType.plain] + 手动 jsonDecode，
  /// 避免静态文件未声明 Content-Type 时被当成字符串而解析失败
  /// （这是之前在线更新一直失效的原因之一）。
  Future<Map<String, Object?>?> _fetchManifest(int currentCode) async {
    final query = {
      'platform': Platform.isIOS ? 'ios' : 'android',
      'channel': 'official',
      'current': currentCode,
    };
    for (final url in [versionEndpoint, versionEndpointBackup]) {
      try {
        final resp = await _dio.get<String>(
          url,
          queryParameters: query,
          options: Options(responseType: ResponseType.plain),
        );
        final body = resp.data;
        if (body == null || body.trim().isEmpty) continue;
        final decoded = jsonDecode(body);
        if (decoded is Map) return decoded.cast<String, Object?>();
      } catch (_) {
        // 该地址不可用，继续尝试下一个
        continue;
      }
    }
    return null;
  }

  /// 判断本机是否只支持 32 位（老旧机型需要 armv7 安装包）
  Future<bool> _isPureArm32() async {
    if (!Platform.isAndroid) return false;
    try {
      final android = await DeviceInfoPlugin().androidInfo;
      final abis = android.supportedAbis
          .map((e) => e.toLowerCase())
          .toList();
      if (abis.isEmpty) return false;
      final has64 = abis.any(
        (e) => e.contains('arm64') || e.contains('aarch64') ||
               e.contains('x86_64') || e.contains('64'),
      );
      return !has64;
    } catch (_) {
      return false;
    }
  }

  /// 逐段比较版本号，[remote] 比 [local] 新时返回 true
  ///
  /// 必须用版本名而不是 versionCode 判断：
  /// `--split-per-abi` 会按 ABI 给 versionCode 加偏移
  /// （arm64 = 基准+2000，armv7 = 基准+1000），
  /// 同一版本的两种包 versionCode 并不相同，直接用版本号比较最可靠。
  static bool isNewerVersion(String remote, String local) {
    List<int> parse(String s) {
      final cleaned = s.trim().replaceAll(RegExp(r'^[vV]'), '');
      return cleaned
          .split(RegExp(r'[.\-+_]'))
          .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
          .toList();
    }

    if (remote.trim().isEmpty) return false;
    final a = parse(remote);
    final b = parse(local);
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// 检查更新
  ///
  /// [silent] 静默检查（启动时）：任何异常都返回 null，不打扰用户
  /// 返回 null 表示无更新或检查失败
  Future<UpdateInfo?> check({bool silent = true}) async {
    try {
      final pkg = await _packageInfo();
      final currentCode = int.tryParse(pkg.buildNumber) ?? 0;
      final currentName = pkg.version;

      final data = await _fetchManifest(currentCode);
      if (data == null) return null;

      final info = UpdateInfo.fromJson(data);

      // 判定是否需要更新：优先按版本名比较（不受 ABI 偏移影响）
      final newerByName = isNewerVersion(info.versionName, currentName);
      final newerByCode = info.versionCode > currentCode;
      if (!newerByName && !newerByCode) return null;

      // 计算是否强制（此判断仍按 versionCode 基准值）
      final forced = info.forceUpdate ||
          (info.minSupportVersion > 0 && currentCode < info.minSupportVersion);

      // 按本机 ABI 选择安装包
      var url = info.downloadUrl;
      var md5sum = info.md5;
      if (await _isPureArm32() && info.downloadUrlArmv7.isNotEmpty) {
        url = info.downloadUrlArmv7;
        if (info.md5Armv7.isNotEmpty) md5sum = info.md5Armv7;
      }

      return UpdateInfo(
        versionName: info.versionName,
        versionCode: info.versionCode,
        forceUpdate: forced,
        minSupportVersion: info.minSupportVersion,
        downloadUrl: url,
        releaseNotes: info.releaseNotes,
        md5: md5sum,
        publishedAt: info.publishedAt,
        downloadUrlArmv7: info.downloadUrlArmv7,
        md5Armv7: info.md5Armv7,
      );
    } catch (_) {
      // 网络不可用 / 服务器异常：静默返回，不打断用户
      return null;
    }
  }

  /// 启动后延迟静默检查（不阻塞进入应用）
  Future<UpdateInfo?> checkInBackground({
    Duration delay = const Duration(seconds: 3),
  }) async {
    await Future<void>.delayed(delay);
    return check(silent: true);
  }

  // ── 下载 ─────────────────────────────────────────────

  /// 下载更新包
  ///
  /// iOS 不提供应用内下载（返回 null，由 UI 引导前往 App Store）
  /// [progress] 进度回调 0.0 ~ 1.0
  Future<File?> download(
    UpdateInfo info, {
    void Function(double progress)? progress,
    CancelToken? cancelToken,
  }) async {
    // iOS 不允许应用内自更新
    if (Platform.isIOS) return null;

    if (info.downloadUrl.isEmpty) return null;
    // 强制 https，拒绝明文下载
    if (!info.downloadUrl.startsWith('https://')) return null;

    final dir = await getTemporaryDirectory();
    final fileName = 'bodhi_update_${info.versionCode}.apk';
    final savePath = '${dir.path}/$fileName';

    // 已存在且校验通过则复用
    final existing = File(savePath);
    if (await existing.exists() && info.md5.isNotEmpty) {
      final ok = await verifyMd5(existing, info.md5);
      if (ok) return existing;
      await existing.delete();
    }

    try {
      await _dio.download(
        info.downloadUrl,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            progress?.call(received / total);
          }
        },
      );

      final file = File(savePath);
      if (!await file.exists()) return null;

      // MD5 校验：不通过则删除并返回 null（绝不安装未校验的包）
      if (info.md5.isNotEmpty) {
        final ok = await verifyMd5(file, info.md5);
        if (!ok) {
          await file.delete();
          return null;
        }
      }

      return file;
    } catch (_) {
      return null;
    }
  }

  /// 校验文件 MD5
  Future<bool> verifyMd5(File file, String expected) async {
    try {
      final bytes = await file.readAsBytes();
      final digest = md5.convert(bytes).toString();
      return digest.toLowerCase() ==
          expected.toLowerCase().replaceAll(' ', '');
    } catch (_) {
      return false;
    }
  }

  /// 清理已下载的更新包
  Future<void> clearDownloaded() async {
    try {
      final dir = await getTemporaryDirectory();
      final files = dir.listSync();
      for (final f in files) {
        if (f is File && f.path.contains('bodhi_update_')) {
          await f.delete();
        }
      }
    } catch (_) {}
  }
}
