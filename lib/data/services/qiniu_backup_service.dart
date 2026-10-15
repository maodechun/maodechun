import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/security/secret_store.dart';
import '../repository/token_repository.dart';

/// 七牛云对象存储密钥备份服务
///
/// 「手机号即身份」的免密云备份：
///   - 首次备份输入 11 位手机号，之后自动静默备份，无需任何密码/验证码
///   - 备份文件以手机号派生密钥加密（PBKDF2 + AES，与本地/FTP 备份同格式），
///     云端不存明文密钥
///   - 存储路径：bodhi/cloud/<手机号>.btk，同手机号覆盖上传（保留最新一份）
///   - 换手机：输入同一手机号即可从云端恢复
///
/// 上传凭证由服务端代签（https://www.852233.com.cn/qiniu/sign.php），
/// 客户端不保存任何 AK/SK；拿到凭证后表单直传七牛，
/// 依次尝试各区域上传域名直到成功。
class QiniuBackupService {
  QiniuBackupService._internal();
  static final QiniuBackupService instance = QiniuBackupService._internal();

  static const String _downloadDomain = 'apk.0499.com.cn';

  /// 各区域上传域名（实测 shakya 空间位于华南 z2，放首位）
  static const List<String> _uploadHosts = [
    'up-z2.qiniup.com',
    'upload.qiniup.com',
    'up-z0.qiniup.com',
    'up-z1.qiniup.com',
    'up-na0.qiniup.com',
    'up-as0.qiniup.com',
  ];

  static const String _phonePrefKey = 'cloud_backup_phone';

  /// 恢复失败时的管理员协助提示
  static const String adminHint = '，如仍无法恢复请联系管理员协助找回';

  String? _phone;

  /// 已绑定的手机号（未设置过为 null）
  Future<String?> getPhone() async {
    if (_phone != null) return _phone;
    try {
      final prefs = await SharedPreferences.getInstance();
      _phone = prefs.getString(_phonePrefKey);
    } catch (_) {}
    return _phone;
  }

  /// 中国大陆手机号格式校验
  static bool isValidPhone(String s) => RegExp(r'^1[3-9]\d{9}$').hasMatch(s);

  /// 保存手机号（本地记录，下次自动使用）
  Future<void> _savePhone(String phone) async {
    _phone = phone;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_phonePrefKey, phone);
    } catch (_) {}
  }

  /// 备份 key
  static String _objectKey(String phone) => 'bodhi/cloud/$phone.btk';

  /// 代签服务器（SK 只保存在服务端，客户端不含任何密钥）
  static const String _signUrl = 'https://www.852233.com.cn/qiniu/sign.php';
  static const String _appSecret = 'bodhi-cloud-v1';

  /// 向代签服务器取上传凭证；服务器不可达/异常时返回 null
  static Future<String?> _resolveUploadToken(String phone, String key) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final req = await client.postUrl(Uri.parse(_signUrl));
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      final body = 'phone=$phone&secret=$_appSecret';
      req.headers.contentLength = utf8.encode(body).length;
      req.add(utf8.encode(body));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      client.close();
      if (resp.statusCode == 200) {
        final data = jsonDecode(text);
        if (data is Map &&
            data['code'] == 0 &&
            data['key'] == key &&
            data['uploadToken'] is String &&
            (data['uploadToken'] as String).isNotEmpty) {
          return data['uploadToken'] as String;
        }
      }
    } catch (_) {
      // 服务器不可达
    }
    return null;
  }

  /// 备份到云端
  ///
  /// [phone] 11 位手机号。文件以手机号加密后覆盖上传。
  Future<QiniuBackupResult> backup(String phone) async {
    if (!isValidPhone(phone)) {
      return const QiniuBackupResult(
        success: false,
        message: '备份失败：请输入正确的 11 位手机号',
      );
    }
    final repo = TokenRepository.instance;
    if (repo.isEmpty) {
      return const QiniuBackupResult(
        success: false,
        message: '备份失败：当前没有任何令牌',
      );
    }

    String payload;
    try {
      payload = repo.buildBackupPayload(deviceTag: 'cloud');
    } catch (e) {
      return QiniuBackupResult(
        success: false,
        message: '备份失败：无法读取令牌数据（$e）',
      );
    }
    if (payload.isEmpty) {
      return const QiniuBackupResult(
        success: false,
        message: '备份失败：无法读取令牌数据',
      );
    }

    // 以手机号派生密钥加密（与本地备份同一加密体系）
    final encrypted = SecretStore.encryptWithPassword(payload, phone);
    final key = _objectKey(phone);
    // 向代签服务器取上传凭证（客户端不含任何密钥）
    final token = await _resolveUploadToken(phone, key);
    if (token == null) {
      return const QiniuBackupResult(
        success: false,
        message: '备份失败：备份服务暂时不可用，请检查网络后重试',
      );
    }

    try {
      await _upload(key, token, utf8.encode(encrypted));
    } catch (e) {
      return QiniuBackupResult(success: false, message: '备份失败：网络错误（$e）');
    }

    await _savePhone(phone);
    return QiniuBackupResult(
      success: true,
      message: '云端备份成功（$phone）',
      phone: phone,
    );
  }

  /// 静默自动备份：已绑定手机号且令牌非空时后台执行，不弹任何提示
  Future<void> autoBackup() async {
    try {
      final phone = await getPhone();
      if (phone == null) return;
      if (TokenRepository.instance.isEmpty) return;
      await backup(phone);
    } catch (_) {
      // 自动备份失败不打扰用户
    }
  }

  /// 从云端恢复（按手机号下载最新备份并导入）
  ///
  /// [merge] true 时与现有令牌合并（重复跳过）
  Future<QiniuBackupResult> restore(String phone, {bool merge = true}) async {
    if (!isValidPhone(phone)) {
      return const QiniuBackupResult(
        success: false,
        message: '恢复失败：请输入正确的 11 位手机号',
      );
    }

    final uri = Uri.https(_downloadDomain, _objectKey(phone));
    HttpClient client;
    String encrypted;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
      final req = await client.getUrl(uri);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        client.close();
        return QiniuBackupResult(
          success: false,
          message: resp.statusCode == 404
              ? '恢复失败：该手机号在云端没有备份$adminHint'
              : '恢复失败：云端返回 ${resp.statusCode}$adminHint',
        );
      }
      encrypted = await resp.transform(utf8.decoder).join();
      client.close();
    } catch (e) {
      return QiniuBackupResult(success: false, message: '恢复失败：网络错误（$e）');
    }

    if (encrypted.isEmpty) {
      return const QiniuBackupResult(
        success: false,
        message: '恢复失败：备份文件为空，如仍无法恢复请联系管理员协助找回',
      );
    }

    final plain = SecretStore.decryptWithPassword(encrypted, phone);
    if (plain == null) {
      return QiniuBackupResult(
        success: false,
        message: '恢复失败：云端数据校验不符或已损坏$adminHint',
      );
    }

    try {
      final result =
          await TokenRepository.instance.restoreFromJson(plain, merge: merge);
      if (!result.success) {
        return QiniuBackupResult(
          success: false,
          message: '恢复失败：${result.error ?? "未知错误"}',
        );
      }
      await _savePhone(phone);
      final msg = result.skipped > 0
          ? '恢复成功：新增 ${result.added} 条，跳过重复 ${result.skipped} 条'
          : '恢复成功：新增 ${result.added} 条';
      return QiniuBackupResult(success: true, message: msg, phone: phone);
    } catch (e) {
      return QiniuBackupResult(success: false, message: '恢复失败：$e');
    }
  }

  /// 表单直传（依次尝试各区域域名）
  static Future<void> _upload(String key, String token, List<int> bytes) async {
    Object? lastError;
    for (final host in _uploadHosts) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        final req = await client.postUrl(Uri.https(host, '/'));
        final boundary =
            'bodhi${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
        req.headers.set(HttpHeaders.contentTypeHeader,
            'multipart/form-data; boundary=$boundary');
        req.headers.set(HttpHeaders.contentLengthHeader, '0');

        final sb = StringBuffer();
        void field(String name, String value) {
          sb
            ..write('--$boundary\r\n')
            ..write('Content-Disposition: form-data; name="$name"\r\n\r\n')
            ..write('$value\r\n');
        }

        field('key', key);
        field('token', token);
        final head = utf8.encode(sb.toString());
        final fileHead = utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="b"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n',
        );
        final tail = utf8.encode('\r\n--$boundary--\r\n');
        final body = [...head, ...fileHead, ...bytes, ...tail];
        req.headers.set(HttpHeaders.contentLengthHeader, body.length);
        req.add(body);
        final resp = await req.close();
        final text = await resp.transform(utf8.decoder).join();
        client.close();
        if (resp.statusCode == 200) return;
        // 401 是凭证/账号问题，换域名也没用，直接抛出
        throw Exception('云端返回 ${resp.statusCode}: ${text.substring(0, text.length > 80 ? 80 : text.length)}');
      } catch (e) {
        lastError = e;
        continue;
      }
    }
    throw lastError ?? Exception('所有上传节点均不可达');
  }
}

/// 七牛云备份 / 恢复结果
class QiniuBackupResult {
  final bool success;
  final String message;
  final String? phone;

  const QiniuBackupResult({
    required this.success,
    required this.message,
    this.phone,
  });
}
