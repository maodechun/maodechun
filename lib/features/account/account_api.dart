import 'dart:convert';

import 'package:dio/dio.dart';

/// 用户账号服务端 API 客户端
///
/// 服务端：https://www.852233.com.cn/user/api.php（PHP + MySQL）
/// 数据库表 bodhi_users 见 服务端/user/schema.sql
///
/// 安全约定：
///   - 全程 HTTPS 传输；
///   - 密码不在客户端存储，服务端用 password_hash(BCRYPT) 落库；
///   - 登录成功后服务端签发 token（sha256(密钥+uid+时间窗)），
///     后续请求头携带 Authorization: Bearer <token>。
class AccountApi {
  AccountApi._internal();
  static final AccountApi instance = AccountApi._internal();

  /// 服务端接口地址（部署时如有变动，改这一处即可）
  static const String apiBase =
      'https://www.852233.com.cn/user/api.php';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {'Accept': 'application/json'},
  ));

  /// 统一响应结构
  /// { ok: true/false, data: {...}, message: '...' }
  Future<Map<String, Object?>> _post(
    String action,
    Map<String, Object?> fields, {
    String? token,
  }) async {
    final resp = await _dio.post<String>(
      apiBase,
      data: FormData.fromMap({
        'action': action,
        ...fields,
      }),
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          if (token != null) 'Authorization': 'Bearer $token',
        },
      ),
    );
    final body = resp.data ?? '';
    if (body.length > 256 * 1024) {
      throw ApiException('响应数据异常，请稍后重试');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw ApiException('服务端返回格式异常');
    final map = decoded.cast<String, Object?>();
    final ok = (map['ok'] as bool?) ?? false;
    if (!ok) {
      throw ApiException((map['message'] as String?) ?? '操作失败，请稍后重试');
    }
    return (map['data'] as Map?)?.cast<String, Object?>() ?? {};
  }

  /// 注册（手机号 + 邮箱 + 密码）
  Future<LoginResult> register({
    required String phone,
    required String password,
    String? nickname,
    String? email,
  }) async {
    final data = await _post('register', {
      'phone': phone,
      'password': password,
      'nickname': nickname ?? '',
      'email': email ?? '',
    });
    return LoginResult.fromJson(data);
  }

  /// 登录
  Future<LoginResult> login({
    required String phone,
    required String password,
  }) async {
    final data = await _post('login', {
      'phone': phone,
      'password': password,
    });
    return LoginResult.fromJson(data);
  }

  /// 检查手机号是否已注册
  Future<bool> phoneExists(String phone) async {
    final data = await _post('phone_exists', {'phone': phone});
    return (data['exists'] as bool?) ?? false;
  }

  // ── 超级管理员接口（服务端同样校验管理员哈希） ────────

  /// 管理员登录（服务端校验）
  Future<AdminLoginResult> adminLogin({
    required String username,
    required String password,
  }) async {
    final data = await _post('admin_login', {
      'username': username,
      'password': password,
    });
    return AdminLoginResult.fromJson(data);
  }

  /// 用户统计
  Future<Map<String, Object?>> adminStats(String adminToken) async {
    return _post('admin_stats', {}, token: adminToken);
  }

  /// 用户列表（分页）
  Future<AdminUserList> adminUsers(
    String adminToken, {
    int page = 1,
    int pageSize = 20,
    String search = '',
  }) async {
    final data = await _post('admin_users', {
      'page': page,
      'page_size': pageSize,
      'search': search,
    }, token: adminToken);
    return AdminUserList.fromJson(data);
  }

  /// 登录日志 / 操作审计（分页，合并返回）
  Future<AdminLogList> adminLogs(
    String adminToken, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final data = await _post('admin_logs', {
      'page': page,
      'page_size': pageSize,
    }, token: adminToken);
    return AdminLogList.fromJson(data);
  }

  /// 管理端操作审计上报（如邮件接口测试）
  Future<void> adminAudit(String adminToken, String detail) async {
    await _post('admin_audit', {'detail': detail}, token: adminToken);
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class LoginResult {
  final String token;
  final String phone;
  final String nickname;
  final String createdAt;

  const LoginResult({
    required this.token,
    required this.phone,
    this.nickname = '',
    this.createdAt = '',
  });

  factory LoginResult.fromJson(Map<String, Object?> json) => LoginResult(
        token: (json['token'] as String?) ?? '',
        phone: (json['phone'] as String?) ?? '',
        nickname: (json['nickname'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
      );
}

class AdminLoginResult {
  final String token;
  final String username;

  const AdminLoginResult({required this.token, required this.username});

  factory AdminLoginResult.fromJson(Map<String, Object?> json) =>
      AdminLoginResult(
        token: (json['token'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
      );
}

class AdminUserItem {
  final int id;
  final String phone;
  final String nickname;
  final String createdAt;
  final String lastLoginAt;
  final String status;

  const AdminUserItem({
    required this.id,
    required this.phone,
    this.nickname = '',
    this.createdAt = '',
    this.lastLoginAt = '',
    this.status = 'active',
  });

  factory AdminUserItem.fromJson(Map<String, Object?> json) => AdminUserItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        phone: (json['phone'] as String?) ?? '',
        nickname: (json['nickname'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
        lastLoginAt: (json['last_login_at'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'active',
      );
}

class AdminUserList {
  final int total;
  final int page;
  final List<AdminUserItem> users;

  const AdminUserList({
    required this.total,
    required this.page,
    required this.users,
  });

  factory AdminUserList.fromJson(Map<String, Object?> json) => AdminUserList(
        total: (json['total'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        users: ((json['users'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => AdminUserItem.fromJson(e.cast<String, Object?>()))
            .toList(),
      );
}

/// 登录日志 / 审计条目
class AdminLogItem {
  final String time;
  final String account;
  final String action;
  final String ip;
  final String result;

  const AdminLogItem({
    required this.time,
    required this.account,
    required this.action,
    required this.ip,
    required this.result,
  });

  factory AdminLogItem.fromJson(Map<String, Object?> json) => AdminLogItem(
        time: (json['time'] as String?) ?? '',
        account: (json['account'] as String?) ?? '',
        action: (json['action'] as String?) ?? '',
        ip: (json['ip'] as String?) ?? '',
        result: (json['result'] as String?) ?? '',
      );
}

class AdminLogList {
  final int total;
  final int page;
  final List<AdminLogItem> logs;

  const AdminLogList({
    required this.total,
    required this.page,
    required this.logs,
  });

  factory AdminLogList.fromJson(Map<String, Object?> json) => AdminLogList(
        total: (json['total'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        logs: ((json['logs'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => AdminLogItem.fromJson(e.cast<String, Object?>()))
            .toList(),
      );
}
