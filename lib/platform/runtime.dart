/// 应用运行时 —— core 与界面之间的那一层。
///
/// 职责只有三件：
///   1. 把「设置 + Key + 库连接」拼成一个**不可变快照**（[RuntimeState]）交给界面；
///   2. 把快照 + 适配器拼成 core 要的依赖（[AdvanceDeps] / [SearchDeps] / [AnswerDeps]）；
///   3. 用 Riverpod 把它挂到 widget 树上（保存设置后调 `refresh()` 重读）。
///
/// **这里不做业务判断** —— 检索怎么放宽、答案怎么组织，全在 core 里。
library;

import 'dart:async';

import 'package:findr_core/findr_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_paths.dart';
import 'backup.dart';
import 'db.dart';
import 'media.dart';
import 'secure.dart';

/// 一切就绪后的运行时快照。
final class RuntimeState {
  const RuntimeState({
    required this.driver,
    required this.dbPath,
    required this.llm,
    required this.asr,
    required this.capture,
    required this.search,
    required this.llmKey,
    required this.asrKey,
    required this.version,
    required this.buildNumber,
  });

  final SqliteDriver driver;

  /// 自检屏与设置页都要显示它，排查时第一眼就看这个。
  final String dbPath;

  /// 主模型与 ASR 都可能没配（`null`）——「没配」是合法状态，不是错误。
  final LlmSettings? llm;
  final AsrSettings? asr;

  final CaptureSettings capture;
  final SearchSettings search;

  /// Key 只在内存里过一手，**从不进 DB**。
  final String? llmKey;
  final String? asrKey;

  /// App 版本号，写进备份 manifest。
  final String? version;

  /// App 构建号（Android 的 versionCode）。
  /// 与 [version] 由同一次平台通道调用填入，同样可能一直是 `null`。
  /// ⚠️ 现在版本号是三段 `X.Y.Z`、不带 `+N` ⇒ 这里恒为 **1**；它只在「远端 tag 恰好带了
  /// `+构建号`」时才可能起作用（同版本号重出包那种情形），日常发版靠的是 [version] 的最后一位。
  final String? buildNumber;

  /// 只覆盖版本号与构建号。**刻意只开这一个口子**：别让它长成通用的 `copyWith`，
  /// 那样每加一个字段就要多一处「哪些能改」的判断，而这些字段本来都是设置页的职责。
  RuntimeState withVersion(String? value, {String? buildNumber}) => RuntimeState(
    driver: driver,
    dbPath: dbPath,
    llm: llm,
    asr: asr,
    capture: capture,
    search: search,
    llmKey: llmKey,
    asrKey: asrKey,
    version: value,
    buildNumber: buildNumber,
  );
}

/// 读一遍设置 + Key。库连接由调用方给（**整个会话只该开一次**）。
Future<RuntimeState> openRuntime({
  required Sqlite3Driver db,
  required ApiKeyStore keys,
  String? version,
  String? buildNumber,
}) async {
  // 数据库平滑升级与分类规范化
  try {
    // 升级旧预设：流程备忘 改为 流程记录
    db
        .prepare(
          "UPDATE categories SET name = '流程记录', description = '怎么做的步骤、流程与材料' "
          "WHERE id = 'cat_procedure' AND name = '流程备忘'",
        )
        .run();
    // 插入新增的预设分类：备忘事项
    db
        .prepare(
          "INSERT OR IGNORE INTO categories (id, name, emoji, description, sort, is_preset) "
          "VALUES ('cat_memo', '备忘事项', NULL, '出行提醒、日常琐事、待办与生活备忘', 3, 1)",
        )
        .run();
    // 清理分类历史残留的 emoji
    db.prepare('UPDATE categories SET emoji = NULL WHERE emoji IS NOT NULL').run();
  } catch (_) {}
  final llmKey = await keys.read(ApiKeySlot.llm);
  final asrKey = await keys.read(ApiKeySlot.asr);
  return RuntimeState(
    driver: db,
    dbPath: db.path ?? '<内存库>',
    llm: readLlmSettings(db),
    asr: readAsrSettings(db),
    capture: readCaptureSettings(db),
    search: readSearchSettings(db),
    llmKey: llmKey,
    asrKey: asrKey,
    version: version,
    buildNumber: buildNumber,
  );
}

/// 图片分析开关的可用性：只有「能力已探测且明确不支持」**且模型名没变**时才锁死。
///
/// 没探测过一律按可用处理 —— 需求 3.3 说的是「能力缺失时降级」，
/// **不是「未探测时禁用」**。这两件事弄反了，用户会觉得「明明能用却点不动」。
bool visionSupported(LlmSettings? llm) {
  final caps = llm?.capabilities;
  if (caps == null) return true;
  if (capabilitiesStale(llm!)) return true;
  return caps.vision;
}

/// 主模型算不算配好了：openai 兼容那套必须有 `baseUrl`，anthropic 不需要。
bool llmConfigured(LlmSettings? llm) {
  if (llm == null) return false;
  if (llm.model.isEmpty) return false;
  if (llm.providerType == ProviderType.openaiCompat) {
    return llm.baseUrl != null && llm.baseUrl!.isNotEmpty;
  }
  return true;
}

/// `buildAdvanceDeps` 的结果：要么给依赖，要么给一句人话说明为什么给不了。
///
/// **刻意不做成抛异常**：调用点是异步的、还要给用户看提示，
/// 用返回值表达「还差配置」比 try/catch 清楚。
sealed class BuiltDeps {
  const BuiltDeps();
}

final class DepsReady extends BuiltDeps {
  const DepsReady(this.deps);

  final AdvanceDeps deps;
}

final class DepsUnavailable extends BuiltDeps {
  const DepsUnavailable(this.reason);

  final String reason;
}

BuiltDeps buildAdvanceDeps(RuntimeState rt) {
  final llm = rt.llm;
  if (!llmConfigured(llm)) return const DepsUnavailable('尚未配置主模型');
  final asr = rt.asr;
  return DepsReady(
    AdvanceDeps(
      db: rt.driver,
      llm: makeLlmAdapter(llm!),
      cfg: toProviderConfig(llm, rt.llmKey),
      media: const DeviceMediaIo(),
      asr: asr == null ? null : makeAsrAdapter(asr, const DeviceMediaIo()),
      asrCfg: asr == null ? null : toAsrProviderConfig(asr, rt.asrKey),
      visionSupported: visionSupported(llm),
      maxAnalyzeImages: rt.capture.maxAnalyzeImages,
    ),
  );
}

/// 本次队列统一使用的图片分析开关。
bool currentVision(RuntimeState rt) =>
    effectiveVision(rt.capture, visionSupported(rt.llm));

/// 跑一次解析队列。返回 `null` 表示「配置不全，跳过了」，界面照提示即可。
Future<QueueRunResult?> runQueueNow(RuntimeState rt, {bool? vision}) async {
  final built = buildAdvanceDeps(rt);
  if (built is! DepsReady) return null;
  return runQueue(built.deps, vision: vision ?? currentVision(rt));
}

/// 单卡操作（编辑闭环）用：拿不到可用配置就直接抛，调用方负责提示。
AdvanceDeps requireDeps(RuntimeState rt) {
  final built = buildAdvanceDeps(rt);
  if (built is DepsReady) return built.deps;
  throw StateError((built as DepsUnavailable).reason);
}

/// L1 检索。**没有模型也要能用** —— 字面检索（FTS + LIKE）不依赖模型。
///
/// 未配模型时把 `llm`/`cfg` 传 null，让 core 直接走字面兜底，
/// **不要在这里抛错**：抛了连兜底都没了，而兜底恰恰是没配模型时唯一能用的东西。
Future<SearchResult> runSearch(RuntimeState rt, String query) {
  final built = buildAdvanceDeps(rt);
  if (built is DepsReady) {
    return searchCards(
      SearchDeps(db: rt.driver, llm: built.deps.llm, cfg: built.deps.cfg),
      query,
    );
  }
  return searchCards(SearchDeps(db: rt.driver), query);
}

/// L2 答案组织。按需求 5.3 只在「本地无结果」或「用户手动触发」时调用 ——
/// 每次搜索都跑会白花一次模型调用，而 L1 的卡片列表本身往往就够用了。
Future<AnswerResult> runAnswer(RuntimeState rt, String query, List<MemoryCard> cards) {
  final built = buildAdvanceDeps(rt);
  if (built is! DepsReady) {
    throw StateError((built as DepsUnavailable).reason);
  }
  return answerFromCards(
    AnswerDeps(llm: built.deps.llm, cfg: built.deps.cfg),
    query,
    cards,
  );
}

// ─────────────────────────────────────────────────────────────
// Riverpod 绑定
// ─────────────────────────────────────────────────────────────

/// Key 存哪。测试里换成 [MemoryApiKeyStore]。
final apiKeyStoreProvider = Provider<ApiKeyStore>((ref) => const SecureApiKeyStore());

/// 库连接：**整个 App 生命周期只开一次**（反复开关库文件会明显增加启动延迟）。
///
/// 放在 Provider 里而不是模块级变量：生命周期跟着容器走，
/// 测试里能自然地被 `ref.onDispose` 收掉，不会留下跨用例的全局状态。
final dbProvider = Provider<Sqlite3Driver>((ref) {
  final db = openAndMigrateDb();
  ref.onDispose(db.close);
  return db;
});

/// 运行时快照。`refresh()` 用于「设置页保存之后重读一遍」。
final runtimeProvider = AsyncNotifierProvider<RuntimeNotifier, RuntimeState>(RuntimeNotifier.new);

final class RuntimeNotifier extends AsyncNotifier<RuntimeState> {
  @override
  Future<RuntimeState> build() async {
    final rt = await openRuntime(
      db: ref.watch(dbProvider),
      keys: ref.watch(apiKeyStoreProvider),
    );
    // ⚠️ **版本号不参与「能不能用」，所以不许它拖住快照。**
    // `package_info_plus` 走平台通道；在没有注册插件的环境（widget 测试、某些定制 ROM）里
    // 那个调用可能**永远不回包**，于是 `await` 一下的代价是整个界面永远停在转圈 ——
    // 用户看到的是「App 坏了」，而其实只是拿不到一个版本字符串。
    unawaited(_fillVersion(rt));
    return rt;
  }

  /// 拿到版本号与构建号再补一次快照。拿不到就一直空着
  /// （`appVersionInfo()` 有「可能永远不完成」的警告，所以只许在这里 unawaited 地等）。
  Future<void> _fillVersion(RuntimeState snapshot) async {
    final (v, b) = await appVersionInfo();
    if (v == null) return;
    final current = state.value;
    // 期间若已经 refresh 过，state 里是另一份快照，别把新快照盖回旧的
    if (current != null && identical(current, snapshot)) {
      state = AsyncData(snapshot.withVersion(v, buildNumber: b));
    }
  }

  /// 重读设置与 Key。保存设置、导入备份之后调它。
  Future<RuntimeState?> refresh() async {
    try {
      // ⚠️ Riverpod 3 的 `AsyncValue.value` 是可空的（旧版的 `valueOrNull` 已删）；
      // 同时 `copyWithPrevious` 被标成包内 API，别用 —— 这里不需要它，
      // 因为刷新过程中界面读的是旧的 `AsyncData`（我们不主动切到 loading，
      // 免得保存一下设置整页就闪成转圈）。
      final prev = state.value;
      final next = await openRuntime(
        db: ref.read(dbProvider),
        keys: ref.read(apiKeyStoreProvider),
        version: prev?.version,
        // 构建号跟着一起带过来：只带 version 的话，保存一次设置就会把构建号抹掉
        buildNumber: prev?.buildNumber,
      );
      state = AsyncData(next);
      if (next.version == null) unawaited(_fillVersion(next));
      return next;
    } catch (e, st) {
      state = AsyncError<RuntimeState>(e, st);
      return null;
    }
  }
}

/// 沙盒路径没就绪时不该去碰库与 Key（`main()` 里已经 await 过，这里只是兜底）。
bool get runtimeReady => AppPaths.ready;
