/// 媒体文件的相对路径规则 —— 逐字对应 `packages/core/src/media/paths.ts`（35 行）。
///
/// 布局见技术设计二：**DB 只存相对路径，绝对根目录由平台层拼接**。
/// 这样备份包才能跨设备还原（绝对路径里含沙盒前缀，换个安装就失效）。
///
/// ⚠️ **这里的时间用「本地时间」，不是 `isoUtc()`** —— 与库里那些 ISO 时间列**不是一回事**：
/// 月份目录名只决定「文件放哪个文件夹」，TS 侧用的就是 `getFullYear()` / `getMonth()`
/// （**本地时区**）。若改成 UTC，跨月那几小时里拍的照片会落到上个月目录，
/// 与 RN 版已有文件对不上 ⇒ 备份包里的路径也就对不上了。
library;

import '../types.dart';

/// 形如 `202603`（本地时区的年月）。
String monthDir(DateTime date) {
  final y = date.year;
  final m = date.month.toString().padLeft(2, '0');
  return '$y$m';
}

String cardMediaDir(DateTime date, String cardId) => 'files/cards/${monthDir(date)}/$cardId';

/// `files/cards/<yyyymm>/<cardId>/01.webp` —— index 从 0 起、落到文件名是 01 起
/// （顺序即拍摄顺序）。
String imageRelPath(DateTime date, String cardId, int index, [String ext = 'webp']) =>
    '${cardMediaDir(date, cardId)}/${(index + 1).toString().padLeft(2, '0')}.$ext';

String audioRelPath(DateTime date, String cardId, [String ext = 'm4a']) =>
    'files/audio/${monthDir(date)}/$cardId.$ext';

/// 单卡图片超过该张数时提示确认（需求 5.1 的存储侧软约束，**不是硬截断**）。
const int maxCaptureImagesWarn = 12;

/// 回收某张卡片的全部媒体相对路径。
List<String> cardMediaPaths(MemoryCard card) {
  final paths = <String>[];
  if (card.images != null) paths.addAll(card.images!);
  if (card.audioPath != null) paths.add(card.audioPath!);
  return paths;
}

/// 录音时长下限：低于这个值基本是误触。
const int minRecordingMs = 500;
