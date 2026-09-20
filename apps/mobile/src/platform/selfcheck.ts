import { Directory, File, Paths } from 'expo-file-system';
import {
  exportBackup,
  makeId,
  migrate,
  packContainer,
  readZip,
  resolveCategoryId,
  unpackContainer,
  utf8Decode,
  utf8Encode,
} from '@findr/core';
import type { SqliteDriver } from '@findr/core';

import { deviceMediaStore } from './media';

export interface CheckResult {
  name: string;
  ok: boolean;
  /** 通过时是观测值，失败时是错误信息 */
  detail: string;
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/**
 * 真机自检：把 M1 里「只在设备上才会暴露」的假设一次性验掉。
 * 全程不写业务表（只在临时表里做增删，结束即 DROP），可以随时跑。
 */
export function runSelfCheck(db: SqliteDriver): CheckResult[] {
  const results: CheckResult[] = [];
  const check = (name: string, fn: () => string) => {
    try {
      results.push({ name, ok: true, detail: fn() });
    } catch (e) {
      results.push({ name, ok: false, detail: message(e) });
    }
  };

  check('打开数据库并应用 PRAGMA', () => {
    const journal = db.prepare('PRAGMA journal_mode').get() as { journal_mode?: string };
    const fk = db.prepare('PRAGMA foreign_keys').get() as { foreign_keys?: number };
    if (fk?.foreign_keys !== 1) throw new Error('foreign_keys 未开启');
    return `journal_mode=${journal?.journal_mode ?? '?'} foreign_keys=${fk.foreign_keys}`;
  });

  check('migrate() 建表并记录 schema_version', () => {
    migrate(db);
    const row = db
      .prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'")
      .get() as { value?: string };
    if (!row?.value) throw new Error('schema_version 缺失');
    return `schema_version=${row.value}`;
  });

  check('预设分类已播种', () => {
    const row = db.prepare("SELECT COUNT(*) AS n FROM categories WHERE is_preset = 1").get() as {
      n?: number;
    };
    if (!row?.n) throw new Error('预设分类数为 0');
    return `is_preset 分类 ${row.n} 条`;
  });

  check('FTS5 模块可用（建虚拟表）', () => {
    db.exec('DROP TABLE IF EXISTS __findr_fts');
    db.exec("CREATE VIRTUAL TABLE __findr_fts USING fts5(body, tokenize='trigram')");
    return 'fts5 + trigram 建表成功';
  });

  check('trigram 命中中文子串（≥3 字）', () => {
    db.prepare('INSERT INTO __findr_fts (body) VALUES (?)').run('备用手电筒放在主卧衣柜顶层');
    const rows = db.prepare('SELECT body FROM __findr_fts WHERE __findr_fts MATCH ?').all('衣柜顶');
    if (rows.length === 0) throw new Error('3 字子串未命中');
    return `MATCH '衣柜顶' → ${rows.length} 行`;
  });

  check('trigram 对 <3 字词不命中（预期，故有 LIKE 降级）', () => {
    let hits = 0;
    try {
      hits = db.prepare('SELECT body FROM __findr_fts WHERE __findr_fts MATCH ?').all('衣柜').length;
    } catch {
      // 部分版本直接报错，同样说明该词不能走 FTS
      return 'MATCH 2 字词报错，符合预期';
    }
    if (hits > 0) throw new Error('2 字词竟然命中了，降级策略的前提不成立');
    return "MATCH '衣柜' → 0 行，符合预期";
  });

  check('LIKE 降级能兜住 <3 字词', () => {
    const rows = db
      .prepare("SELECT body FROM __findr_fts WHERE body LIKE ? ESCAPE '\\'")
      .all('%衣柜%');
    if (rows.length === 0) throw new Error('LIKE 未命中');
    return "LIKE '%衣柜%' → 1 行";
  });

  check('cards_fts 外部内容表已建立', () => {
    const row = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cards_fts'")
      .get();
    if (!row) throw new Error('cards_fts 不存在');
    db.exec('DROP TABLE IF EXISTS __findr_fts');
    return 'cards_fts 存在';
  });

  check('事务 BEGIN / COMMIT 生效', () => {
    db.exec('DROP TABLE IF EXISTS __findr_sc');
    db.exec('CREATE TABLE __findr_sc (v TEXT)');
    db.transaction(() => {
      db.prepare('INSERT INTO __findr_sc (v) VALUES (?)').run('a');
    });
    const n = (db.prepare('SELECT COUNT(*) AS n FROM __findr_sc').get() as { n?: number }).n;
    if (n !== 1) throw new Error(`期望 1 行，实际 ${n}`);
    return '提交后可见 1 行';
  });

  check('嵌套事务走 SAVEPOINT（内层回滚不影响外层）', () => {
    db.transaction(() => {
      db.prepare('INSERT INTO __findr_sc (v) VALUES (?)').run('outer');
      try {
        db.transaction(() => {
          db.prepare('INSERT INTO __findr_sc (v) VALUES (?)').run('inner');
          throw new Error('故意回滚内层');
        });
      } catch {
        // 预期
      }
    });
    const vals = (db.prepare('SELECT v FROM __findr_sc ORDER BY v').all() as { v: string }[]).map(
      (r) => r.v,
    );
    if (vals.length !== 2 || !vals.includes('a') || !vals.includes('outer')) {
      throw new Error(`期望 [a, outer]，实际 [${vals.join(', ')}]`);
    }
    if (vals.includes('inner')) throw new Error('内层写入未被回滚');
    return '外层保留、内层已回滚';
  });

  check('外键约束确实拦截非法引用', () => {
    let rejected = false;
    try {
      db.prepare('INSERT INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)').run(
        '__sc_loc',
        '__sc_missing_parent',
        '自检占位',
        0,
      );
    } catch {
      rejected = true;
    }
    if (!rejected) {
      db.prepare('DELETE FROM locations WHERE id = ?').run('__sc_loc');
      throw new Error('非法 parent_id 竟然写入成功，外键没生效');
    }
    db.exec('DROP TABLE IF EXISTS __findr_sc');
    return '非法 parent_id 被拒';
  });

  check('分类名归一化（容忍 emoji / 标点变体）', () => {
    const hit = db.prepare('SELECT name FROM categories WHERE name = ?').get('物品存取') as
      | { name?: string }
      | undefined;
    if (!hit) return '无「物品存取」分类，跳过';
    const id = resolveCategoryId(db, '📍 物品存取');
    if (!id) throw new Error("resolveCategoryId('📍 物品存取') 返回 null");
    return `命中 ${id}`;
  });

  check('makeId() 可用', () => {
    const hasUuid = typeof (globalThis as { crypto?: { randomUUID?: () => string } }).crypto
      ?.randomUUID === 'function';
    const a = makeId();
    const b = makeId();
    if (!a || a === b) throw new Error(`id 重复或为空：${a} / ${b}`);
    return `crypto.randomUUID ${hasUuid ? '可用' : '不可用（已走兜底）'}，样例 ${a.slice(0, 12)}`;
  });

  return results;
}

// ─────────────────────────────────────────────────────────────
// M4 备份自检（异步：要读真实文件系统）
// ─────────────────────────────────────────────────────────────

const toHex = (b: Uint8Array) =>
  Array.from(b)
    .map((x) => x.toString(16).padStart(2, '0'))
    .join('');

/**
 * 备份链路的真机自检。
 *
 * 为什么单独做一份：备份是**唯一会真的碰文件系统的功能**（读全库媒体、写探针文件），
 * 而 node 测试里跑的是内存媒体库 —— 「设备上真的能把图画进包里吗」只有这里能答。
 *
 * 当前版本不加密，所以这组检查不测加解密，测的是三件真机上才成立的事：
 *   - 真机文件系统上媒体端口的读写（含二进制字节原样往返）；
 *   - **整库真打一次包**：读全库 → 逐个读媒体 → ZIP → 容器头 → 再解包读回清单，
 *     卡片数与报告对得上（这一条等于把导出链路整条走一遍）；
 *   - 容器头的标识/版本校验真的会拦住不相干的文件。
 *
 * 全程只读业务表；唯一写的是一份跑完即删的媒体探针。可以随时跑。
 */
export async function runBackupSelfCheck(db: SqliteDriver): Promise<CheckResult[]> {
  const results: CheckResult[] = [];

  const check = async (name: string, fn: () => Promise<string> | string) => {
    try {
      results.push({ name, ok: true, detail: await fn() });
    } catch (e) {
      results.push({ name, ok: false, detail: message(e) });
    }
  };

  await check('媒体端口读写往返（真实文件系统）', async () => {
    const rel = '__selfcheck/probe.bin';
    const probe = new Uint8Array([0, 1, 2, 250, 251, 252, 253, 254, 255]);
    const file = new File(Paths.document, ...rel.split('/'));
    try {
      deviceMediaStore.write(rel, probe);
      const back = await deviceMediaStore.read(rel);
      if (!back) throw new Error('写完立刻读却是 null');
      if (toHex(back) !== toHex(probe)) throw new Error('读回内容不一致');
      // exists 在端口里是可选的（不实现则退化），设备端实现了，这里断言一下它真的在
      if (!(await deviceMediaStore.exists!(rel))) throw new Error('exists() 返回 false');
      if ((await deviceMediaStore.read('__selfcheck/不存在.bin')) !== null) {
        throw new Error('不存在的路径应返回 null');
      }
      return `写入并读回 ${probe.length} 字节一致`;
    } finally {
      const parent = file.parentDirectory;
      if (file.exists) file.delete();
      if (parent instanceof Directory && parent.exists) parent.delete();
    }
  });

  await check('整库打包 → 解包 → 读回清单（走完整条导出链路）', async () => {
    const t = Date.now();
    // 只读：exportBackup 不写任何表；媒体那侧只读不写
    const { bytes, report } = await exportBackup(
      { db, media: deviceMediaStore },
      { now: new Date() },
    );
    const entry = readZip(unpackContainer(bytes)).find((e) => e.path === 'manifest.json');
    if (!entry) throw new Error('包内没有 manifest.json');
    const manifest = JSON.parse(utf8Decode(entry.data)) as { cards?: unknown[] };
    const cards = Array.isArray(manifest.cards) ? manifest.cards.length : -1;
    if (cards !== report.cards) {
      throw new Error(`清单里的卡片数 ${cards} 与报告里的 ${report.cards} 对不上`);
    }
    return (
      `卡片 ${report.cards} · 分类 ${report.categories} · 位置 ${report.locations} · ` +
      `别名 ${report.aliases} · 媒体 ${report.mediaWritten}/${report.mediaTotal} · ` +
      `整包 ${report.bytes} 字节 · 耗时 ${Date.now() - t} ms`
    );
  });

  await check('容器头能拦住不相干的文件', async () => {
    // 中文 + emoji 走一遍，顺带验 Hermes 上的 utf8 编解码
    const payload = utf8Encode('findr 自检 🧭 中文');
    if (utf8Decode(unpackContainer(packContainer(payload))) !== utf8Decode(payload)) {
      throw new Error('容器往返内容不一致');
    }

    let rejectedShort = false;
    try {
      unpackContainer(new Uint8Array(64));
    } catch {
      rejectedShort = true;
    }
    if (!rejectedShort) throw new Error('乱码文件竟然通过了头部校验');

    const badMagic = packContainer(new Uint8Array([1]));
    badMagic[0] ^= 0x01;
    let rejectedMagic = false;
    try {
      unpackContainer(badMagic);
    } catch {
      rejectedMagic = true;
    }
    if (!rejectedMagic) throw new Error('标识被人改过竟然通过了校验');

    const badVersion = packContainer(new Uint8Array([1]));
    new DataView(badVersion.buffer).setUint16(5, 99, true);
    let rejectedVersion = false;
    try {
      unpackContainer(badVersion);
    } catch {
      rejectedVersion = true;
    }
    if (!rejectedVersion) throw new Error('未知格式版本竟然通过了校验');

    return '标识 / 版本校验都在拦人';
  });

  return results;
}
