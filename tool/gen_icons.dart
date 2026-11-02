// 生成应用图标与启动图的所有位图产物。
//
//   dart run tool/gen_icons.dart          # 在仓库根跑
//
// 设计稿固定在 **160 逻辑单位** 的方形画布上，所有输出都从这一个坐标系缩放 ——
// 改形状只改本文件顶部的常量，各密度、各尺寸自动跟着变，不会出现「某个档位没跟上」。
// 也正因为如此，安卓自适应图标的 108dp 画布刚好等于这 160 逻辑单位（1 单位 = 0.675dp）。
//
// ⚠️ 内容的**大小**另由 kContentScale 控制：安全区只有中心直径 66dp 的圆，
// 不缩会在圆形遮罩下被切掉最外环（详见该常量处的说明）。
//
// 图形：**一道缺口环 + 偏心点**，暖纸底 + 墨色图形。缺口落在右下方，
// 读作「一次扫到一半的检索」——环向外扩散、被截断在同一个方向。
//
// 产物（全部被 .gitignore 之外的真实文件，直接进版本库）：
//   android/app/src/main/res/mipmap-*/ic_launcher.png          传统方形图标（纸底圆角）
//   android/app/src/main/res/drawable-*/ic_launcher_foreground.png   自适应图标 · 前景
//   android/app/src/main/res/drawable-*/ic_launcher_monochrome.png   自适应图标 · 单色（Android 13+ 主题图标）
//   assets/branding/*.png                                      设计素材存档（含 1024 主图）
//
// 自适应图标的**背景层是渐变**，不生成位图：见 res/drawable/ic_launcher_background.xml
// （改色必须与顶部 kPaper0 / kPaper1 同步）。
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

// ---------------------------------------------------------------- 设计稿常量

/// 设计稿逻辑边长。安卓自适应图标的 108dp 画布恰好也映射到这个边长的方框：
/// 图形包围盒约 96/160 = 60%，而系统的安全区是 66/108 = 61% ⇒ 天然合规。
const double kDesign = 160;

/// 自适应图标画布（dp）。传统图标按各密度像素表缩放，不走这个。
const double kAdaptiveDp = 108;

/// 图标圆角（设计稿单位）。传统方形图标用，自适应图标由系统裁切、不用。
const double kCorner = 34;

/// 内容相对设计稿的整体缩放。
///
/// 图形只有一道环 + 一个点，最远像素在 40.4 单位（27.3dp），安全区半径 33dp ——
/// 留了将近 6dp 的余量。**这是刻意的**：之前那版把三道环铺满到 31.1dp，
/// 一屏图标里显得又挤又晕，加这一道留白是主要修正。
/// 想放大可以往上调，跑到 48.9 单位（33dp）就是极限，结尾的自检会打 ❌。
const double kContentScale = 1.0;

// 配色：暖纸底 + 墨色图形。启动屏（colors.xml 的 brand_paper）取纸色起点值。
const int kPaper0 = 0xF7F3EA; // 纸色渐变起点（左上）
const int kPaper1 = 0xE6DDCB; // 纸色渐变终点（右下）
const int kInk0 = 0x242019;   // 墨色渐变起点（左上）
const int kInk1 = 0x3D362B;   // 墨色渐变终点（右下）

/// 唯一那道缺口环的中轴半径。
///
/// 只用一道环是这一版的关键：三道同心环会让视线不断向内追，看着「晕」。
const double kRingR = 35.2;

/// 环的粗细。缩到 24px 时约 1.6px —— 再细就会在低密度屏上发虚。
const double kRingW = 10.4;

/// 缺口的角度区间（度，屏幕坐标：0° 朝右、正角朝下）——断口落在右下方。
const double kGapFrom = 15, kGapTo = 70;

/// 中心点：半径，以及相对圆心的偏移。
///
/// 点**故意偏离圆心**（往左上），正好落在缺口的对面。同心结构一旦被打破，
/// 眼睛就不会顺着环一圈圈打转 —— 这是「晕」的第二个修正点。
const double kDotR = 14.4, kDotX = -6.4, kDotY = -8.0;

// ---------------------------------------------------------------- 几何判定

/// 画布坐标 → 图形坐标：图形以 (0,0) 为中心，整体按 [kContentScale] 缩小后
/// 平移到画布中心。背景层铺满画布、不参与这个变换。
(double, double) _art(double x, double y) =>
    ((x - kDesign / 2) / kContentScale, (y - kDesign / 2) / kContentScale);

/// 圆角矩形内部判定（点 (x,y) 是否落在 [x1,y1]-[x2,y2]、圆角 r 内）。
bool _inRoundedRect(
  double x,
  double y,
  double x1,
  double y1,
  double x2,
  double y2,
  double r,
) {
  if (x < x1 || x > x2 || y < y1 || y > y2) return false;
  // 两个方向都在直边上 ⇒ 一定在内部
  if (x >= x1 + r && x <= x2 - r) return true;
  if (y >= y1 + r && y <= y2 - r) return true;
  // 落在四个圆角里：与最近的圆心比距离
  final cx = x < x1 + r ? x1 + r : x2 - r;
  final cy = y < y1 + r ? y1 + r : y2 - r;
  final dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

/// 缺口环：以原点为心、中轴半径 [r]、粗细 [w]，在 [kGapFrom, kGapTo] 这段角度上断开。
///
/// 断口两端是**圆头**而不是平切：平切会在环的端面留下两条径向直边，
/// 缩到 24px 时像被刀切掉一样生硬；圆头跟环的弧度是连续的。
bool _inRing(double x, double y, double r, double w) {
  final half = w / 2;
  final d = math.sqrt(x * x + y * y);
  final onBand = (d - r).abs() <= half;
  var a = math.atan2(y, x);
  if (a < 0) a += 2 * math.pi; // 归一到 0..2π，和缺口角度同一坐标系
  final g0 = kGapFrom * math.pi / 180;
  final g1 = kGapTo * math.pi / 180;
  if (onBand && !(a > g0 && a < g1)) return true;
  // 断口两端的圆头：即使角度落在缺口里，只要离端点够近仍然算环上
  for (final g in [g0, g1]) {
    final dx = x - r * math.cos(g), dy = y - r * math.sin(g);
    if (dx * dx + dy * dy <= half * half) return true;
  }
  return false;
}

/// 偏心点
bool _inDot(double x, double y) {
  final dx = x - kDotX, dy = y - kDotY;
  return dx * dx + dy * dy <= kDotR * kDotR;
}

/// 整个图形：一道缺口环 + 一个偏心的点。
bool _inMark(double x, double y) =>
    _inDot(x, y) || _inRing(x, y, kRingR, kRingW);

// ---------------------------------------------------------------- 渐变

/// 通道插值。t 已经是平滑过的 0..1。
int _mix(int a, int b, double t) {
  int ch(int shift) {
    final from = (a >> shift) & 0xFF, to = (b >> shift) & 0xFF;
    return (from + (to - from) * t).round();
  }

  return (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

/// smoothstep：线性插值在中段会显得「脏」一下，过一遍曲线更均匀。
double _ease(double t) {
  t = t.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// 纸色底：315° 对角渐变，铺满整张画布。
int _paper(double x, double y) =>
    _mix(kPaper0, kPaper1, _ease((x + y) / (2 * kDesign)));

/// 墨色图形：同一方向的对角渐变，让环有一点体积感而不是死平。
int _ink(double x, double y) {
  final (ax, ay) = _art(x, y);
  return _mix(kInk0, kInk1, _ease((ax + ay) / 120 + 0.5));
}

// ---------------------------------------------------------------- 逐像素着色

/// 返回 0xAARRGGBB；0 表示完全透明。
///
/// 整张图**逐像素求值**而不是「画一个形状、再画下一个」：抗锯齿由外层的超采样统一
/// 处理，环与底的交界自动带上半个像素的过渡，不会出现各自画各自导致的白边或硬边。
int _shade(double x, double y, {required bool background, required bool monochrome}) {
  if (monochrome) return _shadeMono(x, y);

  var has = false;
  var color = 0;

  if (background) {
    if (!_inRoundedRect(x, y, 0, 0, kDesign, kDesign, kCorner)) return 0;
    has = true;
    color = _paper(x, y);
  }

  final (ax, ay) = _art(x, y);
  if (_inMark(ax, ay)) {
    has = true;
    color = _ink(x, y);
  }

  if (!has) return 0;
  return 0xFF000000 | color;
}

/// 单色层（Android 13+ 主题图标）逐像素求值。
///
/// 系统会忽略这一层的颜色、只取**形状**再统一染色。这里直接把整个图形涂成同一个黑，
/// 形状本身（一道断口环 + 一个偏心的点）就足以立住。
int _shadeMono(double x, double y) {
  final (ax, ay) = _art(x, y);
  return _inMark(ax, ay) ? 0xFF000000 : 0;
}

// ---------------------------------------------------------------- 渲染与落盘

/// 渲染一张 size×size 的 PNG。`ss` 是超采样倍数：先在这个倍数下逐像素求值，
/// 再按 alpha 加权平均降采样，得到抗锯齿边缘（也顺便让曲线在任何尺寸下都平滑）。
void _render(
  String path,
  int size, {
  required bool background,
  required bool monochrome,
  int ss = 4,
}) {
  final out = img.Image(width: size, height: size, numChannels: 4);
  final samples = ss * ss;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var sumA = 0, sumR = 0, sumG = 0, sumB = 0;
      for (var sy = 0; sy < ss; sy++) {
        final ly = (y * ss + sy + 0.5) * kDesign / (size * ss);
        for (var sx = 0; sx < ss; sx++) {
          final lx = (x * ss + sx + 0.5) * kDesign / (size * ss);
          final c = _shade(lx, ly, background: background, monochrome: monochrome);
          final a = (c >> 24) & 0xFF;
          if (a == 0) continue;
          // 颜色按 alpha 加权累加 —— 否则边缘会被透明像素拖暗，出现一圈灰边
          sumR += ((c >> 16) & 0xFF) * a;
          sumG += ((c >> 8) & 0xFF) * a;
          sumB += (c & 0xFF) * a;
          sumA += a;
        }
      }
      if (sumA == 0) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
      } else {
        out.setPixelRgba(
          x,
          y,
          (sumR / sumA).round().clamp(0, 255),
          (sumG / sumA).round().clamp(0, 255),
          (sumB / sumA).round().clamp(0, 255),
          (sumA / samples).round().clamp(0, 255),
        );
      }
    }
  }

  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(img.encodePng(out, level: 9), flush: true);
  stdout.writeln('  $path  ($size×$size)');
}

/// 安卓密度档位 → 相对 mdpi 的倍数
const Map<String, double> _densities = {
  'mdpi': 1,
  'hdpi': 1.5,
  'xhdpi': 2,
  'xxhdpi': 3,
  'xxxhdpi': 4,
};

/// 内容包围圆自检：采样整张画布，取离画布中心最远的内容像素（不含背景层）。
///
/// 安卓自适应图标的安全区是中心直径 66dp 的圆（半径 33dp），遮罩的可视范围是中心
/// 72dp 见方；内容超出安全区，圆形遮罩就会切到它。每次生成后打一行结果，
/// 改 [kContentScale] 时可以直接看到有没有越界。
void _reportSafeZone() {
  const unitDp = kAdaptiveDp / kDesign; // 1 设计稿单位 = 0.675dp
  const safeDp = 33.0; // 安全区半径
  const visibleDp = 36.0; // 圆形遮罩的可视半径（72dp 见方内切圆）
  var maxD = 0.0;
  for (var y = 0.0; y <= kDesign; y += 0.25) {
    for (var x = 0.0; x <= kDesign; x += 0.25) {
      if (_shade(x, y, background: false, monochrome: false) == 0) continue;
      final dx = x - kDesign / 2, dy = y - kDesign / 2;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > maxD) maxD = d;
    }
  }
  final dp = maxD * unitDp;
  final ok = dp <= safeDp;
  stdout.writeln(
    '内容包围圆半径 ${maxD.toStringAsFixed(1)} 单位 = ${dp.toStringAsFixed(1)} dp'
    '（安全区 ${safeDp.toStringAsFixed(0)} dp / 遮罩可视 ${visibleDp.toStringAsFixed(0)} dp）'
    '${ok ? '  ✅ 在安全区内' : '  ❌ 超出安全区，圆形遮罩会切到内容！'}',
  );
}

void main() {
  const res = 'android/app/src/main/res';

  stdout.writeln('传统方形图标（蓝底圆角，API < 26 与部分启动器用）');
  _densities.forEach((density, scale) {
    _render(
      '$res/mipmap-$density/ic_launcher.png',
      (48 * scale).round(),
      background: true,
      monochrome: false,
    );
  });

  stdout.writeln('自适应图标 · 前景（透明底，图形落在安全区内）');
  _densities.forEach((density, scale) {
    _render(
      '$res/drawable-$density/ic_launcher_foreground.png',
      (kAdaptiveDp * scale).round(),
      background: false,
      monochrome: false,
    );
  });

  stdout.writeln('自适应图标 · 单色（Android 13+ 主题图标）');
  _densities.forEach((density, scale) {
    _render(
      '$res/drawable-$density/ic_launcher_monochrome.png',
      (kAdaptiveDp * scale).round(),
      background: false,
      monochrome: true,
    );
  });

  stdout.writeln('设计素材存档（assets/branding/）');
  // 主图给到 1024：超采样降到 2 倍，否则这里会跑掉一多半时间，而 1024 上 2 倍已经看不出锯齿
  _render('assets/branding/icon.png', 1024, background: true, monochrome: false, ss: 2);
  _render('assets/branding/android-icon-foreground.png', 432,
      background: false, monochrome: false);
  _render('assets/branding/android-icon-background.png', 432,
      background: true, monochrome: false, ss: 2);
  _render('assets/branding/android-icon-monochrome.png', 432,
      background: false, monochrome: true);
  _render('assets/branding/splash-icon.png', 216, background: false, monochrome: false);

  _reportSafeZone();
  stdout.writeln('完成。');
}
