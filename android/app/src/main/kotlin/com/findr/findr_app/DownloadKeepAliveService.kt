package com.findr.findr_app

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/// 下载更新包期间的「保活」前台服务。
///
/// ⚠️ **它不下载**：下载仍是 Dart 侧在做（同一个进程）。这个服务只干一件事 ——
/// 让系统知道「这个 App 正在做用户看得见的事」，于是切到别的应用、息屏时不被冻结/回收，
/// 几十兆的包能一口气下完。代价是必须挂一条通知（Android 对前台服务的硬要求），
/// 这条通知正好当「后台进度」用。
///
/// 三个约定：
///   1. 结束前台服务用 [stop]；`ready = true` 时换一条**可点**的
///      「更新已下载 · 点此安装」通知（另外的 id）—— 后台完成时用户总得有个入口；
///   2. 通知权限（Android 13+）被拒时一切照跑，只是通知看不见 —— 别在这里做任何阻断；
///   3. 划掉 App 时服务一起没了（START_NOT_STICKY）：Dart 侧的下载也没了，
///      但 `.part` 留着，下次更新会自动续传（见 `lib/platform/update.dart`）。
class DownloadKeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "update_download"
        private const val PROGRESS_ID = 0x4644
        private const val READY_ID = 0x4645
        private const val REQUEST_NOTIFICATIONS = 0x4646
        private const val ACTION_START = "com.findr.findr_app.update.START"
        private const val DEFAULT_TITLE = "正在下载 Findr 更新"

        @Volatile private var running = false
        @Volatile private var title = DEFAULT_TITLE

        fun start(context: Context, title: String?) {
            this.title = title?.takeIf { it.isNotBlank() } ?: DEFAULT_TITLE
            val intent = Intent(context, DownloadKeepAliveService::class.java).setAction(ACTION_START)
            ContextCompat.startForegroundService(context, intent)
        }

        /// 下载中的进度刷新。服务没在跑就什么都不做（通知也不存在）。
        /// 用同一个 [PROGRESS_ID] 覆盖前台服务自己那条通知 —— 平台允许这么做。
        fun update(context: Context, percent: Int) {
            if (!running) return
            try {
                NotificationManagerCompat.from(context).notify(PROGRESS_ID, progressNotification(context, title, percent))
            } catch (_: Exception) {
                // 通知失败不影响下载
            }
        }

        /// 结束保活；[ready] 表示下载成功，换一条可点的「已下载」通知。
        fun stop(context: Context, ready: Boolean) {
            try {
                context.stopService(Intent(context, DownloadKeepAliveService::class.java))
            } catch (_: Exception) {
                // 服务本来就不在跑：无所谓
            }
            running = false
            if (!ready) return
            try {
                NotificationManagerCompat.from(context).notify(READY_ID, readyNotification(context))
            } catch (_: Exception) {
                // 没有通知权限：忽略，App 内的小图标仍然会提示可安装
            }
        }

        /// Android 13+ 才要问。**拒了不阻断**：下载与安装都不依赖通知。
        fun requestNotificationPermissionIfNeeded(activity: Activity) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
            val granted = ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (granted) return
            ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(CHANNEL_ID, "更新下载", NotificationManager.IMPORTANCE_LOW).apply {
                description = "下载更新安装包时的进度提示"
            }
            nm.createNotificationChannel(channel)
        }

        private fun progressNotification(context: Context, title: String, percent: Int): Notification {
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
            if (percent in 0..100) {
                builder.setProgress(100, percent, false).setContentText("$percent%")
            } else {
                builder.setProgress(0, 0, true).setContentText("下载中…")
            }
            return builder.build()
        }

        private fun readyNotification(context: Context): Notification {
            val open = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val pending = PendingIntent.getActivity(
                context,
                0,
                open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("更新已下载")
                .setContentText("点此打开 Findr 完成安装")
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        running = true
        ensureChannel(this)
        startForegroundCompat(-1)
        // 不自动重启：进程被杀，Dart 侧的下载也一并没了，重启一个空服务没有意义
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        try {
            NotificationManagerCompat.from(this).cancel(PROGRESS_ID)
        } catch (_: Exception) {
            // 通知本来就不在：无所谓
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat(percent: Int) {
        // Android 14+ 起必须声明并带上类型（清单里 dataSync）；低版本传 0 即可
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, PROGRESS_ID, progressNotification(this, title, percent), type)
    }
}
