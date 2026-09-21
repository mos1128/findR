/// 应用沙盒的**绝对路径唯一来源**。
///
/// core 只存**相对路径**（`files/cards/202609/<id>/01.webp`，见 `media/paths.dart`），
/// 绝对根目录一律在这里拼 —— 这样备份包才能跨设备还原（绝对路径里含沙盒前缀，换个安装就失效）。
/// 口径与 RN 版 `apps/mobile/src/platform/media.ts` 里的 `absFile()` 一致。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 全局唯一的两个根目录。
///
/// ⚠️ 必须在 `main()` 里 `await` 一次 [init]，之后**全程同步取用**：
/// core 的端口里有同步方法（`MediaIo.fileUri`），拿不到根目录就没法实现。
final class AppPaths {
  AppPaths._();

  static Directory? _documents;
  static Directory? _temp;

  /// 是否已初始化。界面可以据此决定先显示加载态还是直接上内容。
  static bool get ready => _documents != null && _temp != null;

  /// 文档目录：库文件、媒体文件都在它下面，**会随备份还原一起搬**。
  static Directory get documents => _require(_documents, 'documents');

  /// 临时目录：备份导出时的中转文件放这里（系统清理它无所谓），见 `backup.dart`。
  static Directory get temp => _require(_temp, 'temp');

  static Directory _require(Directory? dir, String what) {
    if (dir == null) {
      throw StateError('AppPaths 尚未 init() —— 应在 main() 里 await 一次（取 $what 失败）');
    }
    return dir;
  }

  /// 重复调用无副作用。
  static Future<void> init() async {
    _documents ??= await getApplicationDocumentsDirectory();
    _temp ??= await getTemporaryDirectory();
  }

  /// 直接把根目录钉死 —— **测试与桌面端用**。
  ///
  /// 有它，设备层那几项（真实库文件 / 媒体往返 / 打包往返）才能在 `flutter test`
  /// 里跑在临时目录上；否则那部分逻辑只能等上了真机才知道写没写对。
  static void initWith(Directory root) {
    _documents = root;
    _temp = Directory('${root.path}/.cache');
  }

  /// 只给测试用：把根目录清回去，免得用例之间互相污染。
  static void resetForTest() {
    _documents = null;
    _temp = null;
  }

  /// 相对路径 → 绝对路径。
  ///
  /// 刻意手拼而不引 `package:path`：只处理我们自己生成的、分隔符恒为 `/` 的相对路径，
  /// 而 `dart:io` 在 Windows 上也认 `/`。少一个依赖。
  static String abs(String rel) => '${documents.path}/${normalize(rel)}';

  static File file(String rel) => File(abs(rel));

  /// 相对路径的父目录（顶层文件返回 null）。
  static Directory? parentOf(String rel) {
    final parts = normalize(rel).split('/');
    if (parts.length <= 1) return null;
    parts.removeLast();
    return Directory('${documents.path}/${parts.join('/')}');
  }

  /// 去掉空段与 `.` / `..`：媒体相对路径来自数据库（乃至备份包），
  /// 不能让 `..` 把读写带到沙盒之外。
  static String normalize(String rel) =>
      rel.split('/').where((s) => s.isNotEmpty && s != '.' && s != '..').join('/');
}
