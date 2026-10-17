import 'package:flutter/services.dart';

/// 超级管理员本地校验桥（原生 AdminAuth.kt，通道 bodhi/admin_auth）
///
/// 安全区：
///   - 明文密码只经过本函数参数，不落盘、不存偏好；
///   - APK 内只有 PBKDF2 哈希，反编译拿不到明文；
///   - 登录成功后签发会话令牌（原生内存），后台接口调用时使用。
class AdminBridge {
  AdminBridge._internal();
  static final AdminBridge instance = AdminBridge._internal();

  static const MethodChannel _channel = MethodChannel('bodhi/admin_auth');

  String? _sessionToken;

  String? get sessionToken => _sessionToken;

  /// 本地校验管理员账号密码
  ///
  /// 成功返回会话令牌；失败抛出 [AdminAuthException]（含可读原因）。
  Future<String> verify(String username, String password) async {
    try {
      final result = await _channel
          .invokeMethod<Map>('verify', {
        'username': username.trim(),
        'password': password,
      });
      final token = (result?['token'] as String?) ?? '';
      if (token.isEmpty) {
        throw const AdminAuthException('校验通过但未取得会话令牌');
      }
      _sessionToken = token;
      return token;
    } on PlatformException catch (e) {
      throw AdminAuthException(
        (e.message?.isNotEmpty ?? false) ? e.message! : '管理员账号或密码不正确',
      );
    } on MissingPluginException {
      throw const AdminAuthException('当前平台不支持管理员校验');
    }
  }

  /// 退出管理员会话
  Future<void> logout() async {
    _sessionToken = null;
    try {
      await _channel.invokeMethod<void>('logout');
    } catch (_) {}
  }
}

class AdminAuthException implements Exception {
  final String message;
  const AdminAuthException(this.message);
  @override
  String toString() => message;
}
