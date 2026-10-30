# Findr

本地优先的长程记忆助手。拍照/语音极速记，自然语言秒级查。

## 快速开始

```bash
# 安装依赖
flutter pub get

# 开发
flutter analyze
flutter test
flutter run

# 发版
bash release.sh
```

详细开发指南见 [DEVELOPMENT.md](DEVELOPMENT.md)

## 架构

- 根目录 = Flutter app（界面 + 平台接线）
- `packages/findr_core/` = 纯 Dart 核心逻辑（零 Flutter 依赖）
- pub workspaces 统一依赖解析

## 核心特性

- 📸 多模态录入（拍照/语音/文字），先落盘后解析
- 🧠 AI 自动理解与结构化（分类/位置/步骤）
- 🔍 三级智能检索（本地定位/答案组织/建议裁决）
- 🏠 数据全在手机，模型自己配（BYOK）
- 💾 完整备份导出/导入
- 📱 应用内更新（双渠道：GitHub + Gitee）

## 许可

MIT License
