/// M0 的纯文本录入入口 —— 逐字对应 `packages/core/src/pipeline/ingest.ts`（15 行）。
///
/// 保留为薄封装以维持既有调用方与测试不变。
/// **新代码请直接用 `createDraft` + `advanceCard`**（界面要先把草稿渲染出来）。
library;

import '../types.dart';
import 'capture.dart';

Future<MemoryCard> ingestText(AdvanceDeps deps, {required String transcript}) =>
    ingestCapture(deps, CaptureInput(source: SourceKind.text, text: transcript));
