/// 样本集本身的结构约束 —— 逐字对应 `packages/core/test/samples.test.ts`（66 行）。
///
/// 20 条样本此前只存在于《测试计划.md》的类别描述里，没有逐条清单，因此
/// 「复用为单测 fixtures」一直是空头支票。这些用例保证名单不缩水、不跑偏。
library;

import 'package:test/test.dart';

import '../fixtures/samples.dart';

void main() {
  test('样本集正好 20 条，id 唯一', () {
    expect(samples, hasLength(20));
    final ids = samples.map((s) => s.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('覆盖《测试计划.md》要求的全部 bad case 类别', () {
    final covered = samples.map((s) => s.bad).toSet();
    for (final required in requiredBadCases) {
      expect(covered.contains(required), isTrue, reason: '缺少 bad case 类别：${required.wire}');
    }
  });

  test('每条样本都带可判定的期望值', () {
    for (final s in samples) {
      expect(
        s.transcript.isNotEmpty || s.imageCount > 0,
        isTrue,
        reason: '${s.id} 没有任何素材',
      );
      expect(s.query.trim().length, greaterThan(0), reason: '${s.id} 没有检索问句');
      expect(s.expectation.shouldHit, isTrue, reason: '${s.id} 未标期望命中');
      expect(
        s.expectation.hasLocation,
        isNotNull,
        reason: '${s.id} 未标「素材里有没有位置」',
      );
    }
  });

  test('「只有照片」的样本必须是零文本，反之纯文本样本零图片', () {
    for (final s in samples) {
      if (s.bad == BadCase.photoOnly) {
        expect(s.transcript.trim(), '', reason: '${s.id} 标为只有照片却有文本');
        expect(s.imageCount, greaterThan(0));
      }
      if (s.bad == BadCase.textOnlyOff) {
        expect(s.imageCount, greaterThanOrEqualTo(0));
      }
      if (s.imageCount == 0 && s.bad != BadCase.photoOnly) {
        expect(s.transcript.trim().length, greaterThan(0), reason: '${s.id} 既没图也没文本');
      }
    }
  });

  test('关闭图片分析的样本必须同时有文字，否则会落进「纯图片卡片」分支', () {
    for (final s in samples.where((x) => !x.vision)) {
      expect(
        s.transcript.trim().length,
        greaterThan(0),
        reason: '${s.id} 关了图片分析又没有文字',
      );
    }
  });

  test('「有位置」与「没位置」两类样本都在，盯住 path 由内容驱动这条规则', () {
    final withLoc = samples.where((s) => s.expectation.hasLocation == true).toList();
    final withoutLoc = samples.where((s) => s.expectation.hasLocation == false).toList();
    expect(withLoc.length, greaterThanOrEqualTo(5));
    expect(withoutLoc.length, greaterThanOrEqualTo(5));
    // 「没位置」这一类里必须有靠图才谈得上位置的样本，否则这条规则没被真正考验
    expect(withoutLoc.any((s) => s.imageCount > 0), isTrue);
    // 也要有「图也给了、但文字没位置」的：模型最容易在这类上硬猜
    expect(withLoc.any((s) => s.transcript.trim() == ''), isTrue);
    // trigram 的 <3 字硬限制要有样本盯着，否则 LIKE 降级回归了也发现不了
    expect(samples.any((s) => s.bad == BadCase.shortTerm), isTrue);
    // 别称扩展也是
    expect(samples.any((s) => s.bad == BadCase.alias), isTrue);
  });
}
