export type CardStatus = 'pending_transcript' | 'pending' | 'active' | 'archived';
export type SourceKind = 'photo' | 'voice' | 'text';

export interface StepItem {
  text: string;
  done: boolean;
}

/**
 * 一条记忆卡片。
 *
 * 关于「卡片长什么样」，这里刻意**只有 `categoryId` 一个组织维度**：
 * 早期版本还有 `structureType`（item/todo/procedure）与三个业务状态
 * （`itemStatus`/`todoStatus`/`procedureStatus`），用来决定字段必填性和卡片强调色。
 * 真机验证后确认这套东西对检索零影响、又逼着用户理解一套模型自己的概念，
 * 已于 2026-09-18 整体移除（见 `db/schema.ts` 的 v2 迁移）。
 *
 * 代价与替代：原来「物品必须有位置」靠 `structureType === 'item'` 判定，
 * 现在改成**由内容驱动** —— 模型在内容确实提到存放位置时才填 `path`，
 * 确实是一串步骤时才填 `steps`，缺关键信息则由 `ask` 追问。
 * 这比按类型一刀切更贴近真实口述（「把护照放回主卧抽屉」既是待办也带位置）。
 */
export interface MemoryCard {
  id: string;
  status: CardStatus;
  needsOrganize: boolean;
  categoryId: string | null;
  entity: string | null;
  pathIds: string[] | null;
  pathNames: string | null;
  steps: StepItem[] | null;
  transcript: string | null;
  desc: string | null;
  images: string[] | null;
  audioPath: string | null;
  visionAnalyzed: boolean | null;
  tags: string[] | null;
  confidence: number | null;
  /** P1 补问文案；非空时记忆流展示补问入口，用户编辑后清空（需求 5.1「最多一次」） */
  ask: string | null;
  /** 位置失配时模型给出的完整路径猜测，供用户点选或新建 */
  pathSuggestion: string | null;
  /** 本次 path 是否命中已有位置树（测试计划指标依据） */
  pathMatched: boolean | null;
  source: SourceKind;
  retryCount: number;
  nextRetryAt: string | null;
  lastError: string | null;
  createdAt: string;
  updatedAt: string;
}

/**
 * 分类：用户唯一的组织桶，也是 P1 自动路由的目标池。
 *
 * 以前每个分类还绑一个 `structureType` 来推导卡片形状，现已去掉 ——
 * 分类就是分类，卡片是「东西 / 待办 / 流程」由内容自己决定。
 */
export interface Category {
  id: string;
  name: string;
  emoji: string | null;
  description: string | null;
  sort: number;
  isPreset: boolean;
}

export interface LocationNode {
  id: string;
  parentId: string | null;
  name: string;
  sort: number;
}

export interface AliasEntry {
  id: string;
  kind: 'entity' | 'location';
  name: string;
  cardId: string | null;
  locationId: string | null;
}
