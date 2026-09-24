/// 检索编排。
///
/// 这是「用户问一句话 → 拿到卡片」的总入口，把四件事串起来：
/// P2 规划 → 本地字面检索（含逐级放宽）→ （推理题）整库裁决 → 字面兜底。
///
/// **贯穿全文件的一条原则：字面检索是一等公民。**
/// 没配模型、模型不可达、模型说听不懂 —— 三条路都必须还能用本地 FTS/LIKE 搜出东西，
/// 因为字面检索本来就不依赖模型。隐私优先、长期离线、只想当本地记事本的用户，
/// 是**一等公民而不是残废状态**。
library;

import '../db/driver.dart';
import '../db/repository.dart';
import '../parse/model_json.dart';
import '../parse/outputs.dart';
import '../parse/schema.dart';
import '../prompts/render.dart';
import '../providers/types.dart';
import '../types.dart';
import 'advise.dart';
import 'builder.dart';
import 'inventory.dart';

final class SearchDeps {
  const SearchDeps({required this.db, this.llm, this.cfg});

  final SqliteDriver db;

  /// 未配置主模型时为 null。
  ///
  /// 此时**跳过 P2、直接走字面兜底** —— 与「配了模型但端点不可达」是同一条路。
  /// 字面检索（FTS + LIKE）本来就不依赖模型，不该因为没配模型而整条检索不可用。
  final LlmProviderAdapter? llm;

  final ProviderConfig? cfg;
}

final class SearchResult {
  const SearchResult({
    required this.cards,
    required this.usedFallback,
    required this.unclear,
    required this.p2,
    this.relaxed,
    this.advice,
    this.usage,
  });

  final List<MemoryCard> cards;

  /// P2 失败 / 无网 / 未配模型时走原始 query 直查（需求 5.3 L1 兜底）。
  final bool usedFallback;

  /// intent 识别不出来（或没给出可用关键词），UI 应提示换种说法。
  final bool unclear;

  final P2Output? p2;

  /// 严格条件 0 命中、靠**放宽约束**（去分类 / 去时间位置 / all→any）才拿到的结果。
  /// UI 必须说明：这批结果比用户原话宽，不说明就会被误当成「严格匹配」。
  final bool? relaxed;

  /// 推理题（advise）的裁决结果。有值时 [cards] 是**裁决后**的清单
  /// （必需在前、看情况在后），不再是字面命中 —— UI 必须据此换一套呈现。
  final AdviceResult? advice;

  /// 搜索过程中的 AI token 用量（包含 P2 改写或推理题裁决）。
  final ChatUsage? usage;
}

Future<SearchResult> searchCards(SearchDeps deps, String query) async {
  P2Output? p2;
  ChatUsage? p2Usage;
  final llm = deps.llm;
  final cfg = deps.cfg;
  // 没有模型 ⇒ 跳过 P2、直接走字面兜底。这里**绝不能抛错**：抛了连字面检索都没了。
  // 「配了模型但端点不通」走的是兜底，「压根不想配模型」却全废 —— 同一件事两条路，
  // 而且更常见的那条（隐私优先 / 长期离线）反而更不可用，这是实现走偏，不是设计意图。
  if (llm != null && cfg != null) {
    try {
      final system = buildP2System(
        categories: formatCategoriesForPrompt(listCategories(deps.db)),
        locations: formatLocationsForPrompt(listLocations(deps.db)),
      );
      final res = await llm.chat(
        ChatRequest(
          system: system,
          parts: <Part>[TextPart(query)],
          temperature: 0.1,
        ),
        cfg,
      );
      p2Usage = res.usage;
      final parsed = parseModelJson(res.text, P2OutputSchema.tryParse);
      if (parsed is ParseOk<P2Output>) p2 = parsed.value;
    } catch (_) {
      p2 = null;
    }
  }

  // 取个局部 final 再判空：p2 是「可能多次赋值」的局部变量，
  // 拿一份不可变的副本进来，后面几处的类型提升才稳。
  final plan = p2;

  // 推理题：答案不在库里，字面检索对这类问题**必然 0 条**，改走「整库清单 → 模型裁决」。
  // 必须放在下面的关键词检查**之前** —— advise 模式下 keywords 恒为空，
  // 否则会被当成「模型没听懂」而退化，正是要修的那个毛病。
  if (plan != null && plan.mode == SearchMode.advise) {
    return _adviseSearch(deps, query, plan, p2Usage: p2Usage);
  }

  if (plan != null && plan.intent != P2Intent.unknown && plan.keywords.isNotEmpty) {
    final expanded = expandTermsByAliases(deps.db, <String>[
      ...plan.keywords,
      ...plan.synonyms,
    ]);
    final built = buildSearch(
      p2: plan.withSynonyms(<String>{...plan.synonyms, ...expanded}.toList()),
      resolveCategoryId: (name) => resolveCategoryId(deps.db, name),
    );
    if (built != null) {
      final strict = executeSearch(deps.db, built);
      if (strict.isNotEmpty) {
        return SearchResult(
          cards: strict,
          usedFallback: false,
          unclear: false,
          p2: plan,
          usage: p2Usage,
        );
      }

      // 严格条件一条都没命中 ⇒ 逐级放宽再试。
      // 放宽**只跑本地 SQL，不额外调用模型**，所以在真机上几乎没有额外延迟。
      // 顺序与理由见 `builder.dart` 的 [relaxations]。
      for (final relaxed in relaxations(built)) {
        final got = executeSearch(deps.db, relaxed);
        if (got.isNotEmpty) {
          return SearchResult(
            cards: got,
            usedFallback: false,
            unclear: false,
            p2: plan,
            relaxed: true,
            usage: p2Usage,
          );
        }
      }
      // 放宽也救不回来 —— 说明约束不是问题，是真的没有
      // （放宽逻辑的回归用例见 `test/search/builder_test.dart`）
      return SearchResult(
        cards: const <MemoryCard>[],
        usedFallback: false,
        unclear: false,
        p2: plan,
        usage: p2Usage,
      );
    }
  }

  // 走到这里 = 没配模型 / P2 调用失败 / P2 说听不懂 / 关键词为空 ⇒ 一律退回**字面兜底**。
  //
  // 「听不懂」也要按用户原话再字面搜一遍，搜不到再说搜不到 ——
  // 否则「配了模型但模型没听懂」会比「压根没配模型」还不可用，
  // 同一件事两条路，而后者明明有兜底。
  return SearchResult(
    cards: executeSearch(deps.db, buildRawSearch(query)),
    usedFallback: true,
    unclear: plan != null,
    p2: plan,
    usage: p2Usage,
  );
}

/// 推理题（advise）的执行：整库清单 → 模型逐条裁决。
///
/// 与定位题的差别不只在 prompt，还在**返回的 cards 从何而来**：
/// 定位题的 cards 是本地 SQL 命中的；这里的 cards 是模型挑出来的
/// （必需在前、看情况在后），**可能一条都没有** —— 那也是一种正确答案
/// （「你库里没有适合这次出行的东西，你还缺转换插头」）。
Future<SearchResult> _adviseSearch(
  SearchDeps deps,
  String query,
  P2Output p2, {
  ChatUsage? p2Usage,
}) async {
  final llm = deps.llm;
  final cfg = deps.cfg;
  // 调用方已用 `llm != null && cfg != null` 保证非空，这里只是把类型收窄
  if (llm == null || cfg == null) {
    return SearchResult(
      cards: const <MemoryCard>[],
      usedFallback: true,
      unclear: false,
      p2: p2,
      usage: p2Usage,
    );
  }

  // 排序提示词：优先用 P2 给出的「这个情景通常需要什么类别」（`aspects` 是通用名词，
  // 命中率最高），再补情景描述与用户原句。**排序必须在截断之前**，
  // 否则库一大，「最近的 200 条」就会把去年记的护照挤出清单（见 `inventory.dart`）。
  final inventory = buildInventory(
    deps.db,
    terms: <String?>[...p2.aspects, p2.scenario ?? '', query],
  );
  // 空库没必要花一次调用：没有任何库存，「你需要什么」无从谈起
  if (inventory.cards.isEmpty) {
    return SearchResult(
      cards: const <MemoryCard>[],
      usedFallback: false,
      unclear: false,
      p2: p2,
      usage: p2Usage,
      advice: const AdviceResult(
        ok: true,
        answer: '记忆库还是空的，先记一条再问我。',
      ),
    );
  }

  final trimmedScenario = (p2.scenario ?? '').trim();
  final scenario = trimmedScenario.isNotEmpty ? trimmedScenario : query;

  final res = await adviseFromInventory(
    AdviceDeps(llm: llm, cfg: cfg),
    query,
    scenario,
    inventory,
  );
  final totalUsage = (p2Usage ?? const ChatUsage()) + res.usage;

  if (!res.ok) {
    // 裁决失败 ⇒ 退到字面兜底，与「模型不可达」同一条路，并让 UI 说明走的是哪条
    return SearchResult(
      cards: executeSearch(deps.db, buildRawSearch(query)),
      usedFallback: true,
      unclear: false,
      p2: p2,
      usage: totalUsage,
    );
  }

  final picked = <AdviceItem>[...res.picks, ...res.maybe];
  if (picked.isNotEmpty) {
    return SearchResult(
      cards: picked.map((item) => item.card).toList(),
      usedFallback: false,
      unclear: false,
      p2: p2,
      advice: res,
      usage: totalUsage,
    );
  }

  // 裁决一条都没挑中。这可能是真的（库里确实没有适合这次出行的东西），
  // 也可能是 P2 把一道定位题误判成了推理题。
  // 本地字面检索是**零成本、零延迟**的，顺手跑一次：它若命中了东西，就把这批结果
  // 一并给出（advice 仍然保留，答案与 missing 照常显示），
  // 别让一个模型判断变成一次静默的空结果 —— 与「模型不可达必退字面兜底」是同一条原则。
  final literal = executeSearch(deps.db, buildRawSearch(query));
  if (literal.isNotEmpty) {
    return SearchResult(
      cards: literal,
      usedFallback: true,
      unclear: false,
      p2: p2,
      advice: res,
      usage: totalUsage,
    );
  }

  return SearchResult(
    cards: const <MemoryCard>[],
    usedFallback: false,
    unclear: false,
    p2: p2,
    advice: res,
    usage: totalUsage,
  );
}
