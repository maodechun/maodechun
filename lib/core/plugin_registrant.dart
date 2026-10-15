/// Dart 侧平台插件注册（对应 Flutter 工具链自动生成的 dart_plugin_registrant）。
///
/// 背景：手工内核编译用的是原生 gen_kernel_aot，没有 Flutter 工具链注入
/// Dart 插件注册器的补丁。声明了 dartPluginClass 的插件（path_provider /
/// shared_preferences / image_picker / local_auth / sqflite / url_launcher）
/// 不会自动把 PlatformInterface 的默认实现换成各插件实现，导致 Dart 侧
/// 走旧 MethodChannel，而原生端已迁到 Pigeon channel，运行时必然
/// MissingPluginException。
///
/// Flutter 官方 registrant 的语义就是「在 main 前调用各插件 dart 类的
/// registerWith()」，这里手动等价实现，与 Flutter 工具生成的注册顺序无关紧要。
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:path_provider_android/path_provider_android.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:sqflite/sqflite.dart' show SqflitePlugin;
import 'package:url_launcher_android/url_launcher_android.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void registerDartPlugins() {
  if (!Platform.isAndroid) return;

  // path_provider（2.3+ 为纯 Dart 实现 + jni；本工程用 2.2.10 原生实现时，
  // Dart 侧同样需要挂上 Pigeon 实现，与原生 Messages.java 配对）
  _safe(() => PathProviderPlatform.instance = PathProviderAndroid(), 'path_provider');
  // shared_preferences（2.4+ 保留原生 pluginClass 同时声明 dartPluginClass）
  _safe(() => SharedPreferencesAndroid.registerWith(), 'shared_preferences');
  _safe(() => SharedPreferencesAsyncAndroid.registerWith(), 'shared_preferences_async');
  // image_picker
  _safe(() => ImagePickerAndroid.registerWith(), 'image_picker');
  // local_auth
  _safe(() => LocalAuthAndroid.registerWith(), 'local_auth');
  // sqflite（Dart 侧 SqflitePlugin.registerWith 设置 databaseFactory）
  _safe(() => SqflitePlugin.registerWith(), 'sqflite');
  // url_launcher
  _safe(() => UrlLauncherAndroid.registerWith(), 'url_launcher');
  // webview_flutter（Android 端为 dartPluginClass，不注册则
  // WebViewPlatform.instance == null，WebViewController 构造即抛错，
  // 日记页/内置浏览器整页灰屏）
  _safe(() => AndroidWebViewPlatform.registerWith(), 'webview_flutter');
}

/// WebView 平台兜底检查。
///
/// 真机上曾出现 main 里注册后 WebViewPlatform.instance 仍为 null 的
/// 空指针崩溃（Null check operator used on a null value）。
/// 在实际使用 WebView 的入口再校验一次；若为空则立刻补注册。
/// 返回 true 表示平台实现可用。
bool ensureWebViewPlatform() {
  if (!Platform.isAndroid && !Platform.isIOS) return false;
  if (WebViewPlatform.instance != null) return true;
  if (!Platform.isAndroid) return false;
  try {
    AndroidWebViewPlatform.registerWith();
    debugPrint('[PluginRegistrant] WebViewPlatform was null, re-registered OK');
  } catch (e) {
    debugPrint('[PluginRegistrant] WebView re-register FAILED: $e');
  }
  return WebViewPlatform.instance != null;
}

void _safe(VoidCallback fn, String tag) {
  try {
    fn();
  } catch (e) {
    // ⚠️ 不再静默：注册失败会在运行时以更隐蔽的方式炸出来
    //（MissingPluginException / 空指针），这里必须留下Release可见的痕迹。
    debugPrint('[PluginRegistrant] $tag registerWith FAILED: $e');
  }
}

typedef VoidCallback = void Function();
