import type { Category, LocationNode, MemoryCard } from '../types';
import {
  ASK_RULES,
  DESC_RULES,
  P1_FEWSHOT,
  P1_SCHEMA,
  P1_SYSTEM,
  P1_TEXT_ONLY_OFF,
  P1_TEXT_ONLY_UNSUPPORTED,
  P1_USER,
  P2_FEWSHOT,
  P2_RULES,
  P2_SYSTEM,
  P2_OUTPUT_SCHEMA,
  P3_INPUT_TEMPLATE,
  P3_SCHEMA,
  P3_SYSTEM,
} from './templates';

export function render(template: string, vars: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_m, k: string) => vars[k] ?? '');
}

export function buildP1System(ctx: {
  categories: string;
  locations: string;
  textOnly?: 'off' | 'unsupported';
}): string {
  let s = render(P1_SYSTEM, { categories: ctx.categories, locations: ctx.locations });
  s += '\n\n输出 schema（字段名与类型不得改动）：\n' + P1_SCHEMA;
  s += '\n\n' + DESC_RULES + '\n\n' + ASK_RULES + '\n\n示例：\n' + P1_FEWSHOT;
  if (ctx.textOnly === 'off') s += '\n\n' + P1_TEXT_ONLY_OFF;
  else if (ctx.textOnly === 'unsupported') s += '\n\n' + P1_TEXT_ONLY_UNSUPPORTED;
  return s;
}

export function buildP1User(transcript: string | null): string {
  return render(P1_USER, {
    transcript: transcript ?? '（本次没有文字输入，请仅根据图片判断。）',
  });
}

/** 把卡片已确认的结构化字段渲染成「既定事实」清单 */
export function describeCardFields(card: MemoryCard): string {
  const lines: string[] = [];
  const push = (label: string, value: string | null | undefined) => {
    if (value) lines.push(`- ${label}：${value}`);
  };
  push('分类', card.categoryId ? undefined : undefined); // 分类名由调用方按 id 解析，这里不注入
  push('实体名', card.entity);
  push('位置', card.pathNames);
  push('标签', card.tags?.join('、'));
  push('步骤', card.steps?.map((s) => s.text).join('；'));
  return lines.join('\n');
}

/**
 * 编辑结构化字段后重新生成 desc（需求四「编辑闭环」）。
 * 把用户已确认的字段作为既定事实注入，避免模型又按自己的理解改写回去。
 * 文案与规则见《prompt设计.md》一「重新生成 desc」。
 */
export function buildRegenerateDescUser(card: MemoryCard): string {
  const base = buildP1User(card.transcript);
  const locked = describeCardFields(card);
  if (!locked) return base;
  return `${base}\n\n用户已确认以下字段，请视为既定事实，不要改动，只重新生成 desc：\n${locked}`;
}

export function buildP2System(ctx: { categories: string; locations: string }): string {
  return (
    render(P2_SYSTEM, { categories: ctx.categories, locations: ctx.locations }) +
    '\n\n输出 schema：\n' +
    P2_OUTPUT_SCHEMA +
    '\n\n规则：\n' +
    P2_RULES +
    '\n\n示例：\n' +
    P2_FEWSHOT
  );
}

export function buildP3System(): string {
  return P3_SYSTEM + '\n\n输出 schema：\n' + P3_SCHEMA;
}

export function buildP3Input(query: string, snippets: string): string {
  return render(P3_INPUT_TEMPLATE, { query, snippets });
}

export function formatCategoriesForPrompt(categories: Category[]): string {
  if (categories.length === 0) return '（暂无）';
  return categories
    .map((c) => `- ${c.emoji ?? ''}${c.name}${c.description ? '：' + c.description : ''}`)
    .join('\n');
}

/** 注入策略：只注入一二级（房间 → 家具），三级容器不注入 */
export function formatLocationsForPrompt(locations: LocationNode[]): string {
  if (locations.length === 0) return '（暂无）';
  const byId = new Map(locations.map((l) => [l.id, l]));
  const fullPath = (l: LocationNode): string => {
    const names: string[] = [];
    let cur: LocationNode | undefined = l;
    while (cur) {
      names.unshift(cur.name);
      cur = cur.parentId ? byId.get(cur.parentId) : undefined;
    }
    return names.join('/');
  };
  const depth = (l: LocationNode): number => {
    let d = 0;
    let cur: LocationNode | undefined = l;
    while (cur?.parentId) {
      cur = byId.get(cur.parentId);
      d++;
    }
    return d + 1;
  };
  return locations
    .filter((l) => depth(l) <= 2)
    .map((l) => fullPath(l))
    .join('\n');
}
