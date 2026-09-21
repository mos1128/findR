/// JS `Date.prototype.toISOString()` 的等价物。
///
/// **格式是数据的一部分，不是显示细节。** 卡片的时间戳同时承担四个角色：
/// 库里的 TEXT 列、排序键（`ORDER BY created_at DESC`、`created_at >= ?`）、
/// 备份包里的字段、以及直接显示给用户的值。既有数据（真机库里、老备份包里）
/// 全是 `2026-03-01T00:00:00.000Z` 这个形状 ⇒ **必须继续产出同一形状**。
///
/// 为什么不能直接用 `DateTime.toIso8601String()`：它对本地时区的 DateTime 会输出
/// `2026-03-01T08:00:00.000+08:00` —— 带偏移量、没有 Z。形状一变，字符串比较（就是排序）
/// 跟着错，而且和库里已有的数据混在一起之后再也分不开。
///
/// 实现刻意「先转 UTC 再手拼」，而不是 `toUtc().toIso8601String()`：后者在毫秒之外的精度
/// 非 0 时会输出 6 位小数（`...000000Z`），与 JS 固定的 3 位对不上。
/// 顺带一提，JS 的 Date 只有毫秒精度，这里的微秒部分同样直接丢弃 —— 行为一致。
library;

/// 把 [time] 渲染成 `YYYY-MM-DDTHH:MM:SS.mmmZ`（UTC）。
String isoUtc(DateTime time) {
  final t = time.toUtc();
  final year = t.year.toString().padLeft(4, '0');
  final month = t.month.toString().padLeft(2, '0');
  final day = t.day.toString().padLeft(2, '0');
  final hour = t.hour.toString().padLeft(2, '0');
  final minute = t.minute.toString().padLeft(2, '0');
  final second = t.second.toString().padLeft(2, '0');
  final milli = t.millisecond.toString().padLeft(3, '0');
  return '$year-$month-${day}T$hour:$minute:$second.${milli}Z';
}
