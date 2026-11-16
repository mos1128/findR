/// 跳到本应用的系统设置页。
///
/// **为什么需要它**：权限框只在「还没拒绝过」时弹出。用户点过「不再询问」、
/// 或拒过两次之后，系统直接返回「没授权」而不弹框 —— 这时唯一的路就是设置页，
/// 界面上必须有个能点的入口（否则用户只能自己去系统设置里翻）。
///
/// Kotlin 侧在 `android/app/src/main/kotlin/.../MainActivity.kt`，通道名 `findr/app`。
/// 非 Android（桌面 / 测试）没有这条通道 —— 静默跳过，不因为跳不过去而崩。
library;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('findr/app');

/// 打开「应用详情」页（权限开关都在那里）。**尽力而为**：个别 ROM 砍了这页就算了。
Future<void> openAppSettings() async {
  try {
    await _channel.invokeMethod<void>('openAppSettings');
  } catch (_) {
    // 通道不存在或系统拉不起来：用户仍可自己去系统设置里手动开
  }
}
