import { describe, expect, it } from 'vitest';
import {
  exportBackup,
  importBackup,
  open,
  readZip,
  utf8Decode,
  validateManifest,
  HEADER_LEN,
  SALT_LEN,
  NONCE_BASE_LEN,
  type BackupDeps,
  type BackupManifest,
} from '../src';
import { getCard, insertCard, listCards, upsertLocation } from '../src/db/repository';
import { setSetting } from '../src/db/settings';
import { audioRelPath, imageRelPath } from '../src/media/paths';
import { makeCard, makeDb } from './helpers';
import { memoryMedia, nodeCrypto, type MemoryMedia } from './node-crypto';

const PASS = 'correct horse battery staple';
const AT = new Date('2026-09-18T04:00:00.000Z');

const IMG = imageRelPath(AT, 'c1', 0);
const AUDIO = audioRelPath(AT, 'c2');
const IMG_BYTES = Uint8Array.from([1, 2, 3, 4, 5, 250, 251]);
const AUDIO_BYTES = Uint8Array.from([9, 8, 7, 6]);

interface Side {
  deps: BackupDeps;
  media: MemoryMedia;
}

function sourceSide(): Side {
  const db = makeDb();
  const media = memoryMedia({ [IMG]: IMG_BYTES, [AUDIO]: AUDIO_BYTES });

  upsertLocation(db, { id: 'loc1', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'loc2', parentId: 'loc1', name: '衣柜', sort: 0 });

  insertCard(
    db,
    makeCard({
      id: 'c1',
      entity: '手电筒',
      desc: '备用手电筒放在主卧衣柜顶层',
      images: [IMG],
      pathIds: ['loc1', 'loc2'],
      pathNames: '主卧/衣柜',
      tags: ['照明'],
      updatedAt: '2026-09-01T00:00:00.000Z',
      createdAt: '2026-09-01T00:00:00.000Z',
    }),
  );
  insertCard(
    db,
    makeCard({
      id: 'c2',
      entity: '买牙膏',
      structureType: 'todo',
      categoryId: 'cat_todo',
      todoStatus: 'open',
      audioPath: AUDIO,
      source: 'voice',
      status: 'pending_transcript',
      updatedAt: '2026-09-02T00:00:00.000Z',
      createdAt: '2026-09-02T00:00:00.000Z',
    }),
  );
  db.prepare("INSERT INTO aliases (id, kind, name, card_id) VALUES (?, 'entity', ?, ?)").run(
    'al1',
    '电筒',
    'c1',
  );

  return { deps: { db, crypto: nodeCrypto(), media }, media };
}

function targetSide(): Side {
  const db = makeDb();
  const media = memoryMedia();
  return { deps: { db, crypto: nodeCrypto(), media }, media };
}

async function exportFrom(side: Side) {
  return await exportBackup(side.deps, { passphrase: PASS, now: AT });
}

/** 解出包里的 manifest，用来检查「不该出现的东西有没有出现」 */
async function manifestOf(bytes: Uint8Array, passphrase = PASS): Promise<BackupManifest> {
  const zip = await open(sideCrypto(), passphrase, bytes);
  const entry = readZip(zip).find((e) => e.path === 'manifest.json');
  if (!entry) throw new Error('测试前提不成立：包里没有 manifest.json');
  return JSON.parse(utf8Decode(entry.data)) as BackupManifest;
}

function sideCrypto() {
  return nodeCrypto();
}

describe('备份格式：容器头', () => {
  it('头部长度与布局符合技术设计七（magic 5 + u16 + salt 16 + nonce_base 12）', async () => {
    const { bytes } = await exportFrom(sourceSide());
    expect(HEADER_LEN).toBe(5 + 2 + SALT_LEN + NONCE_BASE_LEN);
    expect(String.fromCharCode(...bytes.slice(0, 5))).toBe('FINDR');
    expect(new DataView(bytes.buffer, bytes.byteOffset).getUint16(5, true)).toBe(1);
    expect(bytes.length).toBeGreaterThan(HEADER_LEN);
  });

  it('非本格式的文件会被明确拒绝', async () => {
    const side = targetSide();
    await expect(
      importBackup(side.deps, new Uint8Array(64), { passphrase: PASS }),
    ).rejects.toThrow(/不是 \.findrpack/);
  });
});

describe('备份：round-trip', () => {
  it('导出再导入后，卡片/分类/位置/别名与媒体文件都一致', async () => {
    const src = sourceSide();
    const { bytes, report } = await exportFrom(src);

    expect(report.cards).toBe(2);
    expect(report.mediaTotal).toBe(2);
    expect(report.mediaWritten).toBe(2);
    expect(report.mediaMissing).toEqual([]);

    const dst = targetSide();
    const { report: ir, manifestInfo } = await importBackup(dst.deps, bytes, {
      passphrase: PASS,
    });

    expect(ir.cardsInserted).toBe(2);
    expect(manifestInfo.cards).toBe(2);

    const c1 = getCard(dst.deps.db, 'c1');
    expect(c1?.entity).toBe('手电筒');
    expect(c1?.images).toEqual([IMG]);
    expect(c1?.pathIds).toEqual(['loc1', 'loc2']);
    expect(c1?.pathNames).toBe('主卧/衣柜');

    const c2 = getCard(dst.deps.db, 'c2');
    expect(c2?.status).toBe('pending_transcript');
    expect(c2?.source).toBe('voice');
    expect(c2?.todoStatus).toBe('open');

    const locs = dst.deps.db.prepare('SELECT id, parent_id FROM locations ORDER BY id').all();
    expect(locs).toEqual([
      { id: 'loc1', parent_id: null },
      { id: 'loc2', parent_id: 'loc1' },
    ]);

    const alias = dst.deps.db
      .prepare('SELECT name, card_id FROM aliases WHERE id = ?')
      .get('al1');
    expect(alias).toEqual({ name: '电筒', card_id: 'c1' });

    expect(dst.media.files.get(IMG)).toEqual(IMG_BYTES);
    expect(dst.media.files.get(AUDIO)).toEqual(AUDIO_BYTES);
  });

  it('同一份包导入两次是幂等的，第二次不动任何数据', async () => {
    const { bytes } = await exportFrom(sourceSide());
    const dst = targetSide();
    await importBackup(dst.deps, bytes, { passphrase: PASS });
    const second = await importBackup(dst.deps, bytes, { passphrase: PASS });

    expect(second.report.cardsInserted).toBe(0);
    expect(second.report.cardsUpdated).toBe(0);
    expect(second.report.cardsKeptLocal).toBe(2);
    expect(listCards(dst.deps.db)).toHaveLength(2);
  });
});

describe('备份：安全边界', () => {
  it('口令错误必须失败，且不落任何数据', async () => {
    const { bytes } = await exportFrom(sourceSide());
    const dst = targetSide();
    await expect(importBackup(dst.deps, bytes, { passphrase: '错的' })).rejects.toThrow();
    expect(listCards(dst.deps.db)).toHaveLength(0);
    expect(dst.media.files.size).toBe(0);
  });

  it('密文被篡改必须失败（GCM tag 校验）', async () => {
    const { bytes } = await exportFrom(sourceSide());
    const tampered = bytes.slice();
    tampered[tampered.length - 1] ^= 0x01;
    const dst = targetSide();
    await expect(importBackup(dst.deps, tampered, { passphrase: PASS })).rejects.toThrow();
    expect(listCards(dst.deps.db)).toHaveLength(0);
  });

  it('文件被截断必须失败', async () => {
    const { bytes } = await exportFrom(sourceSide());
    const dst = targetSide();
    await expect(
      importBackup(dst.deps, bytes.slice(0, bytes.length - 5), { passphrase: PASS }),
    ).rejects.toThrow();
  });

  it('导出产物里绝不出现 API Key 或白名单外的设置项', async () => {
    const src = sourceSide();
    setSetting(src.deps.db, 'llm', {
      providerType: 'anthropic',
      model: 'claude-opus-5',
      apiKey: 'sk-LEAK-CANARY-1234567890',
    });
    setSetting(src.deps.db, 'tracking_id', { installId: 'CANARY-TRACKING' });

    const { bytes } = await exportFrom(src);
    const manifest = await manifestOf(bytes);
    const dump = JSON.stringify(manifest);

    expect(dump).not.toContain('sk-LEAK-CANARY-1234567890');
    expect(dump).not.toContain('CANARY-TRACKING');
    expect(manifest.settings).toHaveProperty('llm');
    expect(manifest.settings).not.toHaveProperty('tracking_id');
  });

  it('库里引用了但磁盘上已不存在的媒体：不阻断导出，但要如实报告', async () => {
    const src = sourceSide();
    src.media.files.delete(AUDIO);
    const { report } = await exportFrom(src);
    expect(report.mediaMissing).toEqual([AUDIO]);
    expect(report.mediaWritten).toBe(1);
  });
});

describe('备份：导入合并策略', () => {
  it('不删除本地独有的数据', async () => {
    const { bytes } = await exportFrom(sourceSide());
    const dst = targetSide();
    insertCard(
      dst.deps.db,
      makeCard({ id: 'local-only', entity: '只有本机有', updatedAt: '2026-09-10T00:00:00.000Z' }),
    );

    await importBackup(dst.deps, bytes, { passphrase: PASS });

    const ids = listCards(dst.deps.db).map((c) => c.id);
    expect(ids).toContain('local-only');
    expect(ids).toContain('c1');
  });

  it('同 id 冲突时 updated_at 新者胜（外来更新 → 覆盖）', async () => {
    const src = sourceSide();
    const { bytes } = await exportFrom(src);

    const dst = targetSide();
    insertCard(
      dst.deps.db,
      makeCard({ id: 'c1', entity: '本机的旧版本', updatedAt: '2026-08-01T00:00:00.000Z' }),
    );
    const { report } = await importBackup(dst.deps, bytes, { passphrase: PASS });

    expect(report.cardsUpdated).toBe(1);
    expect(getCard(dst.deps.db, 'c1')?.entity).toBe('手电筒');
  });

  it('同 id 冲突时 updated_at 新者胜（本地更新 → 保留）', async () => {
    const src = sourceSide();
    const { bytes } = await exportFrom(src);

    const dst = targetSide();
    insertCard(
      dst.deps.db,
      makeCard({ id: 'c1', entity: '本机的新版本', updatedAt: '2026-12-31T00:00:00.000Z' }),
    );
    const { report } = await importBackup(dst.deps, bytes, { passphrase: PASS });

    expect(report.cardsKeptLocal).toBe(1);
    expect(getCard(dst.deps.db, 'c1')?.entity).toBe('本机的新版本');
  });

  it('分类同名冲突：保留本地分类，并把卡片的 category_id 重映射到本地 id', async () => {
    const src = sourceSide();
    // 造一个与外来的 cat_item 同名但不同 id 的本地分类，制造冲突
    // 把本地那条预设的 id 改掉，名字留着 —— 于是外来包的 cat_item 会撞上「同名不同 id」
    const dst = targetSide();
    dst.deps.db
      .prepare("UPDATE categories SET id = 'local_item', description = '本地版本' WHERE id = 'cat_item'")
      .run();

    // 需要一个引用 cat_item 的卡：用 c2 之外的物品卡
    insertCard(
      src.deps.db,
      makeCard({ id: 'c3', entity: '螺丝刀', categoryId: 'cat_item', updatedAt: '2026-09-03T00:00:00.000Z' }),
    );
    const { bytes } = await exportFrom(src);

    const { report } = await importBackup(dst.deps, bytes, { passphrase: PASS });

    expect(report.conflicts.some((c) => c.kind === 'category' && c.name === '物品存取')).toBe(true);
    expect(getCard(dst.deps.db, 'c3')?.categoryId).toBe('local_item');
    // 本地那条同名分类还在，没有被覆盖
    expect(
      dst.deps.db.prepare("SELECT id FROM categories WHERE name = '物品存取'").all(),
    ).toEqual([{ id: 'local_item' }]);
  });

  it('位置的父链会随重映射一起改写，path_names 跟着重算', async () => {
    const src = sourceSide();
    const { bytes } = await exportFrom(src);

    // 目标库里已有同名同父的『主卧』，但 id 不同 → 冲突 + 重映射
    const dst = targetSide();
    upsertLocation(dst.deps.db, { id: 'local_wz', parentId: null, name: '主卧', sort: 0 });

    const { report } = await importBackup(dst.deps, bytes, { passphrase: PASS });

    expect(report.conflicts.some((c) => c.kind === 'location' && c.name === '主卧')).toBe(true);
    const card = getCard(dst.deps.db, 'c1');
    expect(card?.pathIds).toEqual(['local_wz', 'loc2']);
    expect(card?.pathNames).toBe('主卧/衣柜');
    const child = dst.deps.db
      .prepare('SELECT parent_id FROM locations WHERE id = ?')
      .get('loc2') as { parent_id: string };
    expect(child.parent_id).toBe('local_wz');
  });

  it('本地已有设置不被外来包冲掉，缺失的设置才会补上', async () => {
    const src = sourceSide();
    setSetting(src.deps.db, 'pipeline', { confirmThreshold: 0.9 });
    setSetting(src.deps.db, 'capture', { visionDefault: false, visionLast: false, maxAnalyzeImages: 6 });
    const { bytes } = await exportFrom(src);

    const dst = targetSide();
    setSetting(dst.deps.db, 'pipeline', { confirmThreshold: 0.1 });

    const { report } = await importBackup(dst.deps, bytes, { passphrase: PASS });

    expect(report.settingsKeptLocal).toBe(1);
    expect(report.settingsWritten).toBe(1);
    expect(
      JSON.parse(
        (dst.deps.db.prepare("SELECT value FROM settings WHERE key = 'pipeline'").get() as {
          value: string;
        }).value,
      ),
    ).toEqual({ confirmThreshold: 0.1 });
    expect(
      JSON.parse(
        (dst.deps.db.prepare("SELECT value FROM settings WHERE key = 'capture'").get() as {
          value: string;
        }).value,
      ),
    ).toEqual({ visionDefault: false, visionLast: false, maxAnalyzeImages: 6 });
  });
});

describe('备份：manifest 校验', () => {
  it('包里 schema 版本比本机新时必须拒绝导入', () => {
    const base = {
      format: 'findrpack',
      formatVersion: 1,
      schemaVersion: 999,
      exportedAt: AT.toISOString(),
      cards: [],
      categories: [],
      locations: [],
      aliases: [],
      settings: {},
      media: [],
    };
    expect(() => validateManifest(base)).toThrow(/更新的版本/);
  });

  it('缺少必需数组字段时拒绝', () => {
    expect(() => validateManifest({ format: 'findrpack', schemaVersion: 1 })).toThrow(/缺少数组字段/);
    expect(() => validateManifest({ format: 'wrong', schemaVersion: 1 })).toThrow(/标识不符/);
  });
});
