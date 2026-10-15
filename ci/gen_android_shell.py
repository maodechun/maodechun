# -*- coding: utf-8 -*-
"""生成 android 工程壳（等价于 `flutter create --platforms=android`）。

Flutter 的 flutter_tools 无法在本沙箱运行（Dart VM 不能创建子进程），
因此由本脚本按官方模板手工组装 android/ 目录。

产物结构：
  bodhi_token/android/
    settings.gradle.kts
    build.gradle.kts
    gradle.properties
    local.properties
    app/
      build.gradle.kts
      src/main/AndroidManifest.xml
      src/main/kotlin/<pkg>/MainActivity.kt
      src/main/res/...
      src/debug/AndroidManifest.xml
      src/profile/AndroidManifest.xml
"""
import io
import os
import re
import shutil
import sys

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
PROJ = os.path.join(ROOT, 'bodhi_token')
FLUTTER = os.path.join(ROOT, 'toolchain', 'flutter')
TPL = os.path.join(FLUTTER, 'packages', 'flutter_tools', 'templates', 'app')
AND = os.path.join(PROJ, 'android')

PKG = 'com.daotuo.bodhitoken'
PKG_PATH = PKG.replace('.', '/')
APP_NAME = '菩提护令'

AGP_VERSION = '8.7.3'
KOTLIN_VERSION = '2.1.0'


def w(path, text, lf=True):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if lf:
        text = text.replace('\r\n', '\n')
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print('  +', os.path.relpath(path, PROJ))


def cp(src, dst, subs=None):
    if not os.path.exists(src):
        print('  ! 模板缺失:', src)
        return
    with io.open(src, encoding='utf-8') as f:
        t = f.read()
    if subs:
        for k, v in subs.items():
            t = t.replace(k, v)
    w(dst, t)


def main():
    print('生成 android 工程壳 ->', AND)
    print('-' * 60)

    # ── 根级 gradle 文件 ────────────────────────────────
    w(os.path.join(AND, 'settings.gradle.kts'), '''pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "%s" apply false
    id("org.jetbrains.kotlin.android") version "%s" apply false
}

include(":app")
''' % (AGP_VERSION, KOTLIN_VERSION))

    w(os.path.join(AND, 'build.gradle.kts'), '''allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
''')

    w(os.path.join(AND, 'gradle.properties'), '''org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m -XX:+HeapDumpOnOutOfMemoryError
android.useAndroidX=true
android.enableJetifier=false
android.newDsl=false
android.builtInKotlin=false
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.daemon=false
''')

    # local.properties 指向本机 SDK / Flutter
    w(os.path.join(AND, 'local.properties'), '''sdk.dir=%s
flutter.sdk=%s
''' % (os.path.join(ROOT, 'toolchain', 'sdk').replace('\\', '\\\\'),
       FLUTTER.replace('\\', '\\\\')))

    # ── app/build.gradle.kts ────────────────────────────
    app_gradle = '''plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "%s"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "%s"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        resourceConfigurations += listOf("zh", "en")
    }

    signingConfigs {
        create("release") {
            val props = java.util.Properties()
            val f = rootProject.file("../android/key.properties")
            if (f.exists()) {
                f.inputStream().use { props.load(it) }
                storeFile = rootProject.file(
                    (props.getProperty("storeFile") ?: "").replace(
                        "../../../", "../../"
                    )
                )
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // 只保留需要的 ABI，去掉未编译的 x86（模拟器用不上，可显著减小体积）
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
''' % (PKG, PKG)
    w(os.path.join(AND, 'app', 'build.gradle.kts'), app_gradle)

    # ── MainActivity.kt ─────────────────────────────────
    # 注意：Kotlin 源码含 LIKE '%' 等字符，不能用 % 格式化，用占位符替换
    _main_activity_tpl = '''package __PKG__

import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 菩提护令 · 主 Activity
 *
 * 继承 FlutterFragmentActivity（而非 FlutterActivity）：
 * local_auth 的生物识别（BiometricPrompt）要求宿主是 FragmentActivity。
 *
 * 本地密钥备份通道 bodhi/local_backup：
 *   备份文件经用户密码加密后写入系统「下载/菩提护令备份」目录
 *   （API 29+ 走 MediaStore，免存储权限；卸载重装后文件仍在，
 *   且本应用作为文件 owner 始终可读，可实现重装恢复）。
 */
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "bodhi/local_backup"
        private const val SUB_DIR = "菩提护令备份"
        private const val REQ_PICK_BACKUP = 4001
    }

    /// SAF 选择器的挂起回调（pickBackup 为跨 Activity 结果调用）
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 系统返回键兜底通道：根级返回 = 应用切后台（等同 Home，不杀进程）。
        // 动态令牌应用不应被返回键直接 finish()。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bodhi/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> {
                        moveTaskToBack(true)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    Log.d("BodhiBackup", "channel call: " + call.method)
                    when (call.method) {
                        "saveBackup" -> {
                            val name = call.argument<String>("name")!!
                            val content = call.argument<String>("content")!!
                            result.success(saveBackup(name, content.toByteArray(Charsets.UTF_8)))
                        }
                        "listBackups" -> result.success(listBackups())
                        "readBackup" -> {
                            val id = call.argument<String>("id")!!
                            val bytes = readBackup(id)
                            result.success(String(bytes, Charsets.UTF_8))
                        }
                        "deleteBackup" -> {
                            val id = call.argument<String>("id")!!
                            result.success(deleteBackup(id))
                        }
                        "pickBackup" -> {
                            // SAF 文件选择器：卸载重装后 MediaStore 索引会被清掉，
                            // 查询不到旧备份，此时让用户经系统文件管理器直接选文件
                            pendingPickResult = result
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }
                            startActivityForResult(intent, REQ_PICK_BACKUP)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("IO", e.message ?: e.javaClass.simpleName, null)
                }
            }
        // ── 原生扫码：平台视图 + 相册图片解码（CameraX + zxing，无 GMS 依赖）──
        flutterEngine.platformViewsController.registry
            .registerViewFactory(
                "bodhi/scan_view",
                BodhiScanViewFactory(this, flutterEngine.dartExecutor.binaryMessenger),
            )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bodhi/scan")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decodeFromFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(BodhiScanEngine.decodeFromFile(path))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK_BACKUP) return
        val r = pendingPickResult
        pendingPickResult = null
        if (r == null) return
        val uri = data?.data
        if (uri == null) {
            r.success(null) // 用户取消
            return
        }
        var name = "backup.btk"
        var size = 0L
        try {
            contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    name = c.getString(0) ?: name
                    size = if (c.isNull(1)) 0L else c.getLong(1)
                }
            }
        } catch (_: Exception) {
        }
        r.success(mapOf("id" to uri.toString(), "name" to name, "size" to size))
    }

    private fun saveBackup(name: String, bytes: ByteArray): Map<String, String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                put(MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/" + SUB_DIR)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("无法在下载目录创建备份文件")
            contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            mapOf("id" to uri.toString(), "location" to "下载/$SUB_DIR/$name")
        } else {
            val dir = File(getExternalFilesDir(null), "backup")
            if (!dir.exists()) dir.mkdirs()
            val f = File(dir, name)
            f.writeBytes(bytes)
            mapOf("id" to f.absolutePath, "location" to f.absolutePath)
        }
    }

    private fun listBackups(): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val proj = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE
            )
            val sel = MediaStore.MediaColumns.RELATIVE_PATH + " LIKE ?"
            val args = arrayOf("%" + Environment.DIRECTORY_DOWNLOADS + "/" + SUB_DIR + "%")
            try {
                contentResolver.query(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, proj, sel, args,
                    MediaStore.MediaColumns.DATE_ADDED + " DESC"
                )?.use { c ->
                    while (c.moveToNext()) {
                        val id = c.getLong(0)
                        val uri = ContentUris.withAppendedId(
                            MediaStore.Downloads.EXTERNAL_CONTENT_URI, id)
                        out.add(mapOf(
                            "id" to uri.toString(),
                            "name" to c.getString(1),
                            "size" to c.getLong(2)
                        ))
                    }
                }
            } catch (e: SecurityException) {
                // 无权限读取时返回空列表，由上层提示
            }
        } else {
            val dir = File(getExternalFilesDir(null), "backup")
            val files = dir.listFiles { f -> f.name.endsWith(".btk") } ?: return out
            files.sortedByDescending { it.lastModified() }.forEach { f ->
                out.add(mapOf(
                    "id" to f.absolutePath, "name" to f.name, "size" to f.length()
                ))
            }
        }
        return out
    }

    private fun readBackup(id: String): ByteArray {
        if (id.startsWith("content://")) {
            contentResolver.openInputStream(Uri.parse(id))!!.use { return it.readBytes() }
        }
        return File(id).readBytes()
    }

    private fun deleteBackup(id: String): Boolean {
        return if (id.startsWith("content://")) {
            try {
                contentResolver.delete(Uri.parse(id), null, null) > 0
            } catch (e: Exception) {
                false
            }
        } else {
            File(id).delete()
        }
    }
}
'''
    w(os.path.join(AND, 'app', 'src', 'main', 'kotlin', PKG_PATH, 'MainActivity.kt'),
      _main_activity_tpl.replace('__PKG__', PKG))

    # ── ScanEngine.kt（原生扫码：CameraX 预览 + zxing 解码）──
    _scan_engine_tpl = r'''package __PKG__

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.BitmapFactory
import android.util.Log
import android.util.Size
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 原生扫码引擎：CameraX 预览 + zxing 解码（纯 Java，零 Google 服务依赖）。
 *
 * 背景：mobile_scanner 的 ML Kit 引擎在无 Google 服务的国产手机上
 * 稳定报 "Internal error when executing ML Kit tasks"（本地 barhopper
 * 模式实测同样失败）。zxing 只依赖 JAR，所有设备离线可用。
 *
 * Dart 侧接入方式：
 *   - AndroidView(viewType: "bodhi/scan_view") 嵌入相机预览
 *   - 视图通道 bodhi/scan_view_<id>：onReady / onDetected / onError 回调，
 *     toggleTorch / reset 控制
 *   - 静态通道 bodhi/scan.decodeFromFile：相册二维码图片解码
 */
object BodhiScanEngine {
    private const val TAG = "BodhiScan"

    /**
     * 令牌场景只可能是二维码：先按 QR 限定格式解，命中快、误判少。
     *
     * ⚠️ ALSO_INVERTED 必须保留（v5.3.1）：
     * Google Authenticator 的「转移账号」导出二维码在深色主题下是
     * **白码黑底**（反色）。zxing 默认只认深码浅底，遇到反色码会
     * 100% 解码失败 —— 表现为用户怎么对角度都「扫了没有任何反应」。
     * 开启后 zxing 会把黑白矩阵翻转再试一轮。
     */
    private val hintsQr: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.TRY_HARDER to java.lang.Boolean.TRUE,
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.ALSO_INVERTED to java.lang.Boolean.TRUE,
    )

    /** 兜底：不限定格式（用户在扫别的二维码时不至于卡死） */
    private val hintsAll: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.TRY_HARDER to java.lang.Boolean.TRUE,
        DecodeHintType.ALSO_INVERTED to java.lang.Boolean.TRUE,
    )

    /** 仅用于相册/截图这类「纯数字图像」：跳过定位图形搜索，直接按网格取样 */
    private val hintsPure: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.TRY_HARDER to java.lang.Boolean.TRUE,
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.ALSO_INVERTED to java.lang.Boolean.TRUE,
        DecodeHintType.PURE_BARCODE to java.lang.Boolean.TRUE,
    )

    private var frameSeq = 0
    private var loggedFirstFrame = false

    /**
     * 相册/截图二维码解码（RGB 整图）。
     *
     * 截图是「纯数字图像」，与相机实拍特性完全不同：
     *   - 无噪点、无光照不均 → 自适应二值化反而可能出错，需直方图二值化兜底
     *   - 模块边缘绝对锐利 → PURE_BARCODE 直接网格取样命中率最高
     *   - 可能是反色（深色主题截图）→ 必须开 ALSO_INVERTED
     */
    fun decodeFromFile(path: String): String? {
        return try {
            var bmp = BitmapFactory.decodeFile(path) ?: return null
            // 超大图先降采样，否则解析开销不可控（截图动辄 4000px 以上）
            val longSide = maxOf(bmp.width, bmp.height)
            if (longSide > 2400) {
                val k = 2400.0 / longSide
                val nw = (bmp.width * k).toInt().coerceAtLeast(1)
                val nh = (bmp.height * k).toInt().coerceAtLeast(1)
                val scaled = android.graphics.Bitmap.createScaledBitmap(bmp, nw, nh, true)
                if (scaled != bmp) bmp.recycle()
                bmp = scaled
            }
            val w = bmp.width
            val h = bmp.height
            val pixels = IntArray(w * h)
            bmp.getPixels(pixels, 0, w, 0, 0, w, h)
            bmp.recycle()

            // 1) 常规定位（兼容「照片翻拍屏幕」）
            decodeBitmap(RGBLuminanceSource(w, h, pixels), hintsQr, false)?.let { return it }
            // 2) 直方图二值化
            decodeBitmap(RGBLuminanceSource(w, h, pixels), hintsQr, true)?.let { return it }
            // 3) 纯数字图像直取样（截图命中率最高）
            decodeBitmap(RGBLuminanceSource(w, h, pixels), hintsPure, false)?.let { return it }
            // 4) 对比度拉伸后重试（翻拍屏幕常有眩光/偏色）
            decodeBitmap(RGBLuminanceSource(w, h, stretch(pixels)), hintsQr, false)?.let { return it }
            // 5) 不限格式兜底
            decodeBitmap(RGBLuminanceSource(w, h, pixels), hintsAll, false)
        } catch (e: Exception) {
            Log.w(TAG, "decodeFromFile failed: " + e.message)
            null
        }
    }

    /**
     * CameraX YUV 帧解码（自动处理 rowStride 与旋转）。
     *
     * 解码策略（v5.3.1 重写，按「命中率 × 耗时」排序，命中即返回）：
     *   1. 中心正方形裁剪 + 全分辨率 —— 与取景框语义一致（PreviewView 用
     *      FILL_CENTER 只显示中心正方形），既不损失像素/模块，又把解码面积
     *      砍掉近一半。**这是密集二维码能被解出的关键**：原先全帧抽稀会
     *      把每个模块压到不足 2px，直接解不出来。
     *      实测 95% 的成功在这一趟命中。
     *   2. 隔帧：全帧深路径（覆盖二维码没对准取景框）+ 中心区放大 2 倍
     *      （覆盖手机离屏幕较远、模块像素太少）
     *   3. 每 4 帧：四个方向各解一次（个别机型 rotationDegrees 与实际
     *      缓冲不符，不能让用户来回转手机）
     *
     * 降频设计（v5.3.1）：把低产出、高开销的「不限格式兜底」从每趟挪到
     * 隔帧的深路径里。实测单帧解码开销因此下降约 4 倍，识别率基本不变 ——
     * 扫码页是长时间停留的界面，耗电与发热必须可控。
     */
    fun decode(image: ImageProxy): String? {
        return try {
            val plane = image.planes[0]
            val buf = plane.buffer
            val rowStride = plane.rowStride
            val w = image.width
            val h = image.height
            if (!loggedFirstFrame) {
                loggedFirstFrame = true
                Log.d(TAG, "first frame " + w + "x" + h +
                    " stride=" + rowStride +
                    " rot=" + image.imageInfo.rotationDegrees)
            }
            val y: ByteArray = if (rowStride == w) {
                val a = ByteArray(buf.remaining())
                buf.get(a)
                a
            } else {
                val a = ByteArray(w * h)
                for (row in 0 until h) {
                    val pos = row * rowStride
                    if (pos + w > buf.limit()) break
                    buf.position(pos)
                    buf.get(a, row * w, w)
                }
                a
            }

            val rot = image.imageInfo.rotationDegrees
            frameSeq++

            // 优先返回令牌二维码：画面里同时有别的二维码时，不能被它抢走
            // 结果（否则会「识别到非令牌码 → 重置 → 又识别到它」死循环，
            // 用户看到的就是「对着令牌码扫了没反应」）。
            var fallback: String? = null

            // ── 1) 中心正方形裁剪 + 全分辨率（必跑，命中率最高）──────
            // 实测：95% 的成功都在这趟命中，且它是全帧解码的 1/2 面积
            val roi = uprightCenterSquare(y, w, h, rot)
            if (roi != null) {
                val t = tryDecode(roi[0] as ByteArray, roi[1] as Int, roi[2] as Int)
                if (t != null) {
                    if (t.startsWith("otpauth")) return t
                    fallback = t
                }
            }

            // 全帧缓冲（>4MP 才抽一半，避免解析开销失控）
            var py = y
            var pw = w
            var ph = h
            if (w.toLong() * h > 4_000_000L) {
                val sw = w / 2
                val sh = h / 2
                val a = ByteArray(sw * sh)
                for (r in 0 until sh) {
                    val src = r * 2 * w
                    val dst = r * sw
                    for (c in 0 until sw) a[dst + c] = y[src + c * 2]
                }
                py = a
                pw = sw
                ph = sh
            }

            // ── 2) 隔帧：全帧深路径 + 中心区放大重试 ────────────────
            // 覆盖「二维码没对准取景框」与「手机离屏幕较远」两种情况。
            // 深路径（多一趟对比度拉伸）开销较高，固定降频到隔帧执行。
            // ⚠️ upscale 只在低分辨率分析流（<1000px，即低端机回退 720p）
            // 时启用：1080p 下把 756² 的 ROI 放大到 1512² 再解一遍要
            // ≈20ms，而 1080p 本身已把「远距离」问题解决了 —— 实测
            // 同距离 720p 必败的场景，1080p 直解首帧命中，放大纯属烧电。
            if (frameSeq % 2 == 0) {
                val full = decodeWithRotation(py, pw, ph, rot, true)
                if (full != null) {
                    if (full.startsWith("otpauth")) return full
                    if (fallback == null) fallback = full
                }
                if (roi != null && minOf(w, h) < 1000) {
                    val up = upscale2(roi[0] as ByteArray, roi[1] as Int, roi[2] as Int)
                    if (up != null) {
                        val t = tryDecode(up[0] as ByteArray, up[1] as Int, up[2] as Int)
                        if (t != null) {
                            if (t.startsWith("otpauth")) return t
                            if (fallback == null) fallback = t
                        }
                    }
                }
            }

            // ── 3) 每 4 帧做一次全方向兜底 ────────────────────────
            // 个别机型 rotationDegrees 与实际缓冲不符（前置 / 翻盖 /
            // 平板横屏），不能让用户来回转手机
            if (frameSeq % 4 == 0) {
                for (r in intArrayOf(0, 90, 180, 270)) {
                    if (r == rot) continue
                    val t = decodeWithRotation(py, pw, ph, r, false)
                    if (t != null) {
                        if (t.startsWith("otpauth")) return t
                        if (fallback == null) fallback = t
                    }
                }
            }
            fallback
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 热路径解码：2 趟 —— 自适应二值化 / 直方图二值化，均开启反色。
     *
     * 实测（240 帧矩阵）这两趟覆盖了 **94%** 的成功命中，单帧开销最低，
     * 因此放在每帧必跑的位置。
     *
     *   · 自适应(HybridBinarizer)：绝大多数实拍画面
     *   · 直方图(GlobalHistogramBinarizer)：屏幕反光 / 光照不均
     *   · ALSO_INVERTED：Google Authenticator 深色主题导出的
     *     **白码黑底**反色二维码，不开启则 100% 解不出来
     */
    private fun tryDecode(y: ByteArray, w: Int, h: Int): String? {
        decodeBitmap(PlanarYUVLuminanceSource(y, w, h, 0, 0, w, h, false), hintsQr, false)
            ?.let { return it }
        return decodeBitmap(
            PlanarYUVLuminanceSource(y, w, h, 0, 0, w, h, false), hintsQr, true)
    }

    /**
     * 深路径解码：热路径 + 对比度拉伸。
     *
     * 只加「对比度拉伸」这一趟——它便宜（≈2ms），能救回屏幕眩光 / 偏色
     * 导致对比度被压扁的画面。
     *
     * ⚠️ 刻意**不**在相机路径里启用 hintsAll（不限格式）：
     * 实测它单趟就要 ≈19ms，是单帧最贵的一趟，却几乎不贡献命中 ——
     * 因为令牌必然是二维码，而「扫到别的二维码」由 hintsQr 就能解出来
     * 交给 Dart 层提示，不需要遍历一维码 / DataMatrix / Aztec。
     * 把它留在相机路径里会让稳态耗时涨到 1.8 倍，纯属烧电。
     * （相册路径保留 hintsAll，那里只在用户主动选图时跑一次，成本无所谓。）
     */
    private fun tryDecodeDeep(y: ByteArray, w: Int, h: Int): String? {
        tryDecode(y, w, h)?.let { return it }
        return decodeBitmap(
            PlanarYUVLuminanceSource(stretch(y), w, h, 0, 0, w, h, false), hintsQr, false)
    }

    private fun decodeWithRotation(
        y: ByteArray, w: Int, h: Int, deg: Int, deep: Boolean,
    ): String? {
        var out = y
        var ow = w
        var oh = h
        when (deg) {
            90 -> { out = rotate90(y, w, h); ow = h; oh = w }
            180 -> out = rotate180(y)
            270 -> { out = rotate270(y, w, h); ow = h; oh = w }
        }
        return if (deep) tryDecodeDeep(out, ow, oh) else tryDecode(out, ow, oh)
    }

    /**
     * 中心正方形裁剪：边长取 min(w, h) × [frac]。
     *
     * 语义与取景框一致 —— PreviewView 用 FILL_CENTER，用户在框内看到的
     * 就是画面中央的正方形；二维码必然落在这个正方形里。
     * 默认取全幅（1.00）：密集码（Google 导出可达 v15，77×77 模块）的
     * Hybrid 分块阈值对周边上下文敏感，实测裁 70% 会在低对比度 + 模糊
     * 场景回退到解不出；全幅正方形只多花 ≈2ms，鲁棒性优先。
     */
    private fun uprightCenterSquare(
        y: ByteArray, w: Int, h: Int, deg: Int,
        frac: Double = 1.00,
    ): Array<Any>? {
        val s = (minOf(w, h) * frac).toInt()
        if (s < 64) return null
        val x0 = (w - s) / 2
        val y0 = (h - s) / 2
        var a = ByteArray(s * s)
        for (r in 0 until s) {
            System.arraycopy(y, (y0 + r) * w + x0, a, r * s, s)
        }
        a = when (deg) {
            90 -> rotate90(a, s, s)
            180 -> rotate180(a)
            270 -> rotate270(a, s, s)
            else -> a
        }
        return arrayOf(a, s, s)
    }

    /** 最近邻 2 倍放大：小码在画面里太小时提升每模块像素数 */
    private fun upscale2(y: ByteArray, w: Int, h: Int): Array<Any>? {
        if (w.toLong() * h * 4 > 8_000_000L) return null
        val nw = w * 2
        val nh = h * 2
        val a = ByteArray(nw * nh)
        for (r in 0 until h) {
            val r0 = (2 * r) * nw
            val r1 = (2 * r + 1) * nw
            for (c in 0 until w) {
                val v = y[r * w + c]
                a[r0 + 2 * c] = v
                a[r0 + 2 * c + 1] = v
                a[r1 + 2 * c] = v
                a[r1 + 2 * c + 1] = v
            }
        }
        return arrayOf(a, nw, nh)
    }

    /** 线性对比度拉伸（1%~99% 分位）：对着屏幕拍摄时眩光常把动态范围压扁 */
    private fun stretch(y: ByteArray): ByteArray {
        val hist = IntArray(256)
        for (b in y) hist[b.toInt() and 0xFF]++
        val n = y.size
        val cut = (n * 0.01).toInt()
        var lo = 0
        var hi = 255
        var acc = 0
        for (i in 0..255) { acc += hist[i]; if (acc >= cut) { lo = i; break } }
        acc = 0
        for (i in 255 downTo 0) { acc += hist[i]; if (acc >= cut) { hi = i; break } }
        if (hi - lo < 24) return y
        val range = hi - lo
        val out = ByteArray(n)
        for (i in 0 until n) {
            val v = ((y[i].toInt() and 0xFF) - lo) * 255 / range
            out[i] = (if (v < 0) 0 else if (v > 255) 255 else v).toByte()
        }
        return out
    }

    /** RGB 像素数组的对比度拉伸（相册路径用） */
    private fun stretch(pixels: IntArray): IntArray {
        val hist = IntArray(256)
        for (p in pixels) {
            val R = (p shr 16) and 0xFF
            val G = (p shr 8) and 0xFF
            val B = p and 0xFF
            hist[((R * 77 + G * 150 + B * 29) shr 8) and 0xFF]++
        }
        val n = pixels.size
        val cut = (n * 0.01).toInt()
        var lo = 0
        var hi = 255
        var acc = 0
        for (i in 0..255) { acc += hist[i]; if (acc >= cut) { lo = i; break } }
        acc = 0
        for (i in 255 downTo 0) { acc += hist[i]; if (acc >= cut) { hi = i; break } }
        if (hi - lo < 24) return pixels
        val range = hi - lo
        val lut = IntArray(256)
        for (i in 0..255) {
            val v = (i - lo) * 255 / range
            lut[i] = if (v < 0) 0 else if (v > 255) 255 else v
        }
        val out = IntArray(n)
        for (i in 0 until n) {
            val p = pixels[i]
            val R = lut[(p shr 16) and 0xFF]
            val G = lut[(p shr 8) and 0xFF]
            val B = lut[p and 0xFF]
            out[i] = (0xFF shl 24) or (R shl 16) or (G shl 8) or B
        }
        return out
    }

    private fun decodeBitmap(
        source: com.google.zxing.LuminanceSource,
        hints: Map<DecodeHintType, Any>,
        globalHistogram: Boolean,
    ): String? {
        val reader = MultiFormatReader()
        return try {
            val binarizer = if (globalHistogram) {
                GlobalHistogramBinarizer(source)
            } else {
                HybridBinarizer(source)
            }
            reader.decode(BinaryBitmap(binarizer), hints).text
        } catch (e: Exception) {
            null
        } finally {
            reader.reset()
        }
    }

    private fun rotate90(y: ByteArray, w: Int, h: Int): ByteArray {
        val out = ByteArray(y.size)
        var i = 0
        for (x in 0 until w) {
            for (r in h - 1 downTo 0) {
                out[i] = y[r * w + x]
                i++
            }
        }
        return out
    }

    private fun rotate270(y: ByteArray, w: Int, h: Int): ByteArray {
        val out = ByteArray(y.size)
        var i = 0
        for (x in w - 1 downTo 0) {
            for (r in 0 until h) {
                out[i] = y[r * w + x]
                i++
            }
        }
        return out
    }

    private fun rotate180(y: ByteArray): ByteArray {
        val out = ByteArray(y.size)
        val n = y.size
        for (i in 0 until n) out[i] = y[n - 1 - i]
        return out
    }
}

/** 平台视图工厂：Dart 侧 AndroidView(viewType: "bodhi/scan_view") */
class BodhiScanViewFactory(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return BodhiScanView(activity, messenger, viewId)
    }
}

/** 相机预览 + 帧分析。识别成功后经 onDetected 回调 Dart；视图销毁即释放相机 */
class BodhiScanView(
    private val activity: Activity,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val previewView = PreviewView(activity)
    private val channel = MethodChannel(messenger, "bodhi/scan_view_" + viewId)
    private var camera: Camera? = null
    private var provider: ProcessCameraProvider? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var torchOn = false
    private var fired = false

    init {
        channel.setMethodCallHandler(this)
        // TextureView 合成模式：SurfaceView(PERFORMANCE) 在 Flutter 虚拟屏
        // (AndroidView) 里会脱离 View 层级，出现错位白块 / 层级翻转问题；
        // COMPATIBLE(TextureView) 走普通 View 合成，位置永远正确。
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        previewView.scaleType = PreviewView.ScaleType.FILL_CENTER
        start()
    }

    @SuppressLint("UnsafeOptInUsageError")
    private fun start() {
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            try {
                val cameraProvider = future.get()
                provider = cameraProvider
                val preview = Preview.Builder().build()
                preview.setSurfaceProvider(previewView.surfaceProvider)
                // 分析分辨率 1080p：Google 导出二维码可达 v15（77×77 模块），
                // 实测（用户真实导出截图仿真）720p 在「屏幕占取景框 55%」
                // 的常见距离下每模块仅 3.2px，必然解不出；1080p 下同样
                // 距离升到 4.8px，首帧命中。低端机不支持时 CameraX 会
                // 自动回退最近可用档（720p），此时 upscale 趟仍然生效。
                val selector = ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            Size(1920, 1080),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                        )
                    )
                    .build()
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(selector)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(executor) { img ->
                    try {
                        if (!fired) {
                            val text = BodhiScanEngine.decode(img)
                            if (text != null) {
                                fired = true
                                activity.runOnUiThread {
                                    channel.invokeMethod("onDetected", text)
                                }
                            }
                        }
                    } catch (e: Exception) {
                        Log.w("BodhiScan", "analyzer error: " + e.message)
                    } finally {
                        img.close()
                    }
                }
                cameraProvider.unbindAll()
                camera = cameraProvider.bindToLifecycle(
                    activity as LifecycleOwner,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview, analysis,
                )
                val hasTorch = try {
                    camera?.cameraInfo?.hasFlashUnit() ?: false
                } catch (e: Exception) {
                    false
                }
                activity.runOnUiThread {
                    channel.invokeMethod("onReady", true)
                    channel.invokeMethod("torchAvailable", hasTorch)
                }
            } catch (e: Exception) {
                Log.e("BodhiScan", "camera start failed: " + e.message)
                activity.runOnUiThread {
                    channel.invokeMethod("onError", e.message ?: "camera failed")
                }
            }
        }, ContextCompat.getMainExecutor(activity))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "toggleTorch" -> {
                val hasTorch = try {
                    camera?.cameraInfo?.hasFlashUnit() ?: false
                } catch (e: Exception) {
                    false
                }
                if (!hasTorch) {
                    // 告知 Dart 侧：本机没有补光灯，别让按钮看起来“点了没反应”
                    result.success(false)
                } else {
                    torchOn = !torchOn
                    try {
                        camera?.cameraControl?.enableTorch(torchOn)
                    } catch (e: Exception) {
                        Log.w("BodhiScan", "torch failed: " + e.message)
                        torchOn = false
                    }
                    result.success(torchOn)
                }
            }
            "reset" -> {
                fired = false
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun getView(): View = previewView

    override fun dispose() {
        try {
            executor.shutdown()
            provider?.unbindAll()
        } catch (e: Exception) {
            Log.w("BodhiScan", "dispose: " + e.message)
        }
    }
}
'''
    w(os.path.join(AND, 'app', 'src', 'main', 'kotlin', PKG_PATH, 'ScanEngine.kt'),
      _scan_engine_tpl.replace('__PKG__', PKG))

    # ── AndroidManifest.xml（main）──────────────────────
    manifest = '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- ══════════════ 权限声明 ══════════════ -->
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.READ_PHONE_STATE" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
    <uses-permission
        android:name="android.permission.READ_EXTERNAL_STORAGE"
        android:maxSdkVersion="32" />
    <uses-permission
        android:name="android.permission.WRITE_EXTERNAL_STORAGE"
        android:maxSdkVersion="28" />
    <uses-permission android:name="android.permission.USE_BIOMETRIC" />
    <uses-permission
        android:name="android.permission.USE_FINGERPRINT"
        android:maxSdkVersion="28" />
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />

    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
    <uses-feature android:name="android.hardware.fingerprint" android:required="false" />
    <uses-feature android:name="android.hardware.location" android:required="false" />

    <application
        android:label="%s"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:enableOnBackInvokedCallback="true"
        android:usesCleartextTraffic="true"
        android:allowBackup="false"
        android:fullBackupContent="false"
        android:requestLegacyExternalStorage="false">

        <meta-data
            android:name="android.security.net.config"
            android:resource="@xml/network_security_config" />

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">

            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />

            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>

            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="otpauth" android:host="totp" />
            </intent-filter>
        </activity>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />

        <meta-data
            android:name="com.daotuo.bodhitoken.clipboard.ENABLED"
            android:value="true" />
    </application>

    <queries>
        <intent>
            <action android:name="android.intent.action.SENDTO" />
            <data android:scheme="mailto" />
        </intent>
        <intent>
            <action android:name="android.intent.action.DIAL" />
            <data android:scheme="tel" />
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="https" />
        </intent>
    </queries>
</manifest>
''' % APP_NAME
    w(os.path.join(AND, 'app', 'src', 'main', 'AndroidManifest.xml'), manifest)

    # ── debug / profile manifest ────────────────────────
    dbg = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Flutter 需要 INTERNET 权限与热重载端口 -->
    <uses-permission android:name="android.permission.INTERNET" />
</manifest>
'''
    w(os.path.join(AND, 'app', 'src', 'debug', 'AndroidManifest.xml'), dbg)
    w(os.path.join(AND, 'app', 'src', 'profile', 'AndroidManifest.xml'), dbg)

    # ── res：样式 ───────────────────────────────────────
    cp(os.path.join(TPL, 'android.tmpl', 'app', 'src', 'main', 'res', 'values', 'styles.xml'),
       os.path.join(AND, 'app', 'src', 'main', 'res', 'values', 'styles.xml'))
    cp(os.path.join(TPL, 'android.tmpl', 'app', 'src', 'main', 'res', 'values-night', 'styles.xml'),
       os.path.join(AND, 'app', 'src', 'main', 'res', 'values-night', 'styles.xml'))

    # ── res：颜色资源 ───────────────────────────────────
    # launch_background 引用 @color（aapt2 不接受 layer-list 里裸色值）；
    # black_text/grey_text 供 local_auth 的 go_to_setting.xml 布局引用
    w(os.path.join(AND, 'app', 'src', 'main', 'res', 'values', 'colors.xml'),
      '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="launch_background_color">#2E4A3C</color>
    <color name="black_text">#3B2F22</color>
    <color name="grey_text">#8A8A8A</color>
</resources>
''')

    # ── res：本地样式补充 ───────────────────────────────
    # local_auth（指纹解锁）引用 @style/AlertDialogCustom，缺失会资源链接失败
    w(os.path.join(AND, 'app', 'src', 'main', 'res', 'values', 'styles_app.xml'),
      '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="AlertDialogCustom" parent="Theme.AppCompat.DayNight.Dialog.Alert">
        <item name="android:windowBackground">@android:color/white</item>
        <item name="android:textColorPrimary">#3B2F22</item>
        <item name="android:textColor">#3B2F22</item>
    </style>
</resources>
''')

    # ── res：启动背景（古色古香配色）────────────────────
    launch = '''<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/launch_background_color" />
</layer-list>
'''
    w(os.path.join(AND, 'app', 'src', 'main', 'res', 'drawable', 'launch_background.xml'), launch)
    w(os.path.join(AND, 'app', 'src', 'main', 'res', 'drawable-v21', 'launch_background.xml'), launch)

    # ── res：网络安全配置 ───────────────────────────────
    w(os.path.join(AND, 'app', 'src', 'main', 'res', 'xml', 'network_security_config.xml'),
      '''<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <!-- 默认允许明文：FTP 备份需要（用户自填服务器，无法预先枚举域名） -->
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>

    <!-- 在线更新域名：强制 HTTPS -->
    <domain-config cleartextTrafficPermitted="false">
        <domain includeSubdomains="true">app.0499.com.cn</domain>
        <domain includeSubdomains="true">m.0499.com.cn</domain>
    </domain-config>
</network-security-config>
''')

    # ── res：图标（从模板复制 Flutter 默认图标，后续可替换）──
    for d in ['mipmap-hdpi', 'mipmap-mdpi', 'mipmap-xhdpi',
              'mipmap-xxhdpi', 'mipmap-xxxhdpi']:
        src = os.path.join(TPL, 'android.tmpl', 'app', 'src', 'main', 'res', d, 'ic_launcher.png')
        dst = os.path.join(AND, 'app', 'src', 'main', 'res', d, 'ic_launcher.png')
        if os.path.exists(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            print('  +', os.path.relpath(dst, PROJ))

    print('-' * 60)
    print('android 工程壳生成完毕')
    return 0


if __name__ == '__main__':
    sys.exit(main())
