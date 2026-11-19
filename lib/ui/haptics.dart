/// 触觉反馈的唯一入口。
///
/// 只有「手指按下去有物理结果」的动作才配震动：录音起止、存入成功、删除确认、长按弹出菜单。
/// 滚动、翻页、开关统统一律不震 —— 满屏都在震等于没有反馈。
library;

import 'package:flutter/services.dart';

/// 轻点级：长按弹出菜单、开关切换。
void hapticTap() => HapticFeedback.selectionClick();

/// 按住级：录音开始/结束。
void hapticHold() => HapticFeedback.mediumImpact();

/// 成功级：一条记忆真的落库了。
void hapticSuccess() => HapticFeedback.lightImpact();

/// 警告级：删除确认、录音取消。
void hapticWarn() => HapticFeedback.heavyImpact();
