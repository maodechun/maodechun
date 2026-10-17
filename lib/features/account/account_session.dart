import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 用户登录会话（本地持久化，安全存储）
///
/// 只保存 token / 手机号 / 昵称，绝不保存密码。
/// token 存 flutter_secure_storage（Android Keystore 加密落盘）。
class AccountSession {
  AccountSession._internal();
  static final AccountSession instance = AccountSession._internal();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kToken = 'account_token';
  static const _kPhone = 'account_phone';
  static const _kNickname = 'account_nickname';
  static const _kCreatedAt = 'account_created_at';

  String token = '';
  String phone = '';
  String nickname = '';
  String createdAt = '';

  bool get loggedIn => token.isNotEmpty;

  /// 启动时加载会话（无会话则保持未登录）
  Future<void> load() async {
    try {
      token = await _storage.read(key: _kToken) ?? '';
      phone = await _storage.read(key: _kPhone) ?? '';
      nickname = await _storage.read(key: _kNickname) ?? '';
      createdAt = await _storage.read(key: _kCreatedAt) ?? '';
    } catch (_) {
      // 安全存储不可用时保持未登录，不阻断启动
    }
  }

  Future<void> save({
    required String token,
    required String phone,
    required String nickname,
    required String createdAt,
  }) async {
    this.token = token;
    this.phone = phone;
    this.nickname = nickname;
    this.createdAt = createdAt;
    try {
      await _storage.write(key: _kToken, value: token);
      await _storage.write(key: _kPhone, value: phone);
      await _storage.write(key: _kNickname, value: nickname);
      await _storage.write(key: _kCreatedAt, value: createdAt);
    } catch (_) {}
  }

  Future<void> clear() async {
    token = '';
    phone = '';
    nickname = '';
    createdAt = '';
    try {
      await _storage.delete(key: _kToken);
      await _storage.delete(key: _kPhone);
      await _storage.delete(key: _kNickname);
      await _storage.delete(key: _kCreatedAt);
    } catch (_) {}
  }
}
