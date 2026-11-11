/// findR（Flutter 版）的入口。
///
/// 现在挂的是真正的首页 [MemoryStreamScreen]（上「查」下「记」），
/// 自检屏已挪进「设置 → 维护 → 打开自检」——它在真机上仍然是验证命门第 2 层的载体。
///
/// 启动顺序只有一件必须先做的事：**取沙盒目录**。它要走平台通道，
/// 所以 `main()` 要 `await` 一次；之后 core 的同步端口（如 `MediaIo.fileUri`）才能拿到绝对根目录。
///
/// **`builder` 里那层 Stack**：全局的「更新下载」小图标（[UpdateProgressPill]）——
/// 它必须活在所有路由之上（下载从设置页发起，用户随即去干别的），所以挂这里而不是 `home`。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'platform/app_paths.dart';
import 'platform/runtime.dart';
import 'screens/memory_stream_screen.dart';
import 'theme/tokens.dart';
import 'ui/update_pill.dart';

Future<void> main() async {
  // 取沙盒目录要走平台通道，必须先确保绑定就绪。
  WidgetsFlutterBinding.ensureInitialized();
  // 只在这里等一次；之后一切路径都走同步的 AppPaths。
  await AppPaths.init();
  runApp(const ProviderScope(child: FindrApp()));
}

class FindrApp extends ConsumerWidget {
  const FindrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 运行时还没加载好时按「跟随系统」—— 这也是加主题设置之前的行为。
    final appearance =
        ref.watch(runtimeProvider).value?.appearance ??
        defaultAppearanceSettings;
    return MaterialApp(
      title: 'findR',
      debugShowCheckedModeBanner: false,
      // 界面只有中文。不配这一段时，长按输入框的「剪切 / 复制 / 粘贴」
      // 和系统组件的语义文案会回落到英文（DefaultMaterialLocalizations）。
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildFindrTheme(Brightness.light),
      darkTheme: buildFindrTheme(Brightness.dark),
      // 用户在「设置 → 外观」里选：跟随系统 / 亮色 / 暗色。
      themeMode: switch (appearance.themeMode) {
        ThemeModePreference.dark => ThemeMode.dark,
        ThemeModePreference.light => ThemeMode.light,
        ThemeModePreference.system => ThemeMode.system,
      },
      // 所有路由之上的一层：目前只有「更新下载」小图标（没在下载时它什么都不画）。
      // 同时把系统字号上限钳到 1.3×：录入坞与顶栏有大量固定高度，
      // 2.0× 时文字会被裁掉（工具型 App 用 1.3× 是明确取舍）。
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Stack(children: <Widget>[?child, const UpdateProgressPill()]),
      ),
      home: const MemoryStreamScreen(),
    );
  }
}
