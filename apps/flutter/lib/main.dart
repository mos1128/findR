/// findR（Flutter 版）的临时入口。
///
/// 目前只挂 [SelfCheckScreen] —— 用来在**真机**上验证命门第 2 层
/// （打出 APK 的那份 SQLite 是否真的带 FTS5 + trigram）与设备层的几件事。
/// 真正的界面还没开始写（见 `Flutter迁移交接.md` §1「UI 直接在 Flutter 里重构」）。
library;

import 'package:flutter/material.dart';

import 'platform/app_paths.dart';
import 'selfcheck/self_check_screen.dart';

Future<void> main() async {
  // 取沙盒目录要走平台通道，必须先确保绑定就绪。
  WidgetsFlutterBinding.ensureInitialized();
  // 只在这里等一次；之后 core 的同步端口（如 fileUri）才能拿到绝对根目录。
  await AppPaths.init();
  runApp(const FindrApp());
}

class FindrApp extends StatelessWidget {
  const FindrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'findR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6EA5)),
        useMaterial3: true,
      ),
      home: const SelfCheckScreen(),
    );
  }
}
