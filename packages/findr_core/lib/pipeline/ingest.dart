/// 纯文本录入入口。
///
/// 保留为薄封装以维持既有调用方与测试不变。
/// **新代码请直接用 `createDraft` + `advanceCard`**（界面要先把草稿渲染出来）。
library;

import '../types.dart';
import 'capture.dart';

Future<MemoryCard> ingestText(AdvanceDeps deps, {required String transcript}) =>
    ingestCapture(deps, CaptureInput(source: SourceKind.text, text: transcript));
