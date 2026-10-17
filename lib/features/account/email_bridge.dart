import 'package:flutter/services.dart';

/// 原生邮件桥（原生 EmailEngine.kt，通道 bodhi/email）
///
/// SMTP 服务器地址 / 账号 / 密码全部内置于原生层（混淆存储），
/// Dart 侧只传入收件人、主题与正文，拿不到任何凭据。
class EmailBridge {
  EmailBridge._internal();
  static final EmailBridge instance = EmailBridge._internal();

  static const MethodChannel _channel = MethodChannel('bodhi/email');

  /// 发送一封纯文本邮件
  ///
  /// 成功返回 true；失败抛出 [EmailException]（含可读原因）。
  Future<bool> send({
    required String to,
    required String subject,
    required String body,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('send', {
        'to': to.trim(),
        'subject': subject,
        'body': body,
      });
      final ok = (result?['ok'] as bool?) ?? false;
      if (!ok) {
        throw EmailException(
          (result?['message'] as String?) ?? '发送失败，请稍后重试',
        );
      }
      return true;
    } on PlatformException catch (e) {
      throw EmailException(
        (e.message?.isNotEmpty ?? false) ? e.message! : '发送失败，请稍后重试',
      );
    } on MissingPluginException {
      throw const EmailException('当前平台不支持邮件发送');
    }
  }

  /// 发送注册验证码邮件
  Future<bool> sendVerificationCode({
    required String to,
    required String code,
  }) {
    return send(
      to: to,
      subject: '【菩提护令】注册验证码',
      body: '您好！\n\n'
          '您正在注册菩提护令账号，本次验证码为：\n\n'
          '    $code\n\n'
          '验证码 10 分钟内有效，请勿泄露给他人。\n'
          '若非本人操作，请忽略本邮件。\n\n'
          '—— 菩提护令',
    );
  }
}

class EmailException implements Exception {
  final String message;
  const EmailException(this.message);
  @override
  String toString() => message;
}
