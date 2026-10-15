import 'dart:async';

import 'package:ntp/ntp.dart';

/// NTP 时钟校准服务
///
/// 为什么需要：TOTP 依赖准确时间，若用户设备时钟偏差超过 30 秒，
/// 生成的验证码将全部无效。此服务在启动时校正一次，并缓存 12 小时。
class NtpClient {
  NtpClient._internal();
  static final NtpClient instance = NtpClient._internal();

  /// 与标准时间的偏移量（毫秒）。正数表示本地时间偏慢，需加上该值。
  int _offsetMs = 0;

  /// 上次校准时间
  DateTime? _lastSyncAt;

  /// 校准是否成功过
  bool _everSynced = false;

  /// 是否正在校准中（防止并发重复请求）
  bool _syncing = false;

  static const Duration _cacheValid = Duration(hours: 12);

  /// 最近一次校准的偏移量（毫秒）
  int get offsetMs => _offsetMs;

  /// 是否已成功校准
  bool get isSynced => _everSynced;

  /// 缓存是否仍有效
  bool get _cacheAlive {
    final at = _lastSyncAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < _cacheValid;
  }

  /// 当前精确时间 = 本地时间 + 偏移量
  DateTime get now => DateTime.now().add(Duration(milliseconds: _offsetMs));

  /// 执行校准
  ///
  /// [timeout] 单次请求超时，默认 5 秒
  /// 返回是否校准成功。失败不抛异常，静默降级为本地时间。
  Future<bool> sync({Duration timeout = const Duration(seconds: 5)}) async {
    if (_syncing) return _everSynced;
    if (_cacheAlive) return true;

    _syncing = true;
    try {
      final offset = await NTP.getNtpOffset(
        lookUpAddress: 'pool.ntp.org',
        timeout: timeout,
        localTime: DateTime.now(),
      );
      _offsetMs = offset;
      _lastSyncAt = DateTime.now();
      _everSynced = true;
      return true;
    } catch (_) {
      // 网络不可用或 NTP 服务器无响应：降级使用本地时间
      _lastSyncAt = DateTime.now();
      return false;
    } finally {
      _syncing = false;
    }
  }

  /// 启动时调用：后台静默校准，不阻塞 UI
  void syncInBackground() {
    unawaited(sync());
  }

  /// 手动校准（设置页「时间校准」入口）
  Future<NtpSyncResult> manualSync() async {
    final ok = await sync();
    if (!ok) {
      return const NtpSyncResult(
        success: false,
        message: '校准失败，当前网络可能无法访问时间服务器，已沿用本机时间',
        offsetMs: 0,
      );
    }

    final absOffset = _offsetMs.abs();
    final String message;
    if (absOffset < 1000) {
      message = '时间准确，无需调整';
    } else {
      final direction = _offsetMs > 0 ? '慢' : '快';
      message = '校准成功：本机时间比标准时间$direction ${(absOffset / 1000).toStringAsFixed(1)} 秒，已自动修正';
    }

    return NtpSyncResult(
      success: true,
      message: message,
      offsetMs: _offsetMs,
    );
  }

  /// 手动设置偏移（用户完全离线时的手动微调）
  void setManualOffset(int milliseconds) {
    _offsetMs = milliseconds;
    _lastSyncAt = DateTime.now();
    _everSynced = true;
  }

  /// 重置为本地时间
  void reset() {
    _offsetMs = 0;
    _lastSyncAt = null;
    _everSynced = false;
  }
}

/// 校准结果
class NtpSyncResult {
  final bool success;
  final String message;
  final int offsetMs;

  const NtpSyncResult({
    required this.success,
    required this.message,
    required this.offsetMs,
  });
}
