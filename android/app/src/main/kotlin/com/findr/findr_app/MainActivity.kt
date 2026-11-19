package com.findr.findr_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 应用内更新的设备侧动作（Dart 侧见 `lib/platform/update_install.dart`，通道名 `findr/update`）。
///
/// 三件 Android 专属的事只能在这里做：
///   1. **拉起系统安装界面** —— `file://` 从 API 24 起会被 FileUriExposedException 挡掉，
///      必须走 FileProvider 的 `content://` 并临时授权（FLAG_GRANT_READ_URI_PERMISSION）；
///   2. **打开「安装未知应用」授权页** —— Android 8.0 起装包要么用户点过允许、要么来这里开；
///      授权后用户返回，Dart 侧靠「回前台」事件自动重试安装（不用再点一次）；
///   3. **下载期间的保活前台服务** —— 见 [DownloadKeepAliveService]。
///
/// 另外挂了一条 `findr/app` 通道（Dart 侧 `lib/platform/app_settings.dart`）：
/// **打开本应用的系统设置页** —— 权限被「不再询问」永久拒绝后，系统不再弹权限框，
/// 只有这页能把开关打开，界面得有个能点的入口。
///
/// 还有一条 `findr/share` 通道：别的应用「分享到 Findr」时，把 `ACTION_SEND`
/// 里的文字和图片交给 Dart（Dart 侧 `lib/platform/inbound_share.dart`）。
///
/// 以及 `findr/audio` 通道：把录音解成裸 PCM 交给 Dart（见 [decodePcm]）。
///
/// ⚠️ 只做「拉起」不做「代替用户点」：**静默安装不存在**，这是 Android 的规矩，
/// 文档里也这么写（别让任何人以为这是 OTA）。
class MainActivity : FlutterActivity() {
    private val channelName = "findr/update"
    private val appChannelName = "findr/app"
    private val shareChannelName = "findr/share"
    private val audioChannelName = "findr/audio"

    private var shareChannel: MethodChannel? = null

    /// 冷启动时分享 intent 比 Dart 的 handler 先到 —— 先扣在这儿，等 `ready` 再递。
    private var pendingShare: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // configureFlutterEngine 在 super.onCreate 里已经跑过，通道此时可用
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> result.success(installApk(call.argument<String>("path")))
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(true)
                }
                "startKeepAlive" -> {
                    // Android 13+ 的通知权限：只关「通知看不看得见」，拒了下载照跑
                    DownloadKeepAliveService.requestNotificationPermissionIfNeeded(this)
                    DownloadKeepAliveService.start(this, call.argument<String>("title"))
                    result.success(true)
                }
                "updateKeepAlive" -> {
                    DownloadKeepAliveService.update(this, call.argument<Int>("percent") ?: -1)
                    result.success(true)
                }
                "stopKeepAlive" -> {
                    DownloadKeepAliveService.stop(this, call.argument<Boolean>("ready") == true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, appChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, audioChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "decodePcm" -> decodePcm(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, shareChannelName).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart 挂好 handler 之后回一句；扣着的分享在这里补发
                    "ready" -> {
                        pendingShare?.let {
                            invokeMethod("share", it)
                            pendingShare = null
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
            shareChannel = this
        }
    }

    /// 把录音解成裸 PCM（Dart 侧 `lib/platform/asr_audio.dart`）。
    ///
    /// 解码是同步的 MediaCodec 循环，十几秒录音要几十到上百毫秒 —— **不能占主线程**，
    /// 所以丢到普通线程上跑；`result` 回到主线程再交（MethodChannel 只认主线程）。
    private fun decodePcm(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("bad-args", "缺少录音路径", null)
            return
        }
        Thread {
            var payload: Map<String, Any>? = null
            var failure: String? = null
            try {
                payload = PcmDecoder.decode(path)
            } catch (e: Exception) {
                failure = e.message ?: "音频解码失败"
            }
            runOnUiThread {
                when {
                    failure != null -> result.error("decode-failed", failure, null)
                    payload == null -> result.error("no-audio-track", "这条录音里没有音频", null)
                    else -> result.success(payload)
                }
            }
        }.start()
    }

    /// 把一个 `ACTION_SEND` 变成「预填进首页录入条」。
    ///
    /// 只处理单张图 + 一段文字（微信 / 浏览器 / 相册的常规分享）。多图走
    /// `ACTION_SEND_MULTIPLE`，那是另一条 action，先不接 —— 接了也只是把
    /// 多张图一次性塞进录入条，用户还得自己删。
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_SEND) return
        // 同一个 Intent 实例会跟着 Activity 活很久（重建、返回前台），
        // 处理过就清掉 action，避免重复预填。
        intent.action = null

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        val path = if (intent.type?.startsWith("image/") == true) {
            val uri = @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            uri?.let { copyToCache(it) }
        } else {
            null
        }
        if (path == null && text.isNullOrEmpty()) return

        val payload = mapOf<String, Any?>(
            "text" to text,
            "paths" to if (path == null) emptyList<String>() else listOf(path),
        )
        val channel = shareChannel
        if (channel == null) pendingShare = payload else channel.invokeMethod("share", payload)
    }

    /// 分享进来的图片是别的应用的 `content://`，读权限只在这一个 Intent 的生命周期里有效 ——
    /// 必须现在就把字节拷进本应用 cache，否则保存时打开就是 SecurityException。
    private fun copyToCache(uri: Uri): String? = try {
        val dir = File(cacheDir, "share").apply { mkdirs() }
        val type = contentResolver.getType(uri) ?: "image/jpeg"
        val ext = type.substringAfter('/', "jpeg").let { if (it == "jpeg") "jpg" else it }
        val file = File(dir, "share_${System.currentTimeMillis()}.$ext")
        contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { out -> input.copyTo(out) }
        }
        if (file.length() > 0) file.absolutePath else null
    } catch (_: Exception) {
        // 源头应用已经撤权 / 文件已被删：这张图就没了，文字部分照常预填
        null
    }

    /// 返回 `"started"` / `"need_permission"` / `"failed"`（映射见 `platform/update_install.dart`）。
    private fun installApk(path: String?): String {
        if (path.isNullOrEmpty()) return "failed"
        // API 26 起才有「安装未知应用」这道开关；更低版本直接装
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            return "need_permission"
        }
        return try {
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            "started"
        } catch (_: Exception) {
            // 没有安装器 / 文件异常：界面会给「浏览器下载」的兜底
            "failed"
        }
    }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).setData(Uri.parse("package:$packageName")),
            )
        } catch (_: Exception) {
            // 个别 ROM 砍了这页：拉不起来就拉倒，用户也能自己去系统设置里找
        }
    }

    /// 打开本应用的「应用详情」页（权限开关都在这儿）。
    private fun openAppSettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(Uri.parse("package:$packageName")),
            )
        } catch (_: Exception) {
            // 同上：拉不起来就拉倒
        }
    }
}
