import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' show md5;
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

  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    this.forceUpdate = false,
    this.minSupportVersion = 0,
    this.downloadUrl = '',
    this.releaseNotes = '',
    this.md5 = '',
    this.publishedAt = '',
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
/// 更新服务器：https://app.0499.com.cn
/// 安全要求：
///   - 仅允许 https 下载
///   - 下载完成后校验 MD5，校验失败拒绝安装
///   - 强制更新条件：forceUpdate == true 或 本机版本 < minSupportVersion
class UpdateService {
  UpdateService._internal();
  static final UpdateService instance = UpdateService._internal();

  static const String baseUrl = 'https://app.0499.com.cn';
  static const String versionEndpoint = '$baseUrl/api/version';

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

  /// 检查更新
  ///
  /// [silent] 静默检查（启动时）：任何异常都返回 null，不打扰用户
  /// 返回 null 表示无更新或检查失败
  Future<UpdateInfo?> check({bool silent = true}) async {
    try {
      final pkg = await _packageInfo();
      final currentCode = int.tryParse(pkg.buildNumber) ?? 0;

      final response = await _dio.get<Map<String, Object?>>(
        versionEndpoint,
        queryParameters: {
          'platform': Platform.isIOS ? 'ios' : 'android',
          'channel': 'official',
          'current': currentCode,
        },
      );

      final data = response.data;
      if (data == null) return null;

      final info = UpdateInfo.fromJson(data);

      // 判定是否需要更新
      if (info.versionCode <= currentCode) return null;

      // 计算是否强制
      final forced = info.forceUpdate ||
          (info.minSupportVersion > 0 && currentCode < info.minSupportVersion);

      return UpdateInfo(
        versionName: info.versionName,
        versionCode: info.versionCode,
        forceUpdate: forced,
        minSupportVersion: info.minSupportVersion,
        downloadUrl: info.downloadUrl,
        releaseNotes: info.releaseNotes,
        md5: info.md5,
        publishedAt: info.publishedAt,
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
