/// 自动上锁挂起开关
///
/// 备份/恢复等跨页面流程（如 SAF 文件选择器）期间，系统选择器
/// Activity 会让应用进入 paused 状态超过 30 秒，触发自动上锁并
/// 卸载设置页，导致流程在 `!mounted` 处静默中止。
/// 流程期间置为 true，结束（完成或取消）后复位。
class AutoLockGuard {
  AutoLockGuard._();

  static bool suspended = false;

  /// 在挂起状态下执行 [action]
  static Future<T> run<T>(Future<T> Function() action) async {
    final prev = suspended;
    suspended = true;
    try {
      return await action();
    } finally {
      suspended = prev;
    }
  }
}
