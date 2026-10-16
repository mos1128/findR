// 生成应用图标与启动图的所有位图产物。
//
//   dart run tool/gen_icons.dart          # 在仓库根跑
//
// 设计稿固定在 **160 逻辑单位** 的方形画布上，所有输出都从这一个坐标系缩放 ——
// 改形状只改本文件顶部的常量，各密度、各尺寸自动跟着变，不会出现「某个档位没跟上」。
// 也正因为如此，安卓自适应图标的 108dp 画布刚好等于这 160 逻辑单位（1 单位 = 0.675dp）。
//
// ⚠️ 内容的**大小**另由 kContentScale 控制：安全区只有中心直径 66dp 的圆，
// 不缩会在圆形遮罩下被切掉卡片的四个角（详见该常量处的说明）。
//
// 产物（全部被 .gitignore 之外的真实文件，直接进版本库）：
//   android/app/src/main/res/mipmap-*/ic_launcher.png          传统方形图标（蓝底圆角）
//   android/app/src/main/res/drawable-*/ic_launcher_foreground.png   自适应图标 · 前景
//   android/app/src/main/res/drawable-*/ic_launcher_monochrome.png   自适应图标 · 单色（Android 13+ 主题图标）
//   assets/branding/*.png                                      设计素材存档（含 1024 主图）
//
// 自适应图标的**背景层是纯色**，不生成位图：见 res/values/ic_launcher_background.xml。
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

/// 内容（卡片 + 定位针）相对设计稿的整体缩放。
///
/// 为什么必须缩：画布是 108dp，但**任何厂商的遮罩都切不到的，只有中心直径 66dp 的圆**
/// （半径 33dp = 本设计稿的 48.9 单位）。设计稿里卡片 100×86 单位，四角离中心 60~65 单位，
/// 不缩的话圆形遮罩（多数国产 ROM 的圆形图标）会把卡片四个角各切掉一块，卡片就不像卡片了。
///
/// 缩放同时会把**卡片几何中心对齐到画布中心**（画稿里卡片偏下，中心在 y=89 而非 80），
/// 否则缩完仍会整体偏出一截 —— 这两件事必须一起做，只缩不居中照样越界。
///
/// 想改回「更大更满」的样子，把这里调大即可；调完跑一次本脚本，
/// 结尾会把内容包围圆的实际半径打出来，超过 48.9 就是又出安全区了。
const double kContentScale = 0.72;

// 配色：与启动图、README 里记录的品牌参数保持一致
const int kBlue = 0x208AEF;
const int kWhite = 0xFFFFFF;
const int kOrange = 0xFFB25E;
const int kLine = 0xB5D4F4;

// 记忆卡片
const double kCardX1 = 30, kCardY1 = 46, kCardX2 = 130, kCardY2 = 132, kCardR = 14;
// 卡片上的三条内容线（x1, y1, x2, y2），高 7
const List<List<double>> kLines = [
  [44, 64, 94, 71],
  [44, 80, 114, 87],
  [44, 96, 82, 103],
];
// 定位针：圆心 + 头部半径 + 针尖到圆心的距离
const double kPinCX = 114, kPinCY = 56, kPinR = 20, kPinD = 32;
/// 针孔半径（定位针头部中心的镂空）
const double kPinHoleR = 8.5;

// 单色层（Android 13+ 主题图标）专用参数。这一层只有形状有意义，结构全靠「留白」表达 =>
// 卡片改画描边（内部透明），定位针保持实心，两者交界处再留一圈空隙把它们分开。
/// 单色层里卡片描边的粗细
const double kMonoStroke = 13;
/// 单色层里定位针周围留出的空隙宽度
const double kMonoGap = 5;

// ---------------------------------------------------------------- 几何判定

/// 画布坐标 → 内容坐标：把卡片与定位针整体按 [kContentScale] 缩小，
/// 并把卡片几何中心对齐到画布中心。背景层铺满画布、不参与这个变换，
/// 所以背景那条分支仍用原始坐标。
(double, double) _art(double x, double y) {
  final mx = (kCardX1 + kCardX2) / 2, my = (kCardY1 + kCardY2) / 2;
  return (mx + (x - kDesign / 2) / kContentScale, my + (y - kDesign / 2) / kContentScale);
}

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

/// 定位针内部判定：上半是头部圆，下半是两条切线收拢到针尖的锥形。
///
/// `grow` 把整枚针向外「胖」出一圈（画描边空隙用）。水滴形由「头部圆弧 + 两条切线 +
/// 针尖」构成，切点是圆弧与直线的衔接处，必须按当前半径算准，否则头部和针身之间会出现折角；
/// 放胖之后半径、针长都变了，切点要跟着重新算。
bool _inPin(double x, double y, [double grow = 0]) {
  final r = kPinR + grow, d = kPinD + grow;
  // 切点的纵坐标（r²/d）与横坐标
  final ty = r * r / d;
  final tx = r * math.sqrt(d * d - r * r) / d;
  final lx = x - kPinCX, ly = y - kPinCY;
  if (ly <= ty) {
    return lx * lx + ly * ly <= r * r;
  }
  if (ly > d) return false;
  // 该高度上锥形的半宽，随 y 线性收拢到 0
  final halfWidth = tx * (d - ly) / (d - ty);
  return lx.abs() <= halfWidth;
}

/// 针孔（透明/白色的小圆）
bool _inPinHole(double x, double y) {
  final lx = x - kPinCX, ly = y - kPinCY;
  return lx * lx + ly * ly <= kPinHoleR * kPinHoleR;
}

// ---------------------------------------------------------------- 逐像素着色

/// 返回 0xAARRGGBB；0 表示完全透明。
///
/// 整张图**逐像素求值**而不是「画一个形状、再画下一个」：抗锯齿由外层的超采样统一
/// 处理，形状之间的一切交界（白卡压在蓝底上、定位针压在卡片上）自动带上半个像素的过渡，
/// 不会出现各自画各自导致的白边或硬边。
int _shade(double x, double y, {required bool background, required bool monochrome}) {
  if (monochrome) return _shadeMono(x, y);

  var has = false;
  var color = 0;

  if (background) {
    if (!_inRoundedRect(x, y, 0, 0, kDesign, kDesign, kCorner)) return 0;
    has = true;
    color = kBlue;
  }

  // 卡片、内容线、定位针都在「内容坐标」里判定（背景层不缩，故用原始坐标）
  final (ax, ay) = _art(x, y);

  if (_inRoundedRect(ax, ay, kCardX1, kCardY1, kCardX2, kCardY2, kCardR)) {
    has = true;
    color = kWhite;
  }

  if (has) {
    for (final l in kLines) {
      if (_inRoundedRect(ax, ay, l[0], l[1], l[2], l[3], 3.5)) {
        color = kLine;
        break;
      }
    }
  }

  if (_inPin(ax, ay)) {
    has = true;
    color = kOrange;
  }

  if (!has) return 0;
  if (color == kOrange && _inPinHole(ax, ay)) return 0xFFFFFFFF;
  return 0xFF000000 | color;
}

/// 单色层（Android 13+ 主题图标）逐像素求值。
///
/// 系统会忽略这一层的颜色、只取**形状**再统一染色 —— 所以结构只能靠「哪里留白」表达。
/// 若照彩色稿那样把卡片画成实心，它和压在上面的定位针就是同一种颜色、还彼此重叠，
/// 结果必然糊成一整块实心色块（只剩针孔一个小缺口），看不出是个什么东西。
///
/// 这里的画法：卡片改画**描边**（内部透明），定位针保持实心，并在两者交界处留一圈空隙
/// —— 于是「一张卡片上别着一枚定位针」这个结构，在只剩一种颜色时依然立得住。
int _shadeMono(double x, double y) {
  final (ax, ay) = _art(x, y);

  // 定位针：实心，针孔镂空（针孔是这枚针唯一的识别特征，必须留着）
  if (_inPin(ax, ay)) return _inPinHole(ax, ay) ? 0 : 0xFF000000;

  // 卡片：外框以内、内框以外的那一圈才是描边，中间全留白
  if (!_inRoundedRect(ax, ay, kCardX1, kCardY1, kCardX2, kCardY2, kCardR)) return 0;
  final inner = _inRoundedRect(
    ax,
    ay,
    kCardX1 + kMonoStroke,
    kCardY1 + kMonoStroke,
    kCardX2 - kMonoStroke,
    kCardY2 - kMonoStroke,
    kCardR - kMonoStroke,
  );
  if (inner) return 0;

  // 定位针脚下那一圈空隙，把针和卡片描边切开
  if (_inPin(ax, ay, kMonoGap)) return 0;

  return 0xFF000000;
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
