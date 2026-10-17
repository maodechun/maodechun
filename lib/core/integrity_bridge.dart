import 'package:flutter/services.dart';

/// 数据完整性桥（原生 IntegrityEngine.kt，通道 bodhi/integrity）
///
/// 用途：在线更新清单 HMAC-SHA256 服务端签名校验。
/// 签名密钥内置于原生层（混淆存储），Dart 侧只传入待签名数据。
class IntegrityBridge {
  IntegrityBridge._internal();
  static final IntegrityBridge instance = IntegrityBridge._internal();

  static const MethodChannel _channel = MethodChannel('bodhi/integrity');

  /// 计算 HMAC-SHA256（hex 小写）；失败返回 null
  Future<String?> hmacSha256(String data) async {
    try {
      final hex = await _channel.invokeMethod<String>('hmacSha256', {
        'data': data,
      });
      return (hex == null || hex.isEmpty) ? null : hex;
    } catch (_) {
      return null;
    }
  }
}
