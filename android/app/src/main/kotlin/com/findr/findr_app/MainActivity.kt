package com.findr.findr_app

import android.content.Intent
import android.net.Uri
import android.os.Build
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
/// ⚠️ 只做「拉起」不做「代替用户点」：**静默安装不存在**，这是 Android 的规矩，
/// 文档里也这么写（别让任何人以为这是 OTA）。
class MainActivity : FlutterActivity() {
    private val channelName = "findr/update"

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
}
