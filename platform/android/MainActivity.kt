package com.daotuo.bodhi_token

import io.flutter.embedding.android.FlutterFragmentActivity

/// 必须继承 FlutterFragmentActivity：
/// local_auth（指纹 / 3D 人脸）依赖 FragmentActivity 承载
/// 系统 BiometricPrompt，继承普通 FlutterActivity 时
/// 生物识别调用会直接抛异常，表现为只能用密码解锁。
class MainActivity : FlutterFragmentActivity()
