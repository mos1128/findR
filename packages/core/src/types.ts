export type StructureType = 'item' | 'todo' | 'procedure';
export type CardStatus = 'pending_transcript' | 'pending' | 'active' | 'archived';
export type SourceKind = 'photo' | 'voice' | 'text';

export interface StepItem {
  text: string;
  done: boolean;
}

export interface MemoryCard {
  id: string;
  status: CardStatus;
  needsConfirm: boolean;
  needsOrganize: boolean;
  structureType: StructureType | null;
  categoryId: string | null;
  entity: string | null;
  pathIds: string[] | null;
  pathNames: string | null;
  itemStatus: 'in_stock' | 'lent' | 'used' | 'discarded' | null;
  todoStatus: 'open' | 'done' | 'dropped' | null;
  procedureStatus: 'draft' | 'ready' | null;
  steps: StepItem[] | null;
  relatedPerson: string | null;
  dueAt: string | null;
  cycle: string | null;
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

export interface Category {
  id: string;
  name: string;
  emoji: string | null;
  description: string | null;
  structureType: StructureType;
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
