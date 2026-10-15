package com.daotuo.bodhi_token

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/// 必须继承 FlutterFragmentActivity：
///   1. local_auth（指纹 / 3D 人脸）依赖 FragmentActivity 承载系统 BiometricPrompt
///   2. 扫码页平台视图（bodhi/scan_view）与相册解码通道（bodhi/scan）在此注册
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerScanEngine(flutterEngine, this)
    }
}
