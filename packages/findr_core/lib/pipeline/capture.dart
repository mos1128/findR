/// 录入流程的编排 —— 逐字对应 `packages/core/src/pipeline/capture.ts`（326 行）。
///
/// 一条链路：**草稿（纯 DB，不碰网络）→ 转写 → 理解（一次模型调用）→ 落库**。
/// 所有失败都保持素材可重试，**绝不静默丢弃**（需求四、九）。
///
/// Dart 侧的对应关系：
/// - TS 的 union 类型（`UnderstandingResult` / `AdvanceOutcome`）⇒ sealed class + enum，
///   下游 `switch` 是穷尽检查的；
/// - TS 的 `deps: Pick<AdvanceDeps,'db'|'now'>`（结构化子类型）⇒ Dart 没有结构化类型，
///   所以 [createDraft] 直接收 `SqliteDriver` 与一个可选的时钟，**效果相同**：
///   建草稿不需要 llm / cfg，就不该逼调用方准备它们。
library;

import '../db/driver.dart';
import '../db/repository.dart';
import '../parse/model_json.dart';
import '../parse/outputs.dart';
import '../parse/schema.dart';
import '../prompts/render.dart';
import '../providers/media.dart';
import '../providers/types.dart';
import '../types.dart';
import '../util/iso.dart';

/// 单卡送模型分析的图片上限。需求把「可配 N 张」列为非 MVP，这里是固定的请求体护栏。
const int defaultMaxAnalyzeImages = 6;

/// 音频容器：录音直出 m4a/AAC，不转码（技术设计二）。
const String audioMime = 'audio/m4a';

/// 推进卡片需要的一切外部件。
final class AdvanceDeps {
  const AdvanceDeps({
    required this.db,
    required this.llm,
    required this.cfg,
    this.media,
    this.asr,
    this.asrCfg,
    this.visionSupported,
    this.hotwords,
    this.now,
    this.idGen,
    this.maxAnalyzeImages,
  });

  final SqliteDriver db;
  final LlmProviderAdapter llm;
  final ProviderConfig cfg;

  /// 只有需要读图/读音频时才用到；纯文本链路可以不传。
  final MediaIo? media;

  final AsrProviderAdapter? asr;
  final ProviderConfig? asrCfg;

  /// 主模型是否支持图片输入；false 时图片只作附件（需求 3.3）。缺省视为支持。
  final bool? visionSupported;

  /// 模式 2 的 ASR 热词（房间名 + 常用物品名）。
  final List<String>? hotwords;

  final DateTime Function()? now;
  final String Function()? idGen;
  final int? maxAnalyzeImages;

  /// TS 到处写 `deps.now ?? (() => new Date())`，Dart 里由它统一兜住。
  DateTime Function() get clock => now ?? DateTime.now;

  /// TS 到处写 `deps.idGen ?? makeId`。
  String Function() get idGenerator => idGen ?? makeId;

  /// 只换 [hotwords]，其余原样。
  ///
  /// 对应 TS 的 `{ ...deps, hotwords }`（`pipeline/queue.ts` 的批量补转写用它注入热词）。
  /// **刻意不做通用的 `copyWith`**：这里有十几项可选字段，通用版得靠哨兵区分
  /// 「不改」与「改成 null」，而本场景只会改这一个 —— 多出来的灵活性只会多一处误用面。
  AdvanceDeps withHotwords(List<String> hotwords) => AdvanceDeps(
    db: db,
    llm: llm,
    cfg: cfg,
    media: media,
    asr: asr,
    asrCfg: asrCfg,
    visionSupported: visionSupported,
    hotwords: hotwords,
    now: now,
    idGen: idGen,
    maxAnalyzeImages: maxAnalyzeImages,
  );
}

final class CaptureInput {
  const CaptureInput({required this.source, this.text, this.images, this.audio});

  final SourceKind source;

  /// 已输入或已转写的文本；没有则为 null。
  final String? text;

  /// 已落盘的图片相对路径，顺序即拍摄/选择顺序。
  final List<String>? images;

  /// 已落盘的音频相对路径。
  final String? audio;
}

/// 落盘之后的第一步：插入草稿卡。**纯数据库操作、不碰网络**，
/// 因此录入界面可以立即拿到卡片渲染，素材也就永远不会因为网络问题而丢失。
///
/// [id] 由调用方传入 —— 媒体路径里含 cardId，且要求「先写文件再插行」，
/// 所以 id 必须在平台层先于落盘生成。
MemoryCard createDraft(
  SqliteDriver db,
  CaptureInput input, {
  required String id,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final ts = isoUtc(at);
  final hasAudio = input.audio != null && input.audio!.isNotEmpty;
  final text = input.text;
  final hasText = text != null && text.trim().isNotEmpty;
  final images = input.images != null && input.images!.isNotEmpty ? input.images : null;

  final draft = MemoryCard(
    id: id,
    // 有音频且无文本才等转写；已经打了字就直接进待解析（需求四「打字则跳过转写」）
    status: hasAudio && !hasText ? CardStatus.pendingTranscript : CardStatus.pending,
    needsOrganize: false,
    categoryId: null,
    entity: null,
    pathIds: null,
    pathNames: null,
    steps: null,
    transcript: hasText ? text.trim() : null,
    desc: null,
    images: images,
    audioPath: input.audio,
    // 有图即视为「尚未成功分析过」；成功后由理解步骤置 1，无图恒为 null
    visionAnalyzed: images != null ? false : null,
    tags: null,
    confidence: null,
    ask: null,
    pathSuggestion: null,
    pathMatched: null,
    source: input.source,
    retryCount: 0,
    nextRetryAt: null,
    lastError: null,
    createdAt: ts,
    updatedAt: ts,
  );
  insertCard(db, draft);
  return draft;
}

// ─────────────────────────────────────────────────────────────
// 理解步骤：一次模型调用，外加位置树的增量维护（会写 locations 表）。
// 抽出来是为了让「对已入库卡片重新理解」不必先把卡片降级成草稿。
// ─────────────────────────────────────────────────────────────

/// 一次理解的结果。
sealed class UnderstandingResult {
  const UnderstandingResult();
}

/// 关掉图片分析 + 没有文字 ⇒ 没有任何可抽取的信息源，存成「纯图片卡片」。
final class UnderstandingPlain extends UnderstandingResult {
  const UnderstandingPlain();
}

/// 重试 1 次仍拿不到合法 JSON。
final class UnderstandingParseFailed extends UnderstandingResult {
  const UnderstandingParseFailed();
}

/// 调用本身失败（网络/认证/超时）。
final class UnderstandingError extends UnderstandingResult {
  const UnderstandingError(this.error);
  final String error;
}

/// 拿到了结构化字段。
final class UnderstandingParsed extends UnderstandingResult {
  const UnderstandingParsed({required this.fields, required this.usedImages});

  final ParsedCardFields fields;

  /// 本次真的把图送出去了 —— 落库时据此决定要不要置「已分析」。
  final bool usedImages;
}

Future<UnderstandingResult> runUnderstanding(
  AdvanceDeps deps,
  MemoryCard card, {
  required bool vision,
}) async {
  final images = card.images ?? const <String>[];
  final text = card.transcript;
  final visionSupported = deps.visionSupported ?? true;
  final maxImages = deps.maxAnalyzeImages ?? defaultMaxAnalyzeImages;
  final imagesToSend = visionSupported && vision
      ? images.take(maxImages).toList()
      : const <String>[];

  // 关掉图片分析 + 没有文字 ⇒ 没有任何可抽取的信息源。
  // 这里不能去调 P1：buildP1User 的兜底文案会与「不发图」自相矛盾，模型容易开始编。
  if ((text == null || text.isEmpty) && imagesToSend.isEmpty) {
    return const UnderstandingPlain();
  }

  final parts = <Part>[];
  if (imagesToSend.isNotEmpty) {
    final media = deps.media;
    if (media == null) throw StateError('需要读取图片但未注入 MediaIo');
    for (final rel in imagesToSend) {
      final data = await media.imageData(rel);
      parts.add(ImagePart(mime: data.mime, base64: data.base64));
    }
  }
  parts.add(TextPart(buildP1User(text)));

  // 两种「仅文本」变体的文案不同（需求 5.1 / prompt设计.md 一）
  final TextOnlyMode? textOnly = !visionSupported
      ? TextOnlyMode.unsupported
      : (images.isNotEmpty && imagesToSend.isEmpty ? TextOnlyMode.off : null);

  final system = buildP1System(
    categories: formatCategoriesForPrompt(listCategories(deps.db)),
    locations: formatLocationsForPrompt(listLocations(deps.db)),
    textOnly: textOnly,
  );
  Future<ChatResponse> call(String extra) => deps.llm.chat(
    ChatRequest(system: system + extra, parts: parts, temperature: 0.1),
    deps.cfg,
  );

  ParseResult<P1Output> parsed;
  try {
    final first = await call('');
    parsed = parseModelJson(first.text, P1OutputSchema.tryParse);
    if (parsed is! ParseOk<P1Output>) {
      final second = await call('\n\n注意：只输出一个合法 JSON 对象，不要任何多余文字。');
      parsed = parseModelJson(second.text, P1OutputSchema.tryParse);
    }
  } catch (e) {
    return UnderstandingError(_messageOf(e));
  }
  if (parsed is! ParseOk<P1Output>) return const UnderstandingParseFailed();

  final out = parsed.value;
  final categoryId = out.category != null ? resolveCategoryId(deps.db, out.category!) : null;
  // 位置：**由内容决定**，不再拷问「这张卡是什么类型」。模型在内容确实提到存放位置时才给 path，
  // 给了就匹配得到复用、匹配不到**新建** —— 位置树应当由解析结果增量长出来，
  // 而不是要求用户先去设置页手工建好房间再回来选（那等于把「模型会产出什么词」推给用户猜）
  final path = out.path != null
      ? ensurePath(deps.db, out.path!, idGen: deps.idGenerator)
      : null;
  /*
    这里原有一个「待确认」标记 —— 置信度 < 0.6 / 分类选不出 / 本次新建了位置层级 → 打角标，
    第二十版整条删除。删的理由：它只产出一个角标，既不阻挡入库、也不影响检索，
    而唯一的清除按钮只是把角标擦掉、并不修正任何数据，于是留下一个「看得见却无从下手」的提醒；
    四条触发条件里也只剩「模型新造了位置层级」有价值，而那件事本来就该在位置树上直接改。
    真要纠正，用户有直路：详情页点分类 chip、点位置行，或「重新整理」重跑一遍理解。
  */

  return UnderstandingParsed(
    usedImages: imagesToSend.isNotEmpty,
    fields: ParsedCardFields(
      categoryId: categoryId,
      entity: out.entity,
      pathIds: path?.ids,
      pathNames: path?.namesStr,
      steps: out.steps.isNotEmpty
          ? out.steps.map((t) => StepItem(text: t, done: false)).toList()
          : null,
      desc: out.desc,
      tags: out.tags,
      confidence: out.confidence,
      aliases: out.aliases,
      ask: out.ask.isEmpty ? null : out.ask,
      pathSuggestion: out.pathSuggestion,
      // 以「本次真的新建过节点」为准，比模型自报可靠：新建过 ⇒ 没匹配上已有树
      pathMatched: path != null ? path.created.isEmpty : out.pathMatched,
    ),
  );
}

/// `e instanceof Error ? e.message : String(e)` —— 见 `providers/capabilities.dart` 的同款说明。
String _messageOf(Object e) => e.toString();

/// 推进一张卡的结果。
enum AdvanceOutcome {
  activated('activated'),
  needsOrganize('needs-organize'),
  plainCard('plain-card'),
  retry('retry'),

  /// 没配 ASR：素材留着，等用户补文字或之后批量补转写，不算失败。
  skippedNoAsr('skipped-no-asr'),

  skippedNotPending('skipped-not-pending');

  const AdvanceOutcome(this.wire);
  final String wire;
}

final class AdvanceResult {
  const AdvanceResult({required this.card, required this.outcome, this.error});

  final MemoryCard card;
  final AdvanceOutcome outcome;
  final String? error;
}

/// 推进一张草稿卡：待转写 → 转写 → 理解 → 入库。
/// 所有失败都保持素材可重试，绝不静默丢弃（需求四、九）。
Future<AdvanceResult> advanceCard(
  AdvanceDeps deps,
  String cardId, {
  bool? vision,
}) async {
  final clock = deps.clock;
  MemoryCard reload() => getCard(deps.db, cardId)!;

  var card = reload();
  if (card.status != CardStatus.pendingTranscript && card.status != CardStatus.pending) {
    return AdvanceResult(card: card, outcome: AdvanceOutcome.skippedNotPending);
  }

  // ── 第一步：待转写 ────────────────────────────────────────
  if (card.status == CardStatus.pendingTranscript) {
    final transcript = card.transcript;
    if (transcript == null || transcript.isEmpty) {
      final asr = deps.asr;
      final asrCfg = deps.asrCfg;
      final audioPath = card.audioPath;
      if (asr == null || asrCfg == null || audioPath == null) {
        return AdvanceResult(card: card, outcome: AdvanceOutcome.skippedNoAsr);
      }
      try {
        final res = await asr.transcribe(
          TranscribeRequest(
            audio: AudioFileRef(rel: audioPath, mime: audioMime),
            filename: 'audio.m4a',
            lang: 'zh',
            hotwords: deps.hotwords,
          ),
          asrCfg,
        );
        setTranscript(deps.db, cardId, res.text, clock());
        card = reload();
      } catch (e) {
        final error = _messageOf(e);
        markRetry(deps.db, cardId, error, clock());
        return AdvanceResult(card: reload(), outcome: AdvanceOutcome.retry, error: error);
      }
    } else {
      setTranscript(deps.db, cardId, transcript, clock());
      card = reload();
    }
  }

  // ── 第二步：理解 ──────────────────────────────────────────
  UnderstandingResult result;
  try {
    result = await runUnderstanding(deps, card, vision: vision ?? true);
  } catch (e) {
    final error = _messageOf(e);
    markRetry(deps.db, cardId, error, clock());
    return AdvanceResult(card: reload(), outcome: AdvanceOutcome.retry, error: error);
  }

  switch (result) {
    case UnderstandingPlain():
      markPlainCard(deps.db, cardId, clock());
      return AdvanceResult(card: reload(), outcome: AdvanceOutcome.plainCard);
    case UnderstandingParseFailed():
      // 需求 3.4：重试 1 次仍失败 → 只保留原文与图片，标记「待整理」
      markNeedsOrganize(deps.db, cardId, clock());
      return AdvanceResult(card: reload(), outcome: AdvanceOutcome.needsOrganize);
    case UnderstandingError(:final error):
      markRetry(deps.db, cardId, error, clock());
      return AdvanceResult(card: reload(), outcome: AdvanceOutcome.retry, error: error);
    case UnderstandingParsed(:final fields, :final usedImages):
      applyParseResult(deps.db, cardId, fields, clock(), idGen: deps.idGenerator);
      // 本次真的把图送出去了才算「已分析」，否则卡片要一直带着「未分析」角标
      if (usedImages) setVisionAnalyzed(deps.db, cardId, true, clock());
      return AdvanceResult(card: reload(), outcome: AdvanceOutcome.activated);
  }
}

/// 落盘 + 推进一次。界面若想先渲染草稿，请直接用 [createDraft] + [advanceCard]。
Future<MemoryCard> ingestCapture(
  AdvanceDeps deps,
  CaptureInput input, {
  String? id,
  bool? vision,
}) async {
  final cardId = id ?? deps.idGenerator();
  createDraft(deps.db, input, id: cardId, now: deps.clock());
  final result = await advanceCard(deps, cardId, vision: vision);
  return result.card;
}
