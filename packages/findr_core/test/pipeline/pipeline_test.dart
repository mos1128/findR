/// 录入流水线的编排 —— 逐字对应 `packages/core/test/pipeline.test.ts`（618 行 / 31 个用例）。
///
/// 这一层是「草稿 → 转写 → 理解 → 落库」的完整闭环，也是需求四/九的验收网：
/// **任何失败都必须保持素材可重试，绝不静默丢弃。**
///
/// Dart 侧的对应关系（与 TS 的差异都在注释里标出）：
/// - TS 的 `FakeLLMAdapter` ⇒ Dart 的 `FakeLlmAdapter`（同一个队列语义，队列空即抛错）；
/// - TS 的 `MediaIO` 里 `audioPart` 返回 `Blob` / `{uri,name,type}` ⇒ Dart 返回具体
///   `http.MultipartFile`（见 `lib/providers/media.dart` 的说明）；
/// - TS 的 `{kind:'file', rel, mime}` ⇒ Dart 用 `AudioFileRef` 类型本身表达「文件直传」，
///   所以断言改成类型 + 字段，而不是判字符串 union。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:test/test.dart';

import '../helpers.dart';

/// 与 TS 的 `const CFG` 同源：假 Provider，只用来占位（真调用全被 FakeLlmAdapter 接住）。
const ProviderConfig cfG = ProviderConfig(providerType: ProviderType.fake, model: 'fake');

/// 与 TS 的 `const NOW = new Date('2026-03-01T12:00:00.000Z')` 同源。
final DateTime clockNow = DateTime.parse('2026-03-01T12:00:00.000Z');

/// 媒体端口的替身 —— **图片 base64 带上路径名**，好断言「送进模型的是哪一张」。
final MediaIo stubMediaIo = _StubMedia();

final class _StubMedia implements MediaIo {
  @override
  Future<ImageData> imageData(String rel) async =>
      ImageData(base64: 'b64:$rel', mime: 'image/webp');

  @override
  Future<http.MultipartFile> audioPart(String rel, String mime, String filename) async =>
      http.MultipartFile.fromBytes(
        'file',
        Uint8List.fromList(<int>[0]),
        filename: filename,
        contentType: MediaType.parse(mime),
      );

  @override
  String fileUri(String rel) => 'file:///docs/$rel';

  @override
  Future<void> removeCardMedia(List<String> relPaths) async {}
}

/// 一条预置的转写响应。TS 里是 `{ text?: string; error?: string }` 匿名对象，
/// Dart 用具名小类，读起来更清楚（也让 `const` 列表可用）。
final class AsrResp {
  const AsrResp({this.text, this.error});

  final String? text;
  final String? error;
}

/// 脚本化假 ASR —— 与 TS 的 `FakeAsr` 同源：按队列返回，队列空或带 error 即抛错。
final class FakeAsr implements AsrProviderAdapter {
  FakeAsr([List<AsrResp> responses = const <AsrResp>[]]) {
    _queue.addAll(responses);
  }

  final List<TranscribeRequest> requests = <TranscribeRequest>[];

  final List<AsrResp> _queue = <AsrResp>[];

  @override
  Future<TranscribeResult> transcribe(TranscribeRequest req, ProviderConfig cfg) async {
    requests.add(req);
    if (_queue.isEmpty) throw StateError('FakeAsr: 无预置响应');
    final next = _queue.removeAt(0);
    final error = next.error;
    if (error != null && error.isNotEmpty) throw StateError(error);
    return TranscribeResult(next.text ?? '');
  }
}

/// 一条合法的 P1 模型输出（默认值即 TS 的 `p1()`）。
String p1([Map<String, Object?> over = const <String, Object?>{}]) => jsonEncode(<String, Object?>{
  'category': '物品存取',
  'entity': '备用手电筒',
  'aliases': <Object?>['手电'],
  'path': null,
  'path_matched': false,
  'path_suggestion': '主卧衣柜顶层',
  'steps': <Object?>[],
  'desc': '备用手电筒放在主卧衣柜顶层。',
  'tags': <Object?>['应急'],
  'confidence': 0.9,
  'missing': <Object?>[],
  'ask': '',
  ...over,
});

/// 与 TS 的 `deps()` 同源：只传关心的那几项，其余取默认（clock 固定、media 用替身）。
AdvanceDeps deps({
  required SqliteDriver db,
  required LlmProviderAdapter llm,
  AsrProviderAdapter? asr,
  ProviderConfig? asrCfg,
  List<String>? hotwords,
  bool? visionSupported,
  int? maxAnalyzeImages,
  String Function()? idGen,
}) => AdvanceDeps(
  db: db,
  llm: llm,
  cfg: cfG,
  media: stubMediaIo,
  asr: asr,
  asrCfg: asrCfg,
  hotwords: hotwords,
  visionSupported: visionSupported,
  maxAnalyzeImages: maxAnalyzeImages,
  idGen: idGen,
  now: () => clockNow,
);

void main() {
  // ─────────────────────────────────────────────────────────────
  // createDraft
  // ─────────────────────────────────────────────────────────────

  test('有音频且无文本才进待转写；打了字就直接进待解析', () {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/a.m4a'),
      id: 'c1',
    );
    expect(getCard(db, 'c1')!.status, CardStatus.pendingTranscript);

    // 边拍边说同时带了文字：文字即 transcript，不该再送去转写
    createDraft(
      db,
      const CaptureInput(
        source: SourceKind.voice,
        audio: 'files/audio/202603/b.m4a',
        text: '手电筒在衣柜',
      ),
      id: 'c2',
    );
    expect(getCard(db, 'c2')!.status, CardStatus.pending);
    expect(getCard(db, 'c2')!.transcript, '手电筒在衣柜');

    createDraft(db, const CaptureInput(source: SourceKind.text, text: '纯文字'), id: 'c3');
    expect(getCard(db, 'c3')!.status, CardStatus.pending);

    createDraft(
      db,
      const CaptureInput(source: SourceKind.photo, images: ['files/cards/202603/d/01.webp']),
      id: 'c4',
    );
    expect(getCard(db, 'c4')!.status, CardStatus.pending);
  });

  test('有图时 vision_analyzed 初值为「未分析」，无图为 null', () {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.photo, images: ['a.webp', 'b.webp']),
      id: 'c1',
    );
    expect(getCard(db, 'c1')!.visionAnalyzed, false);
    createDraft(db, const CaptureInput(source: SourceKind.text, text: '无图'), id: 'c2');
    expect(getCard(db, 'c2')!.visionAnalyzed, isNull);
  });

  // ─────────────────────────────────────────────────────────────
  // 转写
  // ─────────────────────────────────────────────────────────────

  test('没有配置 ASR：卡片原样保留，重试计数不涨（这不是失败）', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/a.m4a'),
      id: 'c1',
    );
    final llm = FakeLlmAdapter();

    final r = await advanceCard(deps(db: db, llm: llm), 'c1');
    expect(r.outcome, AdvanceOutcome.skippedNoAsr);
    final card = getCard(db, 'c1')!;
    expect(card.status, CardStatus.pendingTranscript);
    expect(card.retryCount, 0);
    expect(card.audioPath, 'files/audio/202603/a.m4a');
    expect(llm.requests, isEmpty);
  });

  test('转写成功后继续走理解，音频路径原样保留', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/a.m4a'),
      id: 'c1',
    );
    final llm = FakeLlmAdapter([p1()]);
    final asr = FakeAsr([const AsrResp(text: '手电筒放主卧衣柜顶层了')]);

    final r = await advanceCard(
      deps(db: db, llm: llm, asr: asr, asrCfg: cfG, hotwords: const ['主卧', '衣柜']),
      'c1',
    );
    expect(r.outcome, AdvanceOutcome.activated);
    final card = getCard(db, 'c1')!;
    expect(card.transcript, '手电筒放主卧衣柜顶层了');
    expect(card.entity, '备用手电筒');
    expect(card.audioPath, 'files/audio/202603/a.m4a');

    // ASR 走的是文件直传 + 热词
    final req = asr.requests[0];
    expect(req.audio, isA<AudioFileRef>());
    final audio = req.audio as AudioFileRef;
    expect(audio.rel, 'files/audio/202603/a.m4a');
    expect(audio.mime, 'audio/m4a');
    expect(req.hotwords, const ['主卧', '衣柜']);
  });

  test('转写失败：保持待转写，按退避序列排下次重试', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/a.m4a'),
      id: 'c1',
    );
    final llm = FakeLlmAdapter();
    final asr = FakeAsr([const AsrResp(error: '网络超时')]);

    final r = await advanceCard(deps(db: db, llm: llm, asr: asr, asrCfg: cfG), 'c1');
    expect(r.outcome, AdvanceOutcome.retry);
    final card = getCard(db, 'c1')!;
    expect(card.status, CardStatus.pendingTranscript);
    expect(card.retryCount, 1);
    expect(card.lastError, contains('网络超时'));
    // 第一次失败 → 1 分钟后
    expect(card.nextRetryAt, isoUtc(clockNow.add(const Duration(minutes: 1))));
  });

  // ─────────────────────────────────────────────────────────────
  // 图片分析开关
  // ─────────────────────────────────────────────────────────────

  test('图片分析关闭但有文字：不发图，且注入「用户主动关闭」的仅文本变体', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(
        source: SourceKind.photo,
        text: '收据留底',
        images: ['files/cards/202603/c1/01.webp'],
      ),
      id: 'c1',
    );
    final llm = FakeLlmAdapter([p1(<String, Object?>{'confidence': 0.9})]);

    await advanceCard(deps(db: db, llm: llm), 'c1', vision: false);

    final req = llm.requests[0];
    expect(req.parts.any((p) => p is ImagePart), isFalse);
    expect(req.system, contains('本次用户选择不分析图片'));
    // 用户已知情，不该在 desc 里声明「未见图片」
    expect(getCard(db, 'c1')!.visionAnalyzed, false);
  });

  test('模型不支持图片：走「能力缺失」变体而非「用户关闭」变体', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(
        source: SourceKind.photo,
        text: '包装盒',
        images: ['files/cards/202603/c1/01.webp'],
      ),
      id: 'c1',
    );
    final llm = FakeLlmAdapter([p1()]);
    await advanceCard(deps(db: db, llm: llm, visionSupported: false), 'c1', vision: true);

    final req = llm.requests[0];
    expect(req.system, contains('当前模型无法接收图片'));
    expect(req.parts.any((p) => p is ImagePart), isFalse);
  });

  test('带图成功识别后 vision_analyzed 置 1，角标随之消失', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(
        source: SourceKind.photo,
        text: '手电筒',
        images: ['files/cards/202603/c1/01.webp'],
      ),
      id: 'c1',
    );
    final llm = FakeLlmAdapter([p1()]);
    await advanceCard(deps(db: db, llm: llm), 'c1', vision: true);

    final imagePart = llm.requests[0].parts.whereType<ImagePart>().single;
    expect(imagePart.mime, 'image/webp');
    expect(imagePart.base64, 'b64:files/cards/202603/c1/01.webp');
    expect(getCard(db, 'c1')!.visionAnalyzed, true);
  });

  test('图片分析关闭且无文字：不调模型，直接落为纯图片卡片', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.photo, images: ['files/cards/202603/c1/01.webp']),
      id: 'c1',
    );
    final llm = FakeLlmAdapter();

    final r = await advanceCard(deps(db: db, llm: llm), 'c1', vision: false);
    expect(r.outcome, AdvanceOutcome.plainCard);
    expect(llm.requests, isEmpty);

    final card = getCard(db, 'c1')!;
    expect(card.status, CardStatus.active);
    expect(card.desc, isNull);
    expect(card.needsOrganize, false);
    // 唯一该带的是「未分析」（有图但没送过模型）；「待确认」已于第二十版删掉
    expect(cardBadges(card), [CardBadge.unanalyzed]);
    expect(card.visionAnalyzed, false);
    expect(card.images, hasLength(1));
  });

  test('单卡图片超过上限时只送前 N 张', () async {
    final db = makeDb();
    final images = List.generate(9, (i) => 'files/cards/202603/c1/0${i + 1}.webp');
    createDraft(
      db,
      CaptureInput(source: SourceKind.photo, text: '流程截图', images: images),
      id: 'c1',
    );
    final llm = FakeLlmAdapter([p1(<String, Object?>{'category': '流程备忘'})]);

    await advanceCard(deps(db: db, llm: llm, maxAnalyzeImages: 3), 'c1', vision: true);
    final sent = llm.requests[0].parts.whereType<ImagePart>().toList();
    expect(sent, hasLength(3));
  });

  // ─────────────────────────────────────────────────────────────
  // 解析结果落库
  // ─────────────────────────────────────────────────────────────

  test('解析成功即入库：低置信 / 分类选不出 / 新建了位置层级，都不再打扰用户', () async {
    final db = makeDb();

    // 第二十版删掉了「待确认」整条功能，而这三条正是它当初的触发条件 —— 现在一律照常入库、不挂角标。
    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'a'), id: 'low');
    await advanceCard(
      deps(db: db, llm: FakeLlmAdapter([p1(<String, Object?>{'confidence': 0.3})])),
      'low',
    );
    final low = getCard(db, 'low')!;
    expect(low.status, CardStatus.active);
    expect(cardBadges(low), isEmpty);

    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'b'), id: 'nocat');
    await advanceCard(
      deps(db: db, llm: FakeLlmAdapter([p1(<String, Object?>{'category': null})])),
      'nocat',
    );
    final nocat = getCard(db, 'nocat')!;
    expect(nocat.categoryId, isNull);
    expect(cardBadges(nocat), isEmpty);

    // 位置树里本来没有「主卧/衣柜顶层」⇒ 解析时新建了层级：树照常长出来，卡片不挂角标
    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'c'), id: 'newpath');
    final p1NewPath = p1(<String, Object?>{
      'path': <Object?>['主卧', '衣柜顶层'],
      'path_matched': false,
    });
    await advanceCard(deps(db: db, llm: FakeLlmAdapter([p1NewPath])), 'newpath');
    final newpath = getCard(db, 'newpath')!;
    expect(newpath.pathNames, '主卧/衣柜顶层');
    expect(newpath.pathMatched, false);
    expect(cardBadges(newpath), isEmpty);

    // 命中已有位置：行为不变
    upsertLocation(db, const LocationNode(id: 'l_master', parentId: null, name: '主卧', sort: 0));
    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'd'), id: 'hit');
    final p1Hit = p1(<String, Object?>{
      'path': <Object?>['主卧'],
      'path_matched': true,
    });
    await advanceCard(deps(db: db, llm: FakeLlmAdapter([p1Hit])), 'hit');
    expect(getCard(db, 'hit')!.pathMatched, true);
  });

  test('内容里没有位置时：path 保持 null，也不去追问位置（改由 ask 决定）', () async {
    final db = makeDb();
    createDraft(db, const CaptureInput(source: SourceKind.text, text: '该买猫砂了'), id: 'c1');
    final llm = FakeLlmAdapter([
      p1(<String, Object?>{
        'category': '待买补货',
        'path': null,
        'path_matched': false,
        'ask': '',
      }),
    ]);
    await advanceCard(deps(db: db, llm: llm), 'c1');

    final card = getCard(db, 'c1')!;
    expect(card.pathIds, isNull);
    expect(card.pathNames, isNull);
    expect(card.ask, isNull);
    // 位置树不该被凭空塞进节点
    expect(listLocations(db), isEmpty);
  });

  test('ask 与 path_suggestion 会落库，供记忆流展示补问入口', () async {
    final db = makeDb();
    createDraft(db, const CaptureInput(source: SourceKind.text, text: '扳手放工具箱了'), id: 'c1');
    final llm = FakeLlmAdapter([
      p1(<String, Object?>{
        'path': null,
        'path_matched': false,
        'path_suggestion': '阳台/工具箱',
        'ask': '工具箱在哪个房间？',
      }),
    ]);
    await advanceCard(deps(db: db, llm: llm), 'c1');

    final card = getCard(db, 'c1')!;
    expect(card.ask, '工具箱在哪个房间？');
    expect(card.pathSuggestion, '阳台/工具箱');
    expect(card.pathMatched, false);
  });

  test('解析两次都失败 → 待整理，原文与图片都留着且仍带未分析角标', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(
        source: SourceKind.photo,
        text: '一段口述',
        images: ['files/cards/202603/c1/01.webp'],
      ),
      id: 'c1',
    );
    final llm = FakeLlmAdapter(['不是 JSON', '仍然不是 JSON']);

    final r = await advanceCard(deps(db: db, llm: llm), 'c1', vision: true);
    expect(r.outcome, AdvanceOutcome.needsOrganize);

    final card = getCard(db, 'c1')!;
    expect(card.status, CardStatus.active);
    expect(card.needsOrganize, true);
    expect(card.transcript, '一段口述');
    expect(card.images, hasLength(1));
    expect(card.desc, isNull);
    // 图没被成功分析过，角标必须还在
    expect(card.visionAnalyzed, false);
  });

  test('模型调用失败 → 草稿保持待解析并按退避排重试', () async {
    final db = makeDb();
    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'x'), id: 'c1');
    final r = await advanceCard(deps(db: db, llm: FakeLlmAdapter()), 'c1');

    expect(r.outcome, AdvanceOutcome.retry);
    final card = getCard(db, 'c1')!;
    expect(card.status, CardStatus.pending);
    expect(card.retryCount, 1);
    expect(card.nextRetryAt, isoUtc(clockNow.add(const Duration(minutes: 1))));
  });

  test('已入库的卡片不会被 advanceCard 再处理', () async {
    final db = makeDb();
    insertCard(db, makeCard(id: 'c1', status: CardStatus.active));
    final llm = FakeLlmAdapter([p1()]);
    final r = await advanceCard(deps(db: db, llm: llm), 'c1');
    expect(r.outcome, AdvanceOutcome.skippedNotPending);
    expect(llm.requests, isEmpty);
  });

  // ─────────────────────────────────────────────────────────────
  // 队列
  // ─────────────────────────────────────────────────────────────

  test('队列串行推进多张草稿', () async {
    resetQueueLockForTest();
    final db = makeDb();
    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'a'), id: 'c1');
    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'b'), id: 'c2');
    createDraft(db, const CaptureInput(source: SourceKind.text, text: 'c'), id: 'c3');
    final llm = FakeLlmAdapter([p1(), p1(), p1()]);

    final r = await runQueue(deps(db: db, llm: llm));
    expect(r.processed, 3);
    expect(r.settled, 3);
    expect(listQueueCards(db, clockNow), isEmpty);
  });

  test('没配 ASR 时待转写卡不入选，不会堵住后面的卡', () async {
    resetQueueLockForTest();
    final db = makeDb();
    // 6 张待转写卡超过单批 5 张：若它们入选就会占满队头，后面的卡永远轮不到
    for (var i = 0; i < 6; i++) {
      createDraft(
        db,
        CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/v$i.m4a'),
        id: 'v$i',
      );
    }
    createDraft(db, const CaptureInput(source: SourceKind.text, text: '文字卡'), id: 'text');
    final llm = FakeLlmAdapter([p1()]);

    final r = await runQueue(deps(db: db, llm: llm));
    expect(r.settled, 1);
    expect(r.skippedNoAsr, 0);
    expect(getCard(db, 'text')!.status, CardStatus.active);
    expect(getCard(db, 'v0')!.status, CardStatus.pendingTranscript);
    // 没有被无谓地计入重试，素材原样等待
    expect(getCard(db, 'v0')!.retryCount, 0);
  });

  test('配好 ASR 后队列会把积压的待转写卡一起补完', () async {
    resetQueueLockForTest();
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/v0.m4a'),
      id: 'v0',
    );
    createDraft(
      db,
      const CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/v1.m4a'),
      id: 'v1',
    );
    final llm = FakeLlmAdapter([p1(), p1()]);
    final asr = FakeAsr([const AsrResp(text: '第一段'), const AsrResp(text: '第二段')]);

    final r = await runQueue(deps(db: db, llm: llm, asr: asr, asrCfg: cfG));
    expect(r.settled, 2);
    expect(getCard(db, 'v0')!.status, CardStatus.active);
    expect(getCard(db, 'v1')!.status, CardStatus.active);
  });

  test('队列不会把已达重试上限的卡片再捞起来', () async {
    resetQueueLockForTest();
    final db = makeDb();
    insertCard(db, makeCard(id: 'c1', status: CardStatus.pending, retryCount: maxAutoRetry));
    final llm = FakeLlmAdapter([p1()]);
    final r = await runQueue(deps(db: db, llm: llm));
    expect(r.processed, 0);
    expect(llm.requests, isEmpty);
  });

  test('批量补转写：重置退避与上限、带上热词', () async {
    resetQueueLockForTest();
    final db = makeDb();
    insertCard(
      db,
      makeCard(
        id: 'c1',
        status: CardStatus.pendingTranscript,
        audioPath: 'files/audio/202603/a.m4a',
        retryCount: maxAutoRetry,
        nextRetryAt: '2026-04-01T00:00:00.000Z',
      ),
    );
    final llm = FakeLlmAdapter([p1()]);
    final asr = FakeAsr([const AsrResp(text: '手电筒在衣柜')]);

    final r = await retryAllTranscriptions(deps(db: db, llm: llm, asr: asr, asrCfg: cfG));
    expect(r.reset, 1);
    expect(r.run.settled, 1);
    expect(getCard(db, 'c1')!.status, CardStatus.active);
    // 没显式给热词时自动从位置树与高频实体收集
    expect(asr.requests, hasLength(1));
  });

  // ─────────────────────────────────────────────────────────────
  // 编辑闭环
  // ─────────────────────────────────────────────────────────────

  test('补文字把待转写推进到入库', () async {
    final db = makeDb();
    createDraft(
      db,
      const CaptureInput(source: SourceKind.voice, audio: 'files/audio/202603/a.m4a'),
      id: 'c1',
    );
    final llm = FakeLlmAdapter([p1()]);

    final r = await submitTranscript(deps(db: db, llm: llm), 'c1', '手电筒放衣柜了');
    expect(r.outcome, AdvanceOutcome.activated);
    final card = getCard(db, 'c1')!;
    expect(card.transcript, '手电筒放衣柜了');
    expect(card.status, CardStatus.active);
  });

  test('重新整理成功后清掉待整理标志', () async {
    final db = makeDb();
    insertCard(
      db,
      makeCard(
        id: 'c1',
        status: CardStatus.active,
        needsOrganize: true,
        transcript: '口述原文',
      ),
    );
    final llm = FakeLlmAdapter([p1()]);

    final r = await reorganizeCard(deps(db: db, llm: llm), 'c1');
    expect(r.outcome, AdvanceOutcome.activated);
    expect(getCard(db, 'c1')!.needsOrganize, false);
    expect(getCard(db, 'c1')!.entity, '备用手电筒');
  });

  test('重新整理再次失败时待整理标志保持不动（不能只清标志留下空卡）', () async {
    final db = makeDb();
    insertCard(
      db,
      makeCard(
        id: 'c1',
        status: CardStatus.active,
        needsOrganize: true,
        transcript: '口述原文',
      ),
    );
    final r = await reorganizeCard(
      deps(db: db, llm: FakeLlmAdapter(['坏输出', '还是坏输出'])),
      'c1',
    );
    expect(r.outcome, AdvanceOutcome.needsOrganize);
    expect(getCard(db, 'c1')!.needsOrganize, true);
  });

  test('补分析图片：重跑视觉理解并清掉未分析角标', () async {
    final db = makeDb();
    insertCard(
      db,
      makeCard(
        id: 'c1',
        status: CardStatus.active,
        images: ['files/cards/202603/c1/01.webp'],
        visionAnalyzed: false,
      ),
    );
    final llm = FakeLlmAdapter([p1(<String, Object?>{'desc': '补分析后的描述'})]);

    final r = await reanalyzeCard(deps(db: db, llm: llm), 'c1');
    expect(r.outcome, AdvanceOutcome.activated);
    final card = getCard(db, 'c1')!;
    expect(card.visionAnalyzed, true);
    expect(card.desc, '补分析后的描述');
    expect(llm.requests[0].parts.any((p) => p is ImagePart), isTrue);
  });

  test('补分析失败时卡片保持原样，不被降级成草稿', () async {
    final db = makeDb();
    insertCard(
      db,
      makeCard(
        id: 'c1',
        status: CardStatus.active,
        entity: '原有实体',
        desc: '原有描述',
        images: ['files/cards/202603/c1/01.webp'],
        visionAnalyzed: false,
      ),
    );
    final r = await reanalyzeCard(deps(db: db, llm: FakeLlmAdapter()), 'c1');

    expect(r.outcome, AdvanceOutcome.retry);
    final card = getCard(db, 'c1')!;
    expect(card.status, CardStatus.active);
    expect(card.entity, '原有实体');
    expect(card.desc, '原有描述');
    expect(card.visionAnalyzed, false);
  });

  test('重新生成 desc 只改 desc，用户编辑过的字段不被模型覆盖', () async {
    final db = makeDb();
    insertCard(
      db,
      makeCard(
        id: 'c1',
        status: CardStatus.active,
        entity: '用户改过的名字',
        categoryId: 'cat_procedure',
        transcript: '一段口述',
        desc: '旧描述',
      ),
    );
    final llm = FakeLlmAdapter([
      p1(<String, Object?>{
        'entity': '模型想改的名字',
        'category': '物品存取',
        'desc': '新描述',
      }),
    ]);

    final r = await regenerateDesc(deps(db: db, llm: llm), 'c1');
    expect(r.ok, isTrue);

    final card = getCard(db, 'c1')!;
    expect(card.desc, '新描述');
    expect(card.entity, '用户改过的名字');
    expect(card.categoryId, 'cat_procedure');

    // 是纯文本调用，不带图
    final req = llm.requests[0];
    expect(req.parts.any((p) => p is ImagePart), isFalse);
    // 且把已确认字段作为既定事实注入了
    expect(
      req.parts.whereType<TextPart>().any((p) => p.text.contains('用户改过的名字')),
      isTrue,
    );
  });

  test('重新生成 desc 失败时不改动卡片', () async {
    final db = makeDb();
    insertCard(db, makeCard(id: 'c1', status: CardStatus.active, desc: '旧描述'));
    final r = await regenerateDesc(deps(db: db, llm: FakeLlmAdapter(['垃圾输出'])), 'c1');
    expect(r.ok, isFalse);
    expect(getCard(db, 'c1')!.desc, '旧描述');
  });

  // ─────────────────────────────────────────────────────────────
  // 端到端
  // ─────────────────────────────────────────────────────────────

  test('ingestCapture 一次走完落盘后的全流程', () async {
    final db = makeDb();
    final llm = FakeLlmAdapter([p1()]);
    final card = await ingestCapture(
      deps(db: db, llm: llm, idGen: () => 'fixed-id'),
      const CaptureInput(source: SourceKind.text, text: '手电筒放衣柜'),
    );
    expect(card.id, 'fixed-id');
    expect(card.status, CardStatus.active);
  });

  // ─────────────────────────────────────────────────────────────
  // 位置树增量维护（问题：不该要求用户先去手工建位置）
  // ─────────────────────────────────────────────────────────────

  test('解析出的位置自动建树，且不再挂角标打扰用户', () async {
    final db = makeDb();
    final llm = FakeLlmAdapter([
      p1(<String, Object?>{
        'path': <Object?>['主卧', '衣柜'],
        'confidence': 0.9,
      }),
    ]);
    final card = await ingestCapture(
      deps(db: db, llm: llm),
      const CaptureInput(source: SourceKind.text, text: '手电筒放主卧衣柜'),
    );

    expect(card.pathNames, '主卧/衣柜');
    expect(card.pathMatched, false); // 有新建 ⇒ 没命中已有树
    expect(cardBadges(card), isEmpty); // 位置不对就直接在详情页改，不靠角标提醒
    final names = listLocations(db).map((l) => l.name).toList()..sort();
    expect(names, ['主卧', '衣柜']);
  });

  test('位置已存在时复用，不会重复建树', () async {
    final db = makeDb();
    // 上次已经长出来的树
    ensurePath(db, const ['主卧', '衣柜']);

    final llm = FakeLlmAdapter([
      p1(<String, Object?>{
        'path': <Object?>['主卧', '衣柜'],
        'confidence': 0.9,
      }),
    ]);
    final card = await ingestCapture(
      deps(db: db, llm: llm),
      const CaptureInput(source: SourceKind.text, text: '手电筒放主卧衣柜'),
    );

    expect(card.pathMatched, true);
    expect(listLocations(db), hasLength(2)); // 没有因为重复解析又长出一套
  });
}
