import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 剪贴板守卫
///
/// 安全要求：密钥类敏感内容复制后 30 秒自动清空剪贴板，
/// 并在系统支持时将其标记为敏感内容（Android 13+ 不显示预览）。
class ClipboardGuard {
  ClipboardGuard._();

  static Timer? _clearTimer;
  static String? _lastCopiedSensitive;

  /// 复制敏感内容（密钥、验证码）
  ///
  /// [autoClearSeconds] 自动清空延时，默认 30 秒
  static Future<void> copySensitive(
    String text, {
    int autoClearSeconds = 30,
  }) async {
    await Clipboard.setData(ClipboardData(text: text));
    _lastCopiedSensitive = text;

    // Android 13+ 标记为敏感，避免出现在剪贴板预览中
    if (Platform.isAndroid) {
      await _markSensitiveAndroid();
    }

    // 重置定时器
    _clearTimer?.cancel();
    _clearTimer = Timer(Duration(seconds: autoClearSeconds), () async {
      // 仅当剪贴板内容仍是我们写入的内容时才清空，
      // 避免误删用户后来复制的内容
      try {
        final current = await Clipboard.getData(Clipboard.kTextPlain);
        if (current?.text == _lastCopiedSensitive) {
          await Clipboard.setData(const ClipboardData(text: ''));
          _lastCopiedSensitive = null;
        }
      } catch (_) {
        // 读剪贴板在部分系统受限，忽略
      }
    });
  }

  /// 复制普通内容（不自动清空）
  static Future<void> copyNormal(String text) async {
    _clearTimer?.cancel();
    _lastCopiedSensitive = null;
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 立即清空（页面 dispose 时调用）
  static Future<void> clearNow() async {
    _clearTimer?.cancel();
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (_lastCopiedSensitive != null && current?.text == _lastCopiedSensitive) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {}
    _lastCopiedSensitive = null;
  }

  /// Android 13+ 敏感标记
  ///
  /// 通过平台通道交由原生实现设置 `ClipDescription.EXTRA_IS_SENSITIVE`，
  /// 未实现时静默忽略（不影响主流程）。
  static Future<void> _markSensitiveAndroid() async {
    try {
      const channel = MethodChannel('com.daotuo.bodhitoken/clipboard');
      await channel.invokeMethod('markSensitive');
    } catch (_) {
      // 原生未实现，忽略
    }
  }
}
