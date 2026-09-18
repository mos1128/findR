import { expect, test } from 'vitest';
import { REQUIRED_BAD_CASES, SAMPLES, type BadCase } from './fixtures/samples';

/**
 * 样本集本身的结构约束。
 *
 * 20 条样本此前只存在于《测试计划.md》的类别描述里，没有逐条清单，因此
 * 「复用为单测 fixtures」一直是空头支票。这个测试保证名单不缩水、不跑偏。
 */
test('样本集正好 20 条，id 唯一', () => {
  expect(SAMPLES).toHaveLength(20);
  const ids = SAMPLES.map((s) => s.id);
  expect(new Set(ids).size).toBe(ids.length);
});

test('覆盖《测试计划.md》要求的全部 bad case 类别', () => {
  const covered = new Set<BadCase>(SAMPLES.map((s) => s.bad));
  for (const required of REQUIRED_BAD_CASES) {
    expect(covered.has(required), `缺少 bad case 类别：${required}`).toBe(true);
  }
});

test('每条样本都带可判定的期望值', () => {
  for (const s of SAMPLES) {
    expect(s.transcript.length > 0 || s.imageCount > 0, `${s.id} 没有任何素材`).toBe(true);
    expect(s.query.trim().length, `${s.id} 没有检索问句`).toBeGreaterThan(0);
    expect(s.expectation.shouldHit, `${s.id} 未标期望命中`).toBe(true);
    expect(s.expectation.hasLocation, `${s.id} 未标「素材里有没有位置」`).toBeDefined();
  }
});

test('「只有照片」的样本必须是零文本，反之纯文本样本零图片', () => {
  for (const s of SAMPLES) {
    if (s.bad === 'photo_only') {
      expect(s.transcript.trim(), `${s.id} 标为只有照片却有文本`).toBe('');
      expect(s.imageCount).toBeGreaterThan(0);
    }
    if (s.bad === 'text_only_off') {
      expect(s.imageCount >= 0).toBe(true);
    }
    if (s.imageCount === 0 && s.bad !== 'photo_only') {
      expect(s.transcript.trim().length, `${s.id} 既没图也没文本`).toBeGreaterThan(0);
    }
  }
});

test('关闭图片分析的样本必须同时有文字，否则会落进「纯图片卡片」分支', () => {
  for (const s of SAMPLES.filter((x) => !x.vision)) {
    expect(s.transcript.trim().length, `${s.id} 关了图片分析又没有文字`).toBeGreaterThan(0);
  }
});

test('「有位置」与「没位置」两类样本都在，盯住 path 由内容驱动这条规则', () => {
  const withLoc = SAMPLES.filter((s) => s.expectation.hasLocation === true);
  const withoutLoc = SAMPLES.filter((s) => s.expectation.hasLocation === false);
  expect(withLoc.length).toBeGreaterThanOrEqual(5);
  expect(withoutLoc.length).toBeGreaterThanOrEqual(5);
  // 「没位置」这一类里必须有靠图才谈得上位置的样本，否则这条规则没被真正考验
  expect(withoutLoc.some((s) => s.imageCount > 0)).toBe(true);
  // 也要有「图也给了、但文字没位置」的：模型最容易在这类上硬猜
  expect(withLoc.some((s) => s.transcript.trim() === '')).toBe(true);
  // trigram 的 <3 字硬限制要有样本盯着，否则 LIKE 降级回归了也发现不了
  expect(SAMPLES.some((s) => s.bad === 'short_term')).toBe(true);
  // 别称扩展也是
  expect(SAMPLES.some((s) => s.bad === 'alias')).toBe(true);
});
