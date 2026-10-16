package com.daotuo.bodhi_token

import android.content.Intent

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/// 必须继承 FlutterFragmentActivity：
///   1. local_auth（指纹 / 3D 人脸）依赖 FragmentActivity 承载系统 BiometricPrompt
///   2. 扫码页平台视图（bodhi/scan_view）与相册解码通道（bodhi/scan）在此注册
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerScanEngine(flutterEngine, this)
        // 本地密钥备份引擎（下载/菩提护令备份 目录读写 + SAF 选文件）
        LocalBackupEngine.register(flutterEngine, this)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        // 本地备份的 SAF 文件选择器结果
        if (LocalBackupEngine.handleActivityResult(requestCode, resultCode, data)) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
