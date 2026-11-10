/// 记忆流的界面状态（列表 + 检索 + 答案）。
///
/// **为什么把状态从 widget 里搬出来**：状态散在组件里时，「哪些搜索提示
/// 该显示」这类判断会和渲染缠在一起，只能靠读整屏代码才能确定行为。搬进 Notifier 之后
/// 那套口径有了单一出处，也能在 `flutter test` 里直接对状态断言（不必去点界面）。
///
/// ⚠️ **这里不做检索本身** —— 分路、放宽、兜底全在 core 的 `search/service.dart`。
/// 这一层只负责「记住上一次搜了什么、结果给谁看」。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/runtime.dart';

/// 一次检索的完整现场。
final class SearchView {
  const SearchView({
    required this.query,
    required this.cards,
    this.advice,
    this.note,
    this.usage,
  });

  /// 原话。重搜 / 组织答案都要用它。
  final String query;

  final List<MemoryCard> cards;

  /// 推理题（advise）的裁决结果。**与答案互斥**：推理题的答案就是那次裁决本身。
  final AdviceResult? advice;

  /// 「本次走的是哪条路」。空结果时必须说清，否则用户会把「字面没搜到」读成「卡片丢了」。
  final String? note;

  /// 检索阶段消耗的模型 token 用量（P2 改写或整库裁决）。
  final ChatUsage? usage;

  SearchView copyWith({
    List<MemoryCard>? cards,
    AdviceResult? advice,
    String? note,
    ChatUsage? usage,
  }) => SearchView(
    query: query,
    cards: cards ?? this.cards,
    advice: advice ?? this.advice,
    note: note ?? this.note,
    usage: usage ?? this.usage,
  );
}

/// 首页状态。
final class MemoryStreamState {
  const MemoryStreamState({
    required this.cards,
    required this.categories,
    this.categoryFilter,
    this.loadError,
    this.searching = false,
    this.search,
    this.answer,
    this.answerError,
    this.answering = false,
    this.hasMore = false,
    this.loadingMore = false,
  });

  /// 记忆流（未搜索时显示）。
  final List<MemoryCard> cards;

  final List<Category> categories;

  /// 分类筛选。**与搜索是两件事**：搜索时以结果为准，筛选只影响记忆流。
  final String? categoryFilter;

  /// 读库失败的原因。**不要把整块屏炸掉** —— 自检期间这类错误必须看得见才有意义。
  final String? loadError;

  final bool searching;

  /// 非空 ⇒ 处于「搜索结果」态。
  final SearchView? search;

  final AnswerResult? answer;

  /// 答案没生成出来的原因。**刻意与 [answer] 分开**：
  /// 以前是把错误文本塞进 `answer.answer`，界面就用同样的「AI 答案」样式把一句报错读给用户；
  /// 而且 `answer` 一旦非空，「AI 总结」按钮就消失了 —— 失败之后连重试都没得点。
  final String? answerError;

  final bool answering;

  /// 记忆流还有没有下一页（一页 [memoryStreamLimit] 条）。
  final bool hasMore;

  /// 正在取下一页。
  final bool loadingMore;

  MemoryStreamState copyWith({
    List<MemoryCard>? cards,
    List<Category>? categories,
    Object? categoryFilter = _unset,
    Object? loadError = _unset,
    bool? searching,
    Object? search = _unset,
    Object? answer = _unset,
    Object? answerError = _unset,
    bool? answering,
    bool? hasMore,
    bool? loadingMore,
  }) => MemoryStreamState(
    cards: cards ?? this.cards,
    categories: categories ?? this.categories,
    categoryFilter: identical(categoryFilter, _unset)
        ? this.categoryFilter
        : categoryFilter as String?,
    loadError: identical(loadError, _unset)
        ? this.loadError
        : loadError as String?,
    searching: searching ?? this.searching,
    search: identical(search, _unset) ? this.search : search as SearchView?,
    answer: identical(answer, _unset) ? this.answer : answer as AnswerResult?,
    answerError: identical(answerError, _unset)
        ? this.answerError
        : answerError as String?,
    answering: answering ?? this.answering,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

const Object _unset = Object();

/// 记忆流每页条数。滚动到底部时自动再取一页。
const int memoryStreamLimit = 100;

final memoryStreamProvider =
    AsyncNotifierProvider<MemoryStreamNotifier, MemoryStreamState>(
      MemoryStreamNotifier.new,
    );

final class MemoryStreamNotifier extends AsyncNotifier<MemoryStreamState> {
  /// 检索请求序号：每次发起检索 +1，晚到的旧结果直接丢弃。
  /// 用户搜 B 时，A 的请求可能还在路上；没有这个序号，A 晚归会把 B 顶掉。
  int _searchSeq = 0;
  int _answerSeq = 0;

  @override
  Future<MemoryStreamState> build() async {
    // 依赖运行时快照 ⇒ 设置页保存后 `refresh()` 会让这里自动重建、列表跟着重读。
    final rt = await ref.watch(runtimeProvider.future);
    return _read(rt, categoryFilter: null);
  }

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时还没就绪');
    return v;
  }

  /// 读列表 + 分类。**两件事都用同一个 try 包住**：一次读库失败要给一句完整的原因，
  /// 而不是半屏有数据半屏空白。
  MemoryStreamState _read(RuntimeState rt, {required String? categoryFilter}) {
    try {
      // 多取一条用来判断「还有没有下一页」，避免额外发一次 COUNT。
      final page = listCards(
        rt.driver,
        ListCardsOptions(
          categoryId: categoryFilter,
          limit: memoryStreamLimit + 1,
        ),
      );
      final hasMore = page.length > memoryStreamLimit;
      return MemoryStreamState(
        cards: hasMore ? page.sublist(0, memoryStreamLimit) : page,
        categories: listCategories(rt.driver),
        categoryFilter: categoryFilter,
        hasMore: hasMore,
      );
    } catch (e) {
      return MemoryStreamState(
        cards: const <MemoryCard>[],
        categories: const <Category>[],
        categoryFilter: categoryFilter,
        loadError: '$e',
      );
    }
  }

  /// 取下一页（100 条）。滚动到底部时由界面调用。
  ///
  /// 只作用于「记忆流」；搜索结果是一次性给全的，不做分页。
  Future<void> loadMore() async {
    final prev = state.value;
    if (prev == null ||
        prev.loadingMore ||
        !prev.hasMore ||
        prev.search != null) {
      return;
    }
    state = AsyncData(prev.copyWith(loadingMore: true));
    try {
      final page = listCards(
        _rt.driver,
        ListCardsOptions(
          categoryId: prev.categoryFilter,
          limit: memoryStreamLimit + 1,
          offset: prev.cards.length,
        ),
      );
      final hasMore = page.length > memoryStreamLimit;
      state = AsyncData(
        prev.copyWith(
          cards: <MemoryCard>[...prev.cards, ...page.take(memoryStreamLimit)],
          hasMore: hasMore,
          loadingMore: false,
        ),
      );
    } catch (_) {
      // 取下一页失败不该清空已经显示的列表。同时把 `hasMore` 置 false：
      // 否则列表末尾每次重建都会再触发一次失败的分页请求，形成空转。
      final current = state.value;
      if (current != null) {
        state = AsyncData(current.copyWith(loadingMore: false, hasMore: false));
      }
    }
  }

  /// 重读。录入后、编辑后、导入备份后、切分类后都走它。
  ///
  /// 若当前正处在搜索态，**顺手把同一条 query 重搜一遍** ——
  /// 否则用户刚改完一张卡，退回来看到的还是修改前的结果（而卡片是新的），
  /// 那种「列表说一套、结果说另一套」的矛盾比多跑一次检索贵得多。
  Future<void> reload() async {
    final prev = state.value;
    // 不主动切 loading：保存一下设置整页闪成转圈很烦，列表本身是好的
    state = AsyncData(
      _read(
        _rt,
        categoryFilter: prev?.categoryFilter,
      ).copyWith(search: prev?.search, answer: prev?.answer),
    );
    final q = prev?.search?.query;
    if (q != null && q.isNotEmpty) await search(q, clearAnswer: false);
  }

  void setCategory(String? categoryId) {
    final prev = state.value;
    if (prev == null) return;
    state = AsyncData(_read(_rt, categoryFilter: categoryId));
  }

  /// 检索。走哪条路全在 core，这里只负责把 `SearchResult` 的四个提示位翻译成人话。
  ///
  /// 方法名刻意叫 `search` 而不是 `runSearch` —— 后者是 `platform/runtime.dart` 里的
  /// 顶层函数，同名会让「界面方法」与「运行时入口」互相遮蔽，读起来极易错。
  Future<void> search(String rawQuery, {bool clearAnswer = true}) async {
    final q = rawQuery.trim();
    if (q.isEmpty) return;
    final prev = state.value;
    if (prev == null) return;

    // 先占号：这次检索之后发起的任何一次都会让本次结果作废。
    final seq = ++_searchSeq;
    // 旧答案属于旧问题，立刻作废
    _answerSeq++;

    state = AsyncData(
      prev.copyWith(
        searching: true,
        search: SearchView(
          query: q,
          cards: prev.search?.cards ?? const <MemoryCard>[],
        ),
        answer: clearAnswer ? null : prev.answer,
        answerError: null,
      ),
    );

    try {
      final res = await runSearch(_rt, q);
      // 晚到的旧请求：直接丢弃，别覆盖用户后发的那次结果
      if (seq != _searchSeq) return;
      final current = state.value;
      if (current == null) return;

      // 提示语顺序有讲究：advice 的 usedFallback 含义与普通检索**不同**
      //（这里是「模型没从库里挑出直接相关的」，不是「模型不可达」），所以先判它。
      String? note;
      if (res.advice != null) {
        note = res.usedFallback ? '模型没挑出直接相关的内容，下面是字面命中的条目。' : null;
      } else if (res.relaxed == true) {
        note = '模型给的条件太严（分类 / 时间 / 位置 / 全词命中），已放宽。';
      } else if (res.unclear) {
        note = res.cards.isEmpty ? '模型没听懂这句话，换个说法试试。' : '模型没听懂，已退回字面检索，结果可能不全。';
      } else if (res.usedFallback) {
        note = llmConfigured(_rt.llm)
            ? '模型不可达，已退回字面检索（无同义词扩展、无分类/位置约束）。'
            : '还没配模型，按字面检索。多个关键词用空格分开更准。';
      }

      state = AsyncData(
        current.copyWith(
          searching: false,
          search: SearchView(
            query: q,
            cards: res.cards,
            advice: res.advice,
            note: note,
            usage: res.usage,
          ),
        ),
      );
    } catch (e) {
      if (seq != _searchSeq) return;
      final current = state.value;
      if (current == null) return;
      state = AsyncData(
        current.copyWith(
          searching: false,
          search: SearchView(
            query: q,
            cards: const <MemoryCard>[],
            note: '检索失败：$e',
          ),
        ),
      );
    }
  }

  void clearSearch() {
    // 清空搜索 = 作废所有在途检索与答案
    _searchSeq++;
    _answerSeq++;
    final prev = state.value;
    if (prev == null) return;
    state = AsyncData(
      prev.copyWith(
        search: null,
        answer: null,
        answerError: null,
        searching: false,
        answering: false,
      ),
    );
  }

  /// 需求 5.3：L2 只在「本地无结果」或「用户手动触发」时跑，**不是每次搜索都跑**。
  Future<void> requestAnswer(String query, List<MemoryCard> cards) async {
    final prev = state.value;
    if (prev == null) return;
    final seq = ++_answerSeq;
    state = AsyncData(prev.copyWith(answering: true, answerError: null));
    try {
      final res = await runAnswer(_rt, query, cards);
      // 期间用户换了问题 / 重新检索 ⇒ 这份答案已经不属于当前结果
      if (seq != _answerSeq) return;
      final current = state.value;
      if (current == null) return;
      state = AsyncData(
        current.copyWith(
          answering: false,
          // 真的没总结出内容 ≠ 总结失败：报错不占答案位，按钮留着让人重试
          answer: res.ok ? res : null,
          answerError: res.ok ? null : (res.error ?? '模型没有返回可用的内容。'),
        ),
      );
    } catch (e) {
      if (seq != _answerSeq) return;
      final current = state.value;
      if (current == null) return;
      // 未配模型时 requireDeps 会抛 —— 必须接住，否则是一次未处理的异常
      state = AsyncData(current.copyWith(answering: false, answerError: '$e'));
    }
  }

  /// 推进入库队列（回前台 / 录完一条之后）。
  Future<QueueRunResult?> drainQueue({bool? vision}) async {
    final rt = _rt;
    final res = await runQueueNow(rt, vision: vision);
    await reload();
    return res;
  }
}
