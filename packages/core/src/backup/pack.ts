import type { SqliteDriver } from '../db/driver';
import { currentSchemaVersion, SCHEMA_VERSION } from '../db/migrate';
import { crc32 } from './crc32';
import { open, seal } from './format';
import { buildManifest, mergeManifest } from './manifest';
import type {
  BackupManifest,
  CryptoPort,
  ExportReport,
  ImportReport,
  MediaEntryMeta,
  MediaStorePort,
} from './types';
import { buildZip, readZip, type ZipEntryPlan } from './zip';
import { utf8Decode, utf8Encode } from '../util/utf8';

/**
 * 备份打包 / 解包（技术设计第七节）。
 *
 * 层次从里到外：
 *   manifest.json + media/*  →  ZIP（STORE）  →  分块 AES-256-GCM  →  .findrpack
 *
 * 顺序很重要：**先写媒体、再合并 DB**。媒体写失败时 DB 一个字都没动，
 * 不会留下「卡片在、图片没了」的半吊子状态；反过来则会出现指向空文件的卡片。
 */

const MANIFEST_NAME = 'manifest.json';

export interface BackupDeps {
  db: SqliteDriver;
  crypto: CryptoPort;
  media: MediaStorePort;
  /** 不传则读库里的 schema_version */
  schemaVersion?: number;
  appVersion?: string;
}

export interface ExportOptions {
  passphrase: string;
  now?: Date;
}

export interface ExportResult {
  bytes: Uint8Array;
  report: ExportReport;
}

export async function exportBackup(
  deps: BackupDeps,
  opts: ExportOptions,
): Promise<ExportResult> {
  const now = opts.now ?? new Date();
  const schemaVersion = deps.schemaVersion ?? currentSchemaVersion(deps.db);
  const { manifest, mediaPaths } = buildManifest(deps.db, schemaVersion, now, deps.appVersion);

  // 第一趟：只读一遍媒体算 size/crc，读完就丢——buildZip 需要精确长度来一次性分配输出缓冲
  const mediaPlans: ZipEntryPlan[] = [];
  const mediaMeta: MediaEntryMeta[] = [];
  const mediaMissing: string[] = [];
  for (const path of mediaPaths) {
    const data = await deps.media.read(path);
    if (!data) {
      // 引用存在但文件没了：不阻断导出（否则一张坏卡会让整个备份做不出来），
      // 但要如实报给用户，别让他以为备份是全的
      mediaMissing.push(path);
      continue;
    }
    const entry: ZipEntryPlan = { path, size: data.length, crc32: crc32(data) };
    mediaPlans.push(entry);
    mediaMeta.push({ path, size: entry.size, crc32: entry.crc32 });
  }
  manifest.media = mediaMeta;

  const manifestBytes = utf8Encode(JSON.stringify(manifest));
  const manifestPlan: ZipEntryPlan = {
    path: MANIFEST_NAME,
    size: manifestBytes.length,
    crc32: crc32(manifestBytes),
  };

  // 第二趟：真正组装，逐个文件读入并直接落进输出缓冲
  const zip = await buildZip([manifestPlan, ...mediaPlans], async (path) => {
    if (path === MANIFEST_NAME) return manifestBytes;
    const data = await deps.media.read(path);
    if (!data) throw new Error(`媒体文件在备份过程中消失了：${path}`);
    return data;
  }, now);

  const bytes = await seal(deps.crypto, opts.passphrase, zip);

  return {
    bytes,
    report: {
      cards: manifest.cards.length,
      categories: manifest.categories.length,
      locations: manifest.locations.length,
      aliases: manifest.aliases.length,
      mediaTotal: mediaPaths.length,
      mediaWritten: mediaPlans.length,
      mediaMissing,
      bytes: bytes.length,
    },
  };
}

export interface ImportOptions {
  passphrase: string;
}

export interface ImportResult {
  report: ImportReport;
  /** 包里声明的 schema 版本与导出时间，用于 UI 提示「你正在导入一份 2026-09-18 的备份」 */
  manifestInfo: { schemaVersion: number; exportedAt: string; cards: number; media: number };
}

export function validateManifest(value: unknown): BackupManifest {
  if (!value || typeof value !== 'object') throw new Error('备份清单不是对象');
  const m = value as Partial<BackupManifest>;
  if (m.format !== 'findrpack') throw new Error(`备份清单标识不符：${String(m.format)}`);
  for (const key of ['cards', 'categories', 'locations', 'aliases'] as const) {
    if (!Array.isArray(m[key])) throw new Error(`备份清单缺少数组字段 ${key}`);
  }
  if (typeof m.schemaVersion !== 'number') throw new Error('备份清单缺少 schemaVersion');
  if (m.schemaVersion > SCHEMA_VERSION) {
    throw new Error(
      `这份备份来自更新的版本（schema ${m.schemaVersion} > 本机 ${SCHEMA_VERSION}），请先升级 App 再导入`,
    );
  }
  return value as BackupManifest;
}

export async function importBackup(
  deps: BackupDeps,
  bytes: Uint8Array,
  opts: ImportOptions,
): Promise<ImportResult> {
  // 口令错 / 文件被改过，都会在这里就炸掉，绝不会走到写库那一步
  const zipBytes = await open(deps.crypto, opts.passphrase, bytes);
  const entries = readZip(zipBytes);

  const manifestEntry = entries.find((e) => e.path === MANIFEST_NAME);
  if (!manifestEntry) throw new Error('备份包内缺少 manifest.json');
  const manifest = validateManifest(JSON.parse(utf8Decode(manifestEntry.data)));

  const report = emptyImportShell();
  const mediaEntries = entries.filter((e) => e.path !== MANIFEST_NAME);
  for (const e of mediaEntries) {
    const existed = deps.media.exists
      ? await deps.media.exists(e.path)
      : (await deps.media.read(e.path)) !== null;
    await deps.media.write(e.path, e.data);
    report.mediaWritten++;
    if (existed) report.mediaOverwritten++;
  }

  const merged = mergeManifest(deps.db, manifest);
  const full: ImportReport = {
    ...merged,
    mediaWritten: report.mediaWritten,
    mediaOverwritten: report.mediaOverwritten,
  };

  return {
    report: full,
    manifestInfo: {
      schemaVersion: manifest.schemaVersion,
      exportedAt: manifest.exportedAt ?? '',
      cards: manifest.cards.length,
      media: manifest.media?.length ?? mediaEntries.length,
    },
  };
}

function emptyImportShell(): Pick<ImportReport, 'mediaWritten' | 'mediaOverwritten'> {
  return { mediaWritten: 0, mediaOverwritten: 0 };
}
