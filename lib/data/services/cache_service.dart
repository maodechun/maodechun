/// 一键清除所有缓存。
///
/// 覆盖范围（不影响令牌数据与用户设置）：
///   1. WebView 网页缓存（资源缓存 / 内存缓存）
///   2. WebView LocalStorage / IndexedDB 等 DOM 存储
///   3. WebView Cookie
///   4. 应用临时目录（下载的更新包、图片缓存等）
///   5. Flutter 图片内存缓存
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/plugin_registrant.dart';

class CacheService {
  CacheService._();
  static final CacheService instance = CacheService._();

  /// 清除结果
  /// [freedBytes] 释放的临时目录字节数；[errors] 各步骤的失败说明。
  Future<CacheClearResult> clearAll() async {
    final errors = <String>[];
    var freed = 0;

    // ── 1. 临时目录（先统计再删除）──────────────────
    try {
      final dir = await getTemporaryDirectory();
      freed = await _dirSize(dir);
      await _emptyDir(dir);
    } catch (e) {
      errors.add('临时文件: $e');
    }

    // ── 2~4. WebView 缓存 / DOM 存储 / Cookie ────────
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        if (ensureWebViewPlatform()) {
          final controller = WebViewController();
          await controller.clearCache();
          await controller.clearLocalStorage();
          final cookies = WebViewCookieManager();
          await cookies.clearCookies();
        }
      } catch (e) {
        errors.add('网页缓存: $e');
      }
    }

    // ── 5. Flutter 图片内存缓存 ──────────────────────
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (e) {
      errors.add('图片缓存: $e');
    }

    return CacheClearResult(
      freedBytes: freed,
      ok: errors.isEmpty,
      errors: errors,
    );
  }

  Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 清空目录内容（保留目录本身），逐项容错
  Future<void> _emptyDir(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // 单个文件被占用等，跳过继续
        }
      }
    } catch (_) {}
  }
}

class CacheClearResult {
  final int freedBytes;
  final bool ok;
  final List<String> errors;

  const CacheClearResult({
    required this.freedBytes,
    required this.ok,
    this.errors = const [],
  });

  String get humanSize {
    if (freedBytes >= 1048576) {
      return '${(freedBytes / 1048576).toStringAsFixed(1)} MB';
    }
    if (freedBytes >= 1024) return '${(freedBytes / 1024).toStringAsFixed(0)} KB';
    return '$freedBytes B';
  }

  String get message {
    if (ok) return '缓存已清除（释放 $humanSize）';
    return '缓存已部分清除（释放 $humanSize）：${errors.join('；')}';
  }
}
