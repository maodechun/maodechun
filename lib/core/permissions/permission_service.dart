import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// 权限申请服务
///
/// 统一管理本应用申请的四项敏感权限：
///   · 相机      —— 扫描二维码绑定密钥
///   · 图库/相册 —— 从相册导入二维码图片
///   · 定位      —— 发现局域网 FTP 服务器 / 校时定位
///   · 设备识别码 —— 备份文件绑定校验（READ_PHONE_STATE）
///
/// 合规要求：申请前必须先向用户说明用途（由调用方负责展示说明），
/// 本服务只负责发起系统权限请求并返回结果。
class PermissionService {
  PermissionService._();

  static final PermissionService instance = PermissionService._();

  /// 相机权限
  Future<bool> requestCamera() => _grant(Permission.camera);

  /// 图库 / 相册权限
  ///
  /// Android 13+ 使用分媒体权限（photos / READ_MEDIA_IMAGES），
  /// Android 12 及以下使用 storage（READ_EXTERNAL_STORAGE）。
  Future<bool> requestGallery() async {
    try {
      final permission = await _galleryPermission();
      final status = await permission.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 定位权限
  Future<bool> requestLocation() => _grant(Permission.location);

  /// 设备识别码（READ_PHONE_STATE）
  Future<bool> requestPhoneState() => _grant(Permission.phone);

  /// 一次性申请四项权限，返回各项是否已授予
  Future<Map<String, bool>> requestAll() async {
    return <String, bool>{
      'camera': await requestCamera(),
      'gallery': await requestGallery(),
      'location': await requestLocation(),
      'phone': await requestPhoneState(),
    };
  }

  /// 打开本应用的系统设置页（用于权限被「不再询问」后手动开启）
  Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (_) {}
  }

  /// 查询四项权限当前授予状态
  Future<Map<String, bool>> checkAll() async {
    try {
      final gallery = await _galleryPermission();
      final statuses = await Future.wait<PermissionStatus>([
        Permission.camera.status,
        gallery.status,
        Permission.location.status,
        Permission.phone.status,
      ]);
      return <String, bool>{
        'camera': statuses[0].isGranted,
        'gallery': statuses[1].isGranted,
        'location': statuses[2].isGranted,
        'phone': statuses[3].isGranted,
      };
    } catch (_) {
      return <String, bool>{
        'camera': false,
        'gallery': false,
        'location': false,
        'phone': false,
      };
    }
  }

  /// 是否仍存在未授予的权限
  Future<bool> hasMissingPermissions() async {
    final states = await checkAll();
    return states.values.any((granted) => !granted);
  }

  Future<bool> _grant(Permission permission) async {
    try {
      final status = await permission.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 解析当前系统应使用的图库权限
  Future<Permission> _galleryPermission() async {
    if (!Platform.isAndroid) return Permission.photos;
    try {
      final sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      return sdkInt >= 33 ? Permission.photos : Permission.storage;
    } catch (_) {
      return Permission.photos;
    }
  }
}
