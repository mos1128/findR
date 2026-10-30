# Findr

**本地优先的长程记忆助手 | 拍照语音极速记 · 自然语言秒级查 · 数据全在手机**

[![Flutter](https://img.shields.io/badge/Flutter-3.47.5-blue.svg)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.13.4-0175C2.svg)](https://dart.dev/)
[![SQLite](https://img.shields.io/badge/SQLite-FTS5%20%2B%20trigram-003B57.svg)](https://www.sqlite.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 📖 简介

Findr 是一款手机端个人长程记忆与检索应用。解决三类低频但恼人的问题：**东西放哪忘了**、**临时待办记不住**、**复杂流程记不清**。

说一句、拍一张，剩下交给它整理 —— 自动分类、提取位置、梳理步骤，之后用一句大白话就能查回来。

记忆库留在手机里，模型用你自己的（BYOK）。没有账号、没有服务器、没有云同步。

---

## ✨ 特性

- 📸 **多模态录入** - 拍照 / 连拍 / 相册 / 语音 / 文字 / 纯文本文件，可同时使用（边拍边说）
- 🛡️ **先落盘后解析** - 素材立刻本地存储，断网也不丢；网络恢复后自动补跑
- 🧠 **AI 理解与结构化** - 自动提取实体、分类、位置层级、步骤清单，生成可检索的描述
- 🔍 **三级智能检索** - 本地字面检索（L1）→ 答案组织（L2）→ 建议裁决（L3），定位题与推理题分开处理
- 🏷️ **动态分类** - 三个开箱即用的预设分类，可自定义增删改
- 🌳 **位置树** - 由内容自动长出房间 → 家具 → 容器，也能手动改名、改选
- 💾 **完整备份** - 一键导出 / 导入，换机数据全回来
- 🔐 **模型全自配** - 支持 Anthropic / OpenAI 兼容 / OpenAI Responses（DeepSeek、通义等均可接），Key 存系统密钥库
- 🖼️ **图片分析开关** - 图片只当附件时关掉，省 token；事后可一键补分析
- 📱 **应用内更新** - 启动时自动检查（12 小时节流），设置入口红点提醒；Gitee / GitHub 双渠道，GitHub 可走加速（地址可在设置里自定义）、失败自动回原站；应用内下载并拉起安装界面

---

## 💡 功能说明

> 只对关键交互做释义，方便快速上手。

### 录入

- 底部一条输入条是唯一入口：`＋` 展开「拍照 / 连拍 · 相册 · 文本文件」，中间打字回车即存，右边长按录音、松手即存。
- 三类素材可以同时出现在一次录入里；纯文本文件与直接打字完全等价。
- 文本文件只支持 `txt / md / markdown / json / csv / tsv / log / yaml / yml` 九种扩展名，单文件上限 8000 字，超限明确拒绝而非静默截断（PDF / Word 请截图或复制文字进来）。
- **图片分析开关**：常驻在输入条上，有图片时出现。关掉后图片只存为附件、不送模型（省 token），但图中内容也就搜不到 —— 卡片会带「未分析」角标，随时可一键补分析。

### 检索

- 顶部搜索框输入一句大白话即可。「我护照放哪了」走本地定位，「出国玩该带哪些东西」走整库建议裁决。
- 定位题：模型先把问题翻译成检索条件，检索本身在本地执行（快、省、离线可用）；0 结果会逐级放宽条件再试，并明确告知「已放宽」。
- 推理题：把整库条目清单（按相关度排序后取前 200 条）交给模型用常识裁决，结果分三档 —— **必需 / 看情况 / 还缺什么**。
- 答案卡片**异步追加在结果列表下方**，不打断已渲染的列表。

### 整理

- 分类是唯一的组织维度，不携带任何字段约束；没有必填字段，位置与步骤由模型按内容判断。
- 解析成功即入库，没有「待确认」这一步。分类选不出、新建了位置层级，都不需要用户操作，详情页随时可改。
- 理解失败重试一次仍失败时，卡片保留原文并打「待整理」角标。

---

## 🚀 快速开始

### 方式一：直接安装（推荐）

1. 前往 [GitHub Releases](https://github.com/mos1128/findR/releases) 或 [Gitee 发行版](https://gitee.com/ms6/findR/releases) 下载最新的 `app-release.apk`。
2. 传到手机安装；首次需允许「安装未知应用」。
3. 打开 App → 设置 → 填入主 LLM 的协议 / 地址 / 模型名 / API Key → 点「探测」确认可用。

> **升级提示**：安装新版直接覆盖即可，数据保留。**别卸载** —— 记忆库在应用私有目录里，卸载会清空，除非先导出备份。

### 方式二：从源码构建

环境要求：Flutter 3.47.5（Dart 3.13.4）、Android SDK（本机出包时需要）。

```bash
# 安装依赖（仓库根执行一次即可，pub workspaces 统一解析）
flutter pub get

# 运行到已连接的设备
flutter run

# 本机出 release 包（需要 Android SDK 与签名配置；产物为 app-release.apk）
flutter build apk --target-platform android-arm64
```

> 正式发版不用本机构建：打 tag 后 CI 自动出包并发布到 GitHub + Gitee。
> 开发须知（环境、约束、发布流程、真机验收）见 [DEVELOPMENT.md](DEVELOPMENT.md)。

---

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

> 代码提交前请确保 `flutter analyze` 与 `flutter test` 均通过（基线：core 300 条 + app 129 条）。

---

**如果这个项目对你有帮助，请给一个 ⭐️ Star 支持一下！**
