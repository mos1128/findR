import Database from 'better-sqlite3';
import type { SqliteDriver } from '../src/db/driver';
import { migrate } from '../src/db/migrate';
import type { MemoryCard } from '../src/types';
import { nodeDriver } from './node-driver';

export function makeDb(): SqliteDriver {
  const raw = new Database(':memory:');
  const db = nodeDriver(raw);
  migrate(db);
  return db;
}

export function makeCard(p: Partial<MemoryCard> & { id: string }): MemoryCard {
  return {
    id: p.id,
    status: p.status ?? 'active',
    needsConfirm: p.needsConfirm ?? false,
    needsOrganize: p.needsOrganize ?? false,
    structureType: p.structureType ?? 'item',
    categoryId: p.categoryId ?? 'cat_item',
    entity: p.entity ?? '测试实体',
    pathIds: p.pathIds ?? null,
    pathNames: p.pathNames ?? null,
    itemStatus: p.itemStatus ?? null,
    todoStatus: p.todoStatus ?? null,
    procedureStatus: p.procedureStatus ?? null,
    steps: p.steps ?? null,
    relatedPerson: p.relatedPerson ?? null,
    dueAt: p.dueAt ?? null,
    cycle: p.cycle ?? null,
    transcript: p.transcript ?? null,
    desc: p.desc ?? null,
    images: p.images ?? null,
    audioPath: p.audioPath ?? null,
    visionAnalyzed: p.visionAnalyzed ?? null,
    tags: p.tags ?? null,
    confidence: p.confidence ?? null,
    source: p.source ?? 'text',
    retryCount: p.retryCount ?? 0,
    nextRetryAt: p.nextRetryAt ?? null,
    lastError: p.lastError ?? null,
    createdAt: p.createdAt ?? '2026-01-01T00:00:00.000Z',
    updatedAt: p.updatedAt ?? '2026-01-01T00:00:00.000Z',
  };
}
