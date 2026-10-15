import 'package:flutter/services.dart';

/// 系统返回键联动注册表
///
/// 背景：本应用的主界面不是 Navigator 路由栈，而是壳层 setState 切换，
/// 系统返回键（底部虚拟导航键）默认"无路可退"，表现为完全无效。
///
/// 解决：根壳层用 PopScope(canPop:false) 统一接管系统返回键，
/// 各子页面（浏览器 / 主导航）向本注册表登记自己的返回处理；
/// 派发顺序为「后注册者优先」（最上层页面先响应），
/// 无人认领时由根壳层兜底（关闭子页 / 应用切后台）。
class SystemBack {
  static final List<Future<bool> Function()> _handlers = [];

  /// 注册返回处理器：返回 true 表示本次返回已被消费
  static void register(Future<bool> Function() handler) {
    _handlers.remove(handler);
    _handlers.add(handler);
  }

  static void unregister(Future<bool> Function() handler) {
    _handlers.remove(handler);
  }

  /// 派发返回事件；返回 true 表示有页面消费了
  static Future<bool> dispatch() async {
    for (final handler in _handlers.toList().reversed) {
      try {
        if (await handler()) return true;
      } catch (_) {
        // 单个处理器异常不阻断派发链
      }
    }
    return false;
  }
}

/// 系统能力桥（MainActivity bodhi/system 通道）
class SystemBridge {
  static const MethodChannel _channel = MethodChannel('bodhi/system');

  /// 把应用切到后台（等同按 Home 键），不杀进程
  ///
  /// 用作根级返回键的标准行为：动态口令应用不应被返回键直接杀死。
  static Future<void> moveTaskToBack() async {
    await _channel.invokeMethod<void>('moveTaskToBack');
  }
}
