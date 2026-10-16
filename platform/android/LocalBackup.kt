package com.daotuo.bodhi_token

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 菩提护令 · 本地备份引擎（bodhi/local_backup 通道）
 *
 * 设计原则：**任何一步失败都必须留下可读原因**，绝不静默无反应。
 *
 * 备份文件（.dt / 旧 .btk）优先写入公共「下载/菩提护令备份」目录，
 * 卸载重装后文件依然存在；三级写入兜底：
 *   1. Android 10+：MediaStore.Downloads（无需存储权限）
 *   2. 公共下载目录文件 API（部分 ROM 需要存储权限）
 *   3. 应用外部私有目录（必然可写，卸载会丢失，位置如实上报）
 *
 * 读取/列表面向四处扫描并去重，避免「MediaStore 索引缺失导致找不到备份」。
 *
 * Dart 侧约定（lib/data/services/local_backup_service.dart）：
 *   saveBackup(name, content)  → { location: String }
 *   listBackups()              → [ { id, name, size } ]
 *   readBackup(id)             → String（文件文本内容）
 *   deleteBackup(id)           → bool
 *   pickBackup()               → { id, name, size } | null（用户取消）
 *   selfTest()                 → { ... 诊断信息 }
 */
class LocalBackupEngine private constructor(
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "LocalBackup"
        private const val CHANNEL = "bodhi/local_backup"
        private const val SUB_DIR = "菩提护令备份"
        private const val REQ_PICK = 42001

        @Volatile
        private var instance: LocalBackupEngine? = null

        fun register(engine: FlutterEngine, activity: Activity) {
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                CHANNEL,
            )
            instance = LocalBackupEngine(activity)
            channel.setMethodCallHandler(instance)
        }

        /** 由 MainActivity.onActivityResult 转发；返回 true 表示已处理 */
        fun handleActivityResult(
            requestCode: Int,
            resultCode: Int,
            data: Intent?,
        ): Boolean = instance?.onActivityResult(requestCode, resultCode, data) ?: false
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pickResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveBackup" -> {
                val name = call.argument<String>("name") ?: ""
                val content = call.argument<String>("content") ?: ""
                runAsync(result) { saveBackup(name, content) }
            }
            "listBackups" -> runAsync(result) { listBackups() }
            "readBackup" -> {
                val id = call.argument<String>("id") ?: ""
                runAsync(result) { readBackup(id) }
            }
            "deleteBackup" -> {
                val id = call.argument<String>("id") ?: ""
                runAsync(result) { deleteBackup(id) }
            }
            "selfTest" -> runAsync(result) { selfTest() }
            "pickBackup" -> launchPicker(result)
            else -> result.notImplemented()
        }
    }

    // ── SAF 文件选择器 ───────────────────────────────────

    private fun launchPicker(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "已有一个文件选择器在运行，请先完成或取消它", null)
            return
        }
        // Activity 已销毁/正在结束时 startActivityForResult 会静默无效，
        // 这正是「点击没有任何反应」的常见原因，提前拦下并给出原因。
        if (activity.isFinishing || activity.isDestroyed) {
            result.error("activity_gone", "设置页面已关闭，请重新进入后再试", null)
            return
        }

        pickResult = result

        val candidates = listOf(
            // 首选：系统文档选择器（支持持久化读权限）
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
            },
            // 兜底：通用内容选择器（少数定制 ROM 没有 DocumentsUI）
            Intent(Intent.ACTION_GET_CONTENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
            // 再兜底：不限定类型（部分 ROM 对 */* + OPENABLE 组合处理异常）
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
        )

        val errors = mutableListOf<String>()
        for (intent in candidates) {
            val better = Intent(intent)
            better.putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            try {
                activity.startActivityForResult(better, REQ_PICK)
                Log.i(TAG, "picker launched: ${better.action}")
                return
            } catch (e: ActivityNotFoundException) {
                errors += "${better.action}: 系统没有可用的文件选择器"
                Log.w(TAG, "picker not found for ${better.action}", e)
            } catch (e: Exception) {
                errors += "${better.action}: ${e.javaClass.simpleName} ${e.message}"
                Log.w(TAG, "picker launch failed", e)
            }
        }

        pickResult = null
        result.error(
            "picker",
            "无法打开系统文件选择器（${errors.joinToString("；")}）",
            null,
        )
    }

    private fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQ_PICK) return false
        val pending = pickResult
        pickResult = null
        if (pending == null) return true

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            mainHandler.post { pending.success(null) } // 用户取消
            return true
        }
        val uri = data.data!!
        runAsync(pending) {
            try {
                activity.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: Exception) {
                // ACTION_GET_CONTENT 返回的 URI 不支持持久化，忽略
            }
            val name = queryDisplayName(uri) ?: "picked_backup.dt"
            val size = querySize(uri)
            mapOf(
                "id" to uri.toString(),
                "name" to name,
                "size" to size,
            )
        }
        return true
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            activity.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun querySize(uri: Uri): Long {
        return try {
            activity.contentResolver.query(
                uri, arrayOf(OpenableColumns.SIZE), null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) c.getLong(0) else 0L
            } ?: 0L
        } catch (_: Exception) {
            0L
        }
    }

    // ── 写入（三级兜底，任何一级成功即返回）───────────────

    private fun saveBackup(name: String, content: String): Map<String, Any> {
        if (name.isBlank()) throw IllegalArgumentException("备份文件名为空")
        if (content.isEmpty()) throw IllegalArgumentException("备份内容为空")

        val bytes = content.toByteArray(Charsets.UTF_8)
        val errors = mutableListOf<String>()

        // 1) MediaStore.Downloads（API 29+，无需权限）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                saveViaMediaStore(name, bytes)
                return mapOf("location" to "下载/$SUB_DIR/$name")
            } catch (e: Exception) {
                errors += "MediaStore（${e.message}）"
                Log.w(TAG, "saveViaMediaStore failed", e)
            }
        }

        // 2) 公共下载目录文件 API
        try {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                SUB_DIR,
            )
            if (!dir.exists() && !dir.mkdirs()) {
                throw IllegalStateException("无法创建目录 ${dir.absolutePath}")
            }
            File(dir, name).writeBytes(bytes)
            return mapOf("location" to "下载/$SUB_DIR/$name")
        } catch (e: Exception) {
            errors += "公共下载目录（${e.message}）"
            Log.w(TAG, "public downloads write failed", e)
        }

        // 3) 应用外部私有目录（必然可写，卸载会丢失）
        try {
            val dir = File(activity.getExternalFilesDir(null), SUB_DIR)
            if (!dir.exists() && !dir.mkdirs()) {
                throw IllegalStateException("无法创建目录 ${dir.absolutePath}")
            }
            File(dir, name).writeBytes(bytes)
            return mapOf(
                "location" to "应用私有目录/$SUB_DIR/$name（卸载后会丢失，建议改用 FTP 或云备份）",
            )
        } catch (e: Exception) {
            errors += "应用私有目录（${e.message}）"
            Log.e(TAG, "app private write failed", e)
        }

        throw IllegalStateException("三种存储位置均写入失败：${errors.joinToString("；")}")
    }

    private fun saveViaMediaStore(name: String, bytes: ByteArray) {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + "/" + SUB_DIR,
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("系统拒绝了写入请求（insert 返回空）")
        try {
            resolver.openOutputStream(uri)?.use { os ->
                os.write(bytes)
                os.flush()
            } ?: throw IllegalStateException("无法打开输出流")
        } finally {
            // 无论成功失败都要解除 pending，否则文件对用户不可见
            try {
                val done = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                resolver.update(uri, done, null, null)
            } catch (_: Exception) {
            }
        }
    }

    // ── 列举（四处扫描 + 去重）────────────────────────────

    private fun listBackups(): List<Map<String, Any>> {
        // 以文件名为 key 去重：MediaStore 与目录扫描可能命中同一份文件
        val merged = LinkedHashMap<String, Map<String, Any>>()

        // 1) MediaStore.Downloads 索引
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                queryMediaStoreDownloads().forEach { merged[it["name"] as String] = it }
            } catch (e: Exception) {
                Log.w(TAG, "queryMediaStoreDownloads failed", e)
            }
        }

        // 2) 目录直扫（部分 ROM 上 MediaStore 索引缺失，必须补扫）
        candidateDirs().forEach { dir ->
            try {
                dir.listFiles()
                    ?.filter { it.isFile && isBackupName(it.name) }
                    ?.forEach { f ->
                        merged.putIfAbsent(
                            f.name,
                            mapOf(
                                "id" to "file:${f.absolutePath}",
                                "name" to f.name,
                                "size" to f.length(),
                            ),
                        )
                    }
            } catch (e: Exception) {
                Log.w(TAG, "scan dir failed: ${dir.absolutePath}", e)
            }
        }

        // 按名称倒序（文件名含时间戳，新的在前）
        return merged.values.sortedByDescending { it["name"] as String }
    }

    private fun queryMediaStoreDownloads(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val resolver = activity.contentResolver
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
        )
        // 不加 selection：由代码侧过滤，避免 RELATIVE_PATH 在不同 ROM 上大小写/斜杠不一致
        resolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            null,
            null,
            "${MediaStore.MediaColumns.DATE_ADDED} DESC",
        )?.use { c ->
            val idIdx = c.getColumnIndex(MediaStore.MediaColumns._ID)
            val nameIdx = c.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeIdx = c.getColumnIndex(MediaStore.MediaColumns.SIZE)
            while (c.moveToNext()) {
                if (nameIdx < 0) continue
                val name = c.getString(nameIdx) ?: continue
                if (!isBackupName(name)) continue
                out.add(
                    mapOf(
                        "id" to if (idIdx >= 0) c.getLong(idIdx).toString() else "",
                        "name" to name,
                        "size" to if (sizeIdx >= 0) c.getLong(sizeIdx) else 0L,
                    )
                )
            }
        }
        return out
    }

    /** 所有可能存放备份的目录 */
    private fun candidateDirs(): List<File> {
        val dirs = mutableListOf<File>()
        try {
            dirs += File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                SUB_DIR,
            )
        } catch (_: Exception) {
        }
        try {
            activity.getExternalFilesDir(null)?.let { dirs += File(it, SUB_DIR) }
        } catch (_: Exception) {
        }
        try {
            dirs += File(activity.filesDir, SUB_DIR)
        } catch (_: Exception) {
        }
        // 2) 直属下载目录下的备份（用户手动移动过的情况）
        try {
            val downloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            dirs += downloads
        } catch (_: Exception) {
        }
        return dirs.distinctBy { it.absolutePath }
    }

    private fun isBackupName(name: String): Boolean =
        name.endsWith(".dt") || name.endsWith(".btk")

    // ── 读取 ─────────────────────────────────────────────

    private fun readBackup(id: String): String {
        if (id.isBlank()) throw IllegalArgumentException("备份标识为空")
        val bytes: ByteArray = when {
            id.startsWith("content:") -> {
                activity.contentResolver.openInputStream(Uri.parse(id))
                    ?.use { it.readBytes() }
                    ?: throw IllegalStateException("无法读取所选文件（可能已被移动或删除）")
            }
            id.startsWith("file:") -> {
                File(id.removePrefix("file:")).takeIf { it.exists() }
                    ?.readBytes()
                    ?: throw IllegalStateException("备份文件不存在或已被删除")
            }
            id.toLongOrNull() != null -> {
                val resolver = activity.contentResolver
                val uri = Uri.parse("content://media/external/downloads/$id")
                resolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IllegalStateException("备份文件不存在或已被删除")
            }
            else -> {
                // 旧版本可能直接传文件名：在所有候选目录中查找
                val found = candidateDirs()
                    .map { File(it, id) }
                    .firstOrNull { it.exists() }
                    ?: throw IllegalStateException("备份文件不存在：$id")
                found.readBytes()
            }
        }
        return String(bytes, Charsets.UTF_8)
    }

    private fun deleteBackup(id: String): Boolean {
        return try {
            when {
                id.startsWith("content:") -> {
                    activity.contentResolver.delete(Uri.parse(id), null, null) > 0
                }
                id.startsWith("file:") -> {
                    File(id.removePrefix("file:")).delete()
                }
                id.toLongOrNull() != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                    val uri = Uri.parse("content://media/external/downloads/$id")
                    activity.contentResolver.delete(uri, null, null) > 0
                }
                else -> {
                    candidateDirs().map { File(it, id) }.any { it.exists() && it.delete() }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "deleteBackup failed", e)
            false
        }
    }

    // ── 自检：把「哪一步坏了」直接告诉用户 ────────────────

    private fun selfTest(): Map<String, Any> {
        val info = mutableMapOf<String, Any>()
        info["channel"] = "ok"
        info["sdkInt"] = Build.VERSION.SDK_INT
        info["packageName"] = activity.packageName

        val dirs = candidateDirs()
        info["dirCount"] = dirs.size
        info["dirs"] = dirs.map { d ->
            val exists = d.exists()
            val writable = try {
                if (!exists) d.mkdirs()
                val probe = File(d, ".bodhi_probe")
                probe.writeText("x")
                probe.delete()
                true
            } catch (_: Exception) {
                false
            }
            "${d.absolutePath}|exists=$exists|writable=$writable|files=${if (exists) (d.listFiles()?.size ?: 0) else 0}"
        }

        // MediaStore 写入探针
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            info["mediaStore"] = try {
                val resolver = activity.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, ".bodhi_probe")
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/" + SUB_DIR,
                    )
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                if (uri == null) {
                    "insert 返回空（被系统拒绝）"
                } else {
                    resolver.delete(uri, null, null)
                    "ok（可写入）"
                }
            } catch (e: Exception) {
                "异常：${e.javaClass.simpleName} ${e.message}"
            }
        } else {
            info["mediaStore"] = "不适用（API ${Build.VERSION.SDK_INT} < 29）"
        }

        info["found"] = listBackups().map { it["name"] as String }
        return info
    }

    // ── 工具：后台线程执行，结果回主线程 ─────────────────

    private fun <T> runAsync(result: MethodChannel.Result, block: () -> T) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                Log.e(TAG, "${e.message}", e)
                mainHandler.post {
                    result.error("io", e.message ?: "本地备份操作失败", null)
                }
            }
        }.start()
    }
}
