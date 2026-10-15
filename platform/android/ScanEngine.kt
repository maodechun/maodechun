package com.daotuo.bodhi_token

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 菩提护令 · 原生扫码引擎（CameraX + zxing）
 *
 * 扫码页 AndroidView(viewType: 'bodhi/scan_view') 的原生实现。
 * 纯 zxing 解码，零 Google 服务依赖，所有设备离线可用。
 *
 * Dart 侧约定（lib/features/scan/scan_page.dart）：
 *   - 视图通道 bodhi/scan_view_<id>：
 *       原生 → Flutter : onReady / onDetected(payload) / onError(msg) /
 *                        torchAvailable(bool)
 *       Flutter → 原生 : reset / toggleTorch(→bool)
 *   - 静态通道 bodhi/scan：decodeFromFile(path → String?)（相册识别）
 */
class ScanViewFactory(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return ScanPlatformView(activity, context, viewId, messenger)
    }
}

class ScanPlatformView(
    private val activity: Activity,
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "ScanEngine"
    }

    private val previewView = PreviewView(context)
    private val channel = MethodChannel(messenger, "bodhi/scan_view_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val analyzerExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var torchOn = false
    private var ready = false
    private var disposed = false

    private val reader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(
                    BarcodeFormat.QR_CODE,
                    BarcodeFormat.DATA_MATRIX,
                    BarcodeFormat.AZTEC,
                    BarcodeFormat.PDF_417,
                ),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
    }

    init {
        channel.setMethodCallHandler(this)
        // PreviewView 默认 FIT_CENTER，填充扫描框区域即可
        startCamera()
    }

    // ── 相机启动 ─────────────────────────────────────────

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener(
            {
                if (disposed) return@addListener
                try {
                    val provider = future.get()
                    cameraProvider = provider
                    bindCamera(provider)
                } catch (e: Exception) {
                    Log.e(TAG, "camera init failed", e)
                    channel.invokeMethod("onError", "相机初始化失败：${e.message ?: e}")
                }
            },
            ContextCompat.getMainExecutor(activity),
        )
    }

    @Suppress("RestrictedApi")
    private fun bindCamera(provider: ProcessCameraProvider) {
        if (disposed || camera != null) return
        val preview = Preview.Builder().build().also {
            it.setSurfaceProvider(previewView.surfaceProvider)
        }
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { view ->
                view.setAnalyzer(analyzerExecutor) { image -> analyzeFrame(image) }
            }

        try {
            val cam = provider.bindToLifecycle(
                activity as LifecycleOwner,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview,
                analysis,
            )
            camera = cam
            ready = true
            channel.invokeMethod("onReady", null)

            val hasFlash = try {
                cam.cameraInfo.hasFlashUnit()
            } catch (_: Exception) {
                false
            }
            channel.invokeMethod("torchAvailable", hasFlash)
        } catch (e: Exception) {
            Log.e(TAG, "camera bind failed", e)
            channel.invokeMethod("onError", "相机启动失败：${e.message ?: e}")
        }
    }

    // ── 实时帧解码 ───────────────────────────────────────

    private fun analyzeFrame(image: ImageProxy) {
        try {
            val rotation = try {
                image.imageInfo.rotationDegrees
            } catch (_: Exception) {
                0
            }
            var yData = ByteArray(image.width * image.height)
            var w = image.width
            var h = image.height

            val yPlane = image.planes[0]
            val buf = yPlane.buffer
            val rowStride = yPlane.rowStride
            val pixelStride = yPlane.pixelStride
            if (pixelStride == 1 && rowStride == w) {
                buf.get(yData, 0, yData.size)
            } else {
                var pos = 0
                for (row in 0 until h) {
                    buf.position(row * rowStride)
                    if (pixelStride == 1) {
                        buf.get(yData, pos, w)
                        pos += w
                    } else {
                        for (col in 0 until w) {
                            yData[pos++] = buf.get(row * rowStride + col * pixelStride)
                        }
                    }
                }
            }

            // 旋转到与屏幕方向一致（CameraX rotationDegrees 为顺时针角度）
            var times = ((rotation % 360) + 360) % 360 / 90
            if (times == 3) times = 1 // 270° 等价于反向 90°
            var rotated = yData
            for (i in 0 until times) {
                val r = rotate90(rotated, w, h)
                rotated = r.first
                w = r.second
                h = r.third
            }

            val source = PlanarYUVLuminanceSource(rotated, w, h, 0, 0, w, h, false)
            val payload = tryDecode(source)
            if (payload != null && !disposed) {
                val p = payload
                mainHandler.post {
                    if (!disposed) channel.invokeMethod("onDetected", p)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "frame decode error: ${e.message}")
        } finally {
            image.close()
        }
    }

    private fun tryDecode(source: PlanarYUVLuminanceSource): String? {
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
        } catch (_: NotFoundException) {
            null
        } catch (_: Exception) {
            null
        } finally {
            try {
                reader.reset()
            } catch (_: Exception) {
            }
        }
    }

    // ── Flutter → 原生 方法 ──────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "reset" -> result.success(true)
            "toggleTorch" -> {
                val cam = camera
                if (cam == null) {
                    result.success(false)
                } else {
                    torchOn = !torchOn
                    cam.cameraControl.enableTorch(torchOn)
                    result.success(torchOn)
                }
            }
            else -> result.notImplemented()
        }
    }

    // ── 生命周期 ─────────────────────────────────────────

    override fun getView(): android.view.View = previewView

    override fun dispose() {
        disposed = true
        try {
            channel.setMethodCallHandler(null)
        } catch (_: Exception) {
        }
        try {
            analyzerExecutor.shutdown()
        } catch (_: Exception) {
        }
        try {
            cameraProvider?.unbindAll()
        } catch (_: Exception) {
        }
        camera = null
    }
}

/** 亮度矩阵顺时针旋转 90°（数据、宽、高） */
private fun rotate90(data: ByteArray, w: Int, h: Int): Triple<ByteArray, Int, Int> {
    val out = ByteArray(data.size)
    for (y in 0 until h) {
        val rowStart = y * w
        for (x in 0 until w) {
            out[x * h + (h - 1 - y)] = data[rowStart + x]
        }
    }
    return Triple(out, h, w)
}

/**
 * 相册图片解码（静态通道 bodhi/scan · decodeFromFile）
 *
 * 稳健策略：限制最大边长解码 → 两种裁剪 → 4 个旋转方向逐一尝试。
 */
object ScanDecoder {

    private val reader = MultiFormatReader()

    fun decodeFromFile(path: String?, callback: (String?) -> Unit) {
        if (path.isNullOrEmpty()) {
            callback(null)
            return
        }
        Thread {
            var payload: String? = null
            try {
                payload = decodeInternal(path)
            } catch (_: Exception) {
            }
            val p = payload
            android.os.Handler(Looper.getMainLooper()).post { callback(p) }
        }.start()
    }

    private fun decodeInternal(path: String): String? {
        // 1. 读尺寸并限制最大边 1600，避免大图解码 OOM
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sample = 1
        var maxSide = maxOf(bounds.outWidth, bounds.outHeight)
        while (maxSide / sample > 1600) sample *= 2

        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val base = BitmapFactory.decodeFile(path, opts) ?: return null

        // 2. 4 个旋转方向（Bitmap 矩阵旋转）× 2 种二值化兜底
        val matrix = Matrix()
        var payload: String? = null
        for (rotation in 0 until 4) {
            val rotated = if (rotation == 0) base else {
                matrix.postRotate(90f)
                val r = Bitmap.createBitmap(base, 0, 0, base.width, base.height, matrix, true)
                r
            }
            val pixels = IntArray(rotated.width * rotated.height)
            rotated.getPixels(pixels, 0, rotated.width, 0, 0, rotated.width, rotated.height)
            val src: com.google.zxing.LuminanceSource =
                RGBLuminanceSource(rotated.width, rotated.height, pixels)

            payload = try {
                reader.decode(BinaryBitmap(HybridBinarizer(src))).text
            } catch (_: NotFoundException) {
                // GlobalHistogram 对低对比度截图有时更有效
                try {
                    reader.decode(
                        BinaryBitmap(com.google.zxing.common.GlobalHistogramBinarizer(src)),
                    ).text
                } catch (_: Exception) {
                    null
                }
            } catch (_: Exception) {
                null
            } finally {
                try {
                    reader.reset()
                } catch (_: Exception) {
                }
            }
            if (rotated !== base) rotated.recycle()
            if (payload != null) break
        }
        base.recycle()
        return payload
    }
}

/** 供 MainActivity 注册视图工厂与静态通道 */
fun registerScanEngine(flutterEngine: FlutterEngine, activity: Activity) {
    flutterEngine.platformViewsController.registry
        .registerViewFactory("bodhi/scan_view", ScanViewFactory(activity, flutterEngine.dartExecutor.binaryMessenger))
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bodhi/scan")
        .setMethodCallHandler { call, result ->
            when (call.method) {
                "decodeFromFile" -> {
                    ScanDecoder.decodeFromFile(call.argument<String>("path")) { payload ->
                        result.success(payload)
                    }
                }
                else -> result.notImplemented()
            }
        }
}
