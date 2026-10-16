package com.daotuo.bodhi_token

import android.app.Activity
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
 * 备份文件（.dt / 旧 .btk）保存到公共「下载/菩提护令备份」目录，
 * 卸载重装后文件依然存在：
 *   - Android 10+（API 29+）：MediaStore.Downloads，无需存储权限
 *   - Android 9 及以下：Environment.DIRECTORY_DOWNLOADS 文件 API
 *     （无存储权限时退回应用私有目录，位置如实上报给 Dart 层）
 *
 * Dart 侧约定（lib/data/services/local_backup_service.dart）：
 *   saveBackup(name, content)  → { location: String }
 *   listBackups()              → [ { id, name, size } ]
 *   readBackup(id)             → String（文件文本内容）
 *   deleteBackup(id)           → bool
 *   pickBackup()               → { id, name, size }（SAF 文件选择器）
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
            "pickBackup" -> {
                if (pickResult != null) {
                    result.error("busy", "已有选择器在运行", null)
                    return
                }
                pickResult = result
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf(
                                "application/octet-stream",
                                "text/plain",
                                "application/x-binary",
                            ),
                        )
                    }
                    activity.startActivityForResult(intent, REQ_PICK)
                } catch (e: Exception) {
                    Log.e(TAG, "pickBackup launch failed", e)
                    pickResult = null
                    result.error("picker", "无法打开文件选择器：${e.message}", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    // ── 文件操作（后台线程执行）─────────────────────────

    private fun saveBackup(name: String, content: String): Map<String, Any> {
        if (name.isBlank() || content.isEmpty()) {
            throw IllegalArgumentException("name/content 为空")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/" + SUB_DIR,
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = activity.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore 写入被拒绝")
            resolver.openOutputStream(uri)?.use { os ->
                os.write(content.toByteArray(Charsets.UTF_8))
                os.flush()
            } ?: throw IllegalStateException("无法打开输出流")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return mapOf("location" to "下载/$SUB_DIR/$name")
        }

        // Android 9 及以下
        val publicDir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            SUB_DIR,
        )
        val target: File = if (publicDir.parentFile?.canWrite() == true || publicDir.mkdirs() || publicDir.isDirectory) {
            File(publicDir, name).also { f ->
                f.parentFile?.mkdirs()
                f.writeText(content, Charsets.UTF_8)
            }
        } else {
            // 无存储权限：退回应用私有目录（卸载会丢失，如实上报位置）
            File(activity.getExternalFilesDir(null), "$SUB_DIR/$name").apply {
                parentFile?.mkdirs()
                writeText(content, Charsets.UTF_8)
            }
        }
        return mapOf("location" to target.absolutePath)
    }

    private fun listBackups(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = activity.contentResolver
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
            )
            resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                arrayOf("%${Environment.DIRECTORY_DOWNLOADS}/$SUB_DIR%"),
                "${MediaStore.MediaColumns.DATE_ADDED} DESC",
            )?.use { c ->
                val idIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                while (c.moveToNext()) {
                    val name = c.getString(nameIdx) ?: continue
                    if (!isBackupName(name)) continue
                    out.add(
                        mapOf(
                            "id" to c.getLong(idIdx).toString(),
                            "name" to name,
                            "size" to c.getLong(sizeIdx),
                        )
                    )
                }
            }
            return out
        }

        val dirs = listOfNotNull(
            File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), SUB_DIR),
            activity.getExternalFilesDir("$SUB_DIR"),
        )
        for (dir in dirs) {
            dir.listFiles()?.filter { it.isFile && isBackupName(it.name) }?.forEach { f ->
                out.add(
                    mapOf(
                        "id" to "file:${f.absolutePath}",
                        "name" to f.name,
                        "size" to f.length(),
                    )
                )
            }
        }
        // 按名称倒序（文件名含时间戳）
        return out.sortedByDescending { it["name"] as String }
    }

    private fun readBackup(id: String): String {
        if (id.isBlank()) throw IllegalArgumentException("id 为空")
        val bytes: ByteArray = when {
            id.startsWith("content:") -> {
                activity.contentResolver.openInputStream(Uri.parse(id))
                    ?.use { it.readBytes() }
                    ?: throw IllegalStateException("无法读取所选文件")
            }
            id.toLongOrNull() != null -> {
                val resolver = activity.contentResolver
                val uri = Uri.parse(
                    "content://media/external/downloads/${id}"
                )
                resolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IllegalStateException("备份文件不存在或已被删除")
            }
            id.startsWith("file:") -> {
                File(id.removePrefix("file:")).takeIf { it.exists() }
                    ?.readBytes()
                    ?: throw IllegalStateException("备份文件不存在或已被删除")
            }
            else -> {
                // 旧版本可能直接传文件名：按名称在两个目录中查找
                val candidates = listOf(
                    File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "$SUB_DIR/$id"),
                    activity.getExternalFilesDir("$SUB_DIR")?.let { File(it, id) },
                )
                val found = candidates.firstOrNull { it != null && it.exists() }
                    ?: throw IllegalStateException("备份文件不存在")
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
                id.toLongOrNull() != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                    val uri = Uri.parse("content://media/external/downloads/$id")
                    activity.contentResolver.delete(uri, null, null) > 0
                }
                else -> {
                    val path = id.removePrefix("file:")
                    File(path).delete()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "deleteBackup failed", e)
            false
        }
    }

    private fun isBackupName(name: String): Boolean =
        name.endsWith(".dt") || name.endsWith(".btk")

    // ── SAF 选择结果 ─────────────────────────────────────

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
