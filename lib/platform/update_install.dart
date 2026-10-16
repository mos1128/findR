/// 「下载完之后的那几步」的设备侧动作：安装 APK、打开「安装未知应用」授权页、
/// 以及下载期间的保活通知。
///
/// **为什么单独一层**：这些都是 Android 的活（要 FileProvider、要前台服务），
/// 走一条自写的平台通道（Kotlin 侧在 `android/app/src/main/kotlin/.../MainActivity.kt`，
/// 通道名 `findr/update`）—— **不引第三方插件**：体积零增长、行为全可控，
/// 也不欠「插件停更」的债（桌面端将来复用同一份 core，只有这一层要各平台各写一份）。
///
/// **非 Android 平台（桌面 / 测试环境）**：通道不存在 ⇒ `installApk` 收成
/// [InstallOutcome.unavailable]、通知类调用变成空操作 —— 界面据此退到「浏览器下载」，
/// **不许因为装不上就崩**。
library;

import 'package:flutter/services.dart';

/// 安装结果四态：
/// - [started]：系统安装界面已拉起（用户装不装、装完没有，我们无从得知也不必知道）；
/// - [needPermission]：系统还没允许本 App「安装未知应用」，界面要引导去授权；
/// - [failed]：拉安装界面这一步就失败了（没有安装器、文件异常）；
/// - [unavailable]：平台上没有这条通道（桌面、测试）—— 界面只留浏览器下载。
enum InstallOutcome { started, needPermission, failed, unavailable }

/// 设备侧的更新动作。做成接口是为了测试能塞假实现（照 `ApiKeyStore` 的路子）。
abstract interface class UpdatePlatform {
  /// 拉起系统安装界面。**永远只是「拉起」** —— 静默安装不存在，这是 Android 的规矩。
  Future<InstallOutcome> installApk(String path);

  /// 打开系统的「安装未知应用」授权页。用户授权后返回，上层靠回前台事件自动重试安装。
  Future<void> openInstallSettings();

  /// 下载开始时挂一个前台服务 + 通知。**它的唯一目的是别让系统把 App 冻结/杀掉**，
  /// 于是切走、息屏也能接着下（下载本身仍跑在 Dart 侧，服务不搬数据）。
  Future<void> startKeepAlive(String title);

  /// 更新通知栏进度。[percent] 为 null 表示未知（不定态进度条）。
  Future<void> updateKeepAlive(int? percent);

  /// 结束保活。[ready] 为 true 时留一条「已下载，点此安装」的普通通知 ——
  /// 下载在后台完成时，用户得有个能点回来的入口。
  Future<void> stopKeepAlive({required bool ready});
}

/// 真实实现：把上面五个动作逐个映射到 `findr/update` 通道。
final class MethodChannelUpdatePlatform implements UpdatePlatform {
  const MethodChannelUpdatePlatform();

  static const MethodChannel _channel = MethodChannel('findr/update');

  @override
  Future<InstallOutcome> installApk(String path) async {
    try {
      final r = await _channel.invokeMethod<String>('installApk', <String, Object?>{'path': path});
      return switch (r) {
        'started' => InstallOutcome.started,
        'need_permission' => InstallOutcome.needPermission,
        _ => InstallOutcome.failed,
      };
    } on MissingPluginException {
      return InstallOutcome.unavailable;
    } catch (_) {
      // PlatformException 等：都算「这一步没成」，别把下载成果也搭进去
      return InstallOutcome.failed;
    }
  }

  @override
  Future<void> openInstallSettings() => _quietly('openInstallSettings');

  @override
  Future<void> startKeepAlive(String title) => _quietly('startKeepAlive', <String, Object?>{'title': title});

  @override
  Future<void> updateKeepAlive(int? percent) =>
      _quietly('updateKeepAlive', <String, Object?>{'percent': percent ?? -1});

  @override
  Future<void> stopKeepAlive({required bool ready}) => _quietly('stopKeepAlive', <String, Object?>{'ready': ready});

  /// 通知类调用一律「尽力而为」：有通知更好，没有不影响下载与安装本身。
  Future<void> _quietly(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // 平台没有这条通道（桌面/测试）或调用失败：静默跳过
    }
  }
}
