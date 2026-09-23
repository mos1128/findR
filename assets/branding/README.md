# 品牌素材（应用图标 / 启动图）

应用图标与启动图的素材，做发布收尾时直接取用。

**目前尚未接入**（`android/app/src/main/res/mipmap-*/ic_launcher.png` 仍是 Flutter 模板默认图）。
接入属于「发布收尾」那一步，见 `开发指南.md` 第七节。

## 文件

| 文件 | 尺寸 | 用途 |
|---|---|---|
| `icon.png` | 780 KB | 主图标（iOS / 通用，方形圆角） |
| `android-icon-foreground.png` | 77 KB | 安卓自适应图标 · 前景层 |
| `android-icon-background.png` | 17 KB | 安卓自适应图标 · 背景层 |
| `android-icon-monochrome.png` | 4 KB | 安卓自适应图标 · 单色层（Android 13+ 主题图标） |
| `splash-icon.png` | 3 KB | 启动图中间的那个图标 |

## 素材参数

- **应用名**：`Findr`
- **自适应图标背景色**：`#E6F4FE`
- **启动图背景色**：`#208AEF`
- **启动图图标宽度**：`76`（原始素材单位，Flutter 侧按实际分辨率换算）
- 图标为竖屏应用（`orientation: portrait`）

## 接入方式（将来做时二选一）

1. **用工具**：`flutter_launcher_icons` + `flutter_native_splash`，把上面参数填进 `pubspec.yaml` 的配置段，一条命令生成各档位图。
2. **手动**：按 Android 各密度档位（mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192 px）
   从 `icon.png` 缩放后替换 `android/app/src/main/res/mipmap-*/ic_launcher.png`；
   自适应图标另建 `mipmap-anydpi-v26/ic_launcher.xml`，引用前景/背景两张图；
   启动图改 `android/app/src/main/res/drawable/launch_background.xml`。

⚠️ 换图标**不需要**卸载重装（只有换签名才要），改完覆盖安装即可。
