/// 设置页的统一兜底：运行时还没加载好 → 转圈；加载失败 → 错误原因 + 重试。
///
/// 各设置页原先都是 `if (rt == null) 转圈`，首次加载失败时会永久转圈、
/// 连一句出错原因都没有。这里把 loading 与 error 分开，error 留一个出口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/runtime.dart';
import '../theme/tokens.dart';
import 'kit.dart';

class RuntimeFallback extends ConsumerWidget {
  const RuntimeFallback({super.key, required this.title, required this.state});

  final String title;
  final AsyncValue<RuntimeState> state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = FindrColors.of(context);
    if (!state.hasError) {
      return Scaffold(
        appBar: FindrTopBar(title: title),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: FindrTopBar(title: title),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.four),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '读取设置失败',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.text,
                ),
              ),
              const SizedBox(height: Spacing.two),
              Text(
                plainError(state.error!),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.four),
              FindrButton(
                title: '重试',
                expand: false,
                onPressed: () => ref.invalidate(runtimeProvider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
