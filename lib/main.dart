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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'platform/app_paths.dart';
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

class FindrApp extends StatelessWidget {
  const FindrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'findR',
      debugShowCheckedModeBanner: false,
      theme: buildFindrTheme(Brightness.light),
      darkTheme: buildFindrTheme(Brightness.dark),
      // 跟系统走。暗色下那套令牌是配好对儿的，不存在「深底深字」。
      themeMode: ThemeMode.system,
      // 所有路由之上的一层：目前只有「更新下载」小图标（没在下载时它什么都不画）
      builder: (context, child) => Stack(
        children: <Widget>[
          ?child,
          const UpdateProgressPill(),
        ],
      ),
      home: const MemoryStreamScreen(),
    );
  }
}
