import * as Sharing from 'expo-sharing';
import Constants from 'expo-constants';
import { Directory, File, Paths } from 'expo-file-system';
import {
  exportBackup,
  importBackup,
  type ExportReport,
  type ImportResult,
  type SqliteDriver,
} from '@findr/core';

import { deviceMediaStore } from './media';

/**
 * 备份的「文件那一半」：把 core 产出的 .findrpack 字节落成设备上的文件、递出去、选回来。
 *
 * core 只负责「字节进字节出」（pack.ts），落在哪个目录、怎么给用户，是平台层的事。
 * 全库媒体只在两端各读一遍，中间不复制 —— 导出峰值内存 ≈ 整包 + 单文件。
 *
 * ⚠️ **包里没有任何加密**（2026-09-20 决策，见 core 的 backup/format.ts）：
 * 它就是一层壳 + 标准 ZIP，拿到文件的人直接就能读到全部记忆。
 * 所以这个文件只能往用户自己信得过的地方递，加密要等后续版本。
 */

export const BACKUP_EXT = '.findrpack';
export const BACKUP_MIME = 'application/octet-stream';

/** 放 cache 而不是 document：它是「待递出去的临时产物」，系统清理它无所谓 */
const BACKUP_DIR = 'backups';
const KEEP_BACKUPS = 3;

function backupDir(): Directory {
  return new Directory(Paths.cache, BACKUP_DIR);
}

function stamp(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

/** 递出去之后这文件就没用了，只留最近几个，免得反复导出把 cache 越堆越大 */
function purgeOldBackups(dir: Directory): void {
  try {
    const packs = dir
      .list()
      .filter((e): e is File => e instanceof File && e.name.startsWith('findr-') && e.name.endsWith(BACKUP_EXT))
      .sort((a, b) => b.name.localeCompare(a.name));
    for (const stale of packs.slice(KEEP_BACKUPS)) stale.delete();
  } catch {
    // 清理失败不该让导出失败
  }
}

export interface ExportOutcome {
  /** 文件在设备上的 URI，交给分享面板用 */
  uri: string;
  fileName: string;
  report: ExportReport;
}

export type ExportPhase = 'packing' | 'writing';

/**
 * 导出。
 *
 * `onPhase` 只报「打包」和「落盘」两段：core 的 exportBackup 是一整块（读全库 →
 * 逐个读媒体 → ZIP → 套容器头），中间不给回调，所以不假装能报得更细。
 * 现在最慢的是**把全库媒体逐个读进内存并拼进 ZIP**（图片多的库要几秒），
 * 界面靠秒表交代「还在动」，不靠进度条。
 */
export async function exportToFile(
  db: SqliteDriver,
  onPhase?: (p: ExportPhase) => void,
): Promise<ExportOutcome> {
  const now = new Date();

  onPhase?.('packing');
  const { bytes, report } = await exportBackup(
    {
      db,
      media: deviceMediaStore,
      appVersion: Constants.expoConfig?.version,
    },
    { now },
  );

  onPhase?.('writing');
  const dir = backupDir();
  if (!dir.exists) dir.create({ intermediates: true });
  const file = new File(dir, `findr-${stamp(now)}${BACKUP_EXT}`);
  if (file.exists) file.delete();
  file.create();
  file.write(bytes);
  purgeOldBackups(dir);

  return { uri: file.uri, fileName: file.name, report };
}

export async function canShare(): Promise<boolean> {
  try {
    return await Sharing.isAvailableAsync();
  } catch {
    return false;
  }
}

/** 打开系统分享面板。用户在这里可以「发送到微信 / 保存到云盘 / 存到文件」。 */
export async function shareBackup(uri: string, fileName: string): Promise<void> {
  await Sharing.shareAsync(uri, {
    mimeType: BACKUP_MIME,
    dialogTitle: `导出 Findr 备份（${fileName}）`,
    UTI: 'public.data',
  });
}

/**
 * 让用户挑一个备份文件。
 *
 * 刻意用「全部类型」通配的 MIME 而不是限定成 octet-stream：Android 对自定义后缀
 * `.findrpack` 的类型判定不可靠，一旦限定，就会出现「文件明明在，选择器里却是灰的」。
 * 真正的把关放在 core 的 magic 校验里 —— 挑错文件会得到一句人话
 * （「不是有效的 .findrpack 文件」），比让人压根找不到文件好得多。
 */
export async function pickBackupFile(): Promise<File | null> {
  const res = await File.pickFileAsync({ mimeTypes: '*/*' });
  if (res.canceled) return null;
  return res.result;
}

/**
 * 从挑到的文件里读整包字节。
 *
 * 直读失败时先复制到本地再读：从微信/云盘「转存」过来的文件是 `content://` 虚拟文档，
 * 偶尔拿不到可读流。复制失败就把**原始错误**抛出去 —— 别把「读不出」和「复制不了」
 * 混成一句含糊的话，那会让排查从几分钟变成几小时。
 */
export async function readBackupBytes(file: File): Promise<Uint8Array> {
  try {
    return await file.bytes();
  } catch (original) {
    try {
      const dir = backupDir();
      if (!dir.exists) dir.create({ intermediates: true });
      const local = new File(dir, `import${BACKUP_EXT}`);
      if (local.exists) local.delete();
      await file.copy(local, { overwrite: true });
      try {
        return await local.bytes();
      } finally {
        if (local.exists) local.delete();
      }
    } catch {
      throw original;
    }
  }
}

/**
 * 导入。core 侧的顺序是「先写媒体、再合并 DB」，所以这里不需要额外的事务包装 ——
 * 媒体写失败时 DB 一个字都没动。导入**不会删除本地任何数据**（同 id 按 updated_at 新者胜）。
 */
export async function importFromBytes(db: SqliteDriver, bytes: Uint8Array): Promise<ImportResult> {
  return await importBackup({ db, media: deviceMediaStore }, bytes);
}
