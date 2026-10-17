package com.daotuo.bodhi_token

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 菩提护令 · 超级管理员本地校验引擎
 *
 * 安全设计：
 *   - APK 内**不含明文密码**，只存 PBKDF2-HMAC-SHA256 哈希
 *     （120,000 次迭代 + 固定盐），反编译 dex / so 也拿不到密码原文；
 *   - 校验在原生层完成，Dart 侧只拿到 true/false，
 *     Dart 内存快照 / 快照文件中不出现密码；
 *   - 校验通过后返回一次性会话令牌（内存随机数），
 *     后台管理接口调用时使用，令牌不落盘、应用退出即失效；
 *   - 连续输错 5 次锁定 5 分钟（防暴力枚举）。
 *
 * 客户端内置口令属于「设备侧防线」：
 * 能显著提高破解门槛，但理论上无法做到绝对不可破解——
 * 服务端管理接口另有独立的管理员哈希校验（见 服务端/user/config.php）。
 */
object AdminAuthEngine {

    private const val CHANNEL = "bodhi/admin_auth"

    // ── 内置管理员（哈希化存储，无明文） ──────────────────
    // username 明文本身不敏感，仅用于比对
    private const val ADMIN_USER = "admin"

    // PBKDF2 盐（hex）
    private val SALT = hexToBytes("b0d11a086f2c4e57")

    // PBKDF2("mM8633819", salt, 120000, 32) 的结果（hex）
    private val ADMIN_HASH =
        hexToBytes("0ce0d1eedb833e4cddf6b2c3e3134d0aca41bf40565d71f147212eac68415943")

    private const val ITERATIONS = 120000
    private const val KEY_LENGTH = 256

    // ── 防暴力破解 ────────────────────────────────────────
    private const val MAX_FAILS = 5
    private const val LOCK_MS = 5 * 60 * 1000L
    private var failCount = 0
    private var lockedUntil = 0L

    // 当前会话令牌（登录成功后生成，仅存内存）
    private var sessionToken: String? = null

    fun register(engine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "verify" -> {
                    val user = call.argument<String>("username") ?: ""
                    val pass = call.argument<String>("password") ?: ""
                    // PBKDF2 12 万次迭代较耗时，放后台线程执行
                    Thread {
                        try {
                            val token = verify(user, pass)
                            Handler(Looper.getMainLooper()).run {
                                result.success(mapOf("ok" to true, "token" to token))
                            }
                        } catch (e: AuthException) {
                            Handler(Looper.getMainLooper()).run {
                                result.error("auth_failed", e.message, null)
                            }
                        }
                    }.start()
                }
                "sessionToken" -> result.success(sessionToken)
                "logout" -> {
                    sessionToken = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** @return 成功返回会话令牌；失败抛出带原因的异常文案 */
    private fun verify(username: String, password: String): String {
        val now = System.currentTimeMillis()
        if (now < lockedUntil) {
            val remainSec = (lockedUntil - now) / 1000
            throw AuthException("尝试次数过多，请 ${remainSec / 60 + 1} 分钟后再试")
        }

        val userOk = username.trim() == ADMIN_USER
        val passOk = pbkdf2(password)!!.contentEquals(ADMIN_HASH)

        if (!userOk || !passOk) {
            failCount++
            if (failCount >= MAX_FAILS) {
                lockedUntil = System.currentTimeMillis() + LOCK_MS
                failCount = 0
                throw AuthException("连续错误次数过多，已临时锁定 5 分钟")
            }
            throw AuthException("管理员账号或密码不正确")
        }

        // 登录成功：重置计数，签发会话令牌
        failCount = 0
        lockedUntil = 0L
        sessionToken = java.util.UUID.randomUUID().toString().replace("-", "")
        return sessionToken!!
    }

    private fun pbkdf2(password: String): ByteArray? = try {
        val spec = javax.crypto.spec.PBEKeySpec(
            password.toCharArray(), SALT, ITERATIONS, KEY_LENGTH,
        )
        val factory = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        factory.generateSecret(spec).encoded
    } catch (_: Exception) {
        null
    }

    private fun hexToBytes(hex: String): ByteArray {
        val len = hex.length
        val out = ByteArray(len / 2)
        var i = 0
        while (i < len) {
            out[i / 2] = ((Character.digit(hex[i], 16) shl 4)
                + Character.digit(hex[i + 1], 16)).toByte()
            i += 2
        }
        return out
    }

    class AuthException(message: String) : Exception(message)
}
