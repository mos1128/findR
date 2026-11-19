/// 录音失败的那一个弹窗。
///
/// 两个入口共用：录入坞的长按录音、搜索页的语音搜索。同一个权限问题在 App 里
/// 说两种话，用户会以为是两件事 —— 所以文案、按钮、字重都必须从这里出。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/app_settings.dart';
import '../theme/tokens.dart';
import 'recorder.dart';

Future<void> showRecordAlert(BuildContext context, RecorderError error) async {
  final c = FindrColors.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      title: Text(
        '无法录音',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: c.text,
        ),
      ),
      content: Text(
        error.message,
        style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
      ),
      actions: error.permission
          // 系统权限框只在「还没拒绝过」时弹；点过「不再询问」之后只剩设置页这一条路
          ? <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('取消', style: TextStyle(color: c.textSecondary)),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  unawaited(openAppSettings());
                },
                child: Text(
                  '去设置',
                  style: TextStyle(
                    color: c.record,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]
          : <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  '知道了',
                  style: TextStyle(
                    color: c.record,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
    ),
  );
}
