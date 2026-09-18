import { crc32 } from './crc32';
import type { MaybePromise } from './types';

/**
 * 最小 ZIP 读写（**只支持 STORE，不压缩**）。
 *
 * 为什么不用 jszip / fflate / zlib：
 *   - 明文整包随后会被 AES-256-GCM 加密，媒体（webp / m4a）本身已是压缩格式，
 *     deflate 在这里几乎不省字节，却要拖进来一个依赖；
 *   - core 的既定约束是零 RN 依赖、平台能力全走注入，而 Hermes 上没有 zlib；
 *   - STORE 是 ZIP 规范里最简单的一档，写+读不到 200 行，且产物是**标准 zip**，
 *     用户拿 7-Zip 就能打开自检（调试价值）。
 *
 * 读取侧刻意只认 method=0：本格式只由我们自己写，遇到 deflate 说明文件被人重新压过，
 * 与其猜不如直接报错——解不开的包比悄悄导入一半更危险。
 */

const LOCAL_SIG = 0x04034b50;
const CENTRAL_SIG = 0x02014b50;
const EOCD_SIG = 0x06054b50;

const METHOD_STORE = 0;
/** bit 11 = 文件名按 UTF-8 解释；我们的名字全是 ASCII，置上只是为了让别的工具不猜错 */
const FLAG_UTF8 = 0x0800;
const VERSION_NEEDED = 20;
const MAX_U32 = 0xffffffff;
const EOCD_MIN = 22;
const MAX_COMMENT = 0xffff;

export interface ZipEntryPlan {
  /** 包内路径，必须 ASCII（我们的用法是 manifest.json 与 files/...） */
  path: string;
  size: number;
  crc32: number;
}

export interface ZipReadEntry {
  path: string;
  data: Uint8Array;
}

/**
 * 名字只走 ASCII 单字节编解码。
 * 不用 TextEncoder/TextDecoder 是因为 Hermes 上它们不保证存在，而文件名本来就不需要多字节。
 */
function encodeName(name: string): Uint8Array {
  const out = new Uint8Array(name.length);
  for (let i = 0; i < name.length; i++) {
    const code = name.charCodeAt(i);
    if (code > 0x7f) throw new Error(`备份包内路径含非 ASCII 字符：${name}`);
    out[i] = code;
  }
  return out;
}

function decodeName(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] > 0x7f) throw new Error('备份包内出现非 ASCII 路径，无法解析');
    s += String.fromCharCode(bytes[i]);
  }
  return s;
}

function dosDateTime(d: Date): { time: number; date: number } {
  // ZIP 的 DOS 时间戳：秒只存偶数（2 秒精度），年份从 1980 起算
  const time = ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xffff;
  const year = d.getFullYear() - 1980;
  const date = (((year < 0 ? 0 : year) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xffff;
  return { time, date };
}

export function planZipSize(entries: readonly ZipEntryPlan[]): number {
  let total = EOCD_MIN;
  for (const e of entries) {
    const nameLen = encodeName(e.path).length;
    total += 30 + nameLen + e.size; // local header + name + 数据
    total += 46 + nameLen; // central directory 条目
  }
  return total;
}

/**
 * 按 entries 里已声明的 size/crc32 组装 zip。
 * 数据通过 readEntry 按需取——这样调用方可以「每个文件读一次就写进去」，
 * 峰值内存只有 输出缓冲 + 单个文件，而不是把所有媒体同时握在手里。
 * readEntry 允许返回 Promise：设备端读文件是异步的，这里顺序 await 即可。
 */
export async function buildZip(
  entries: readonly ZipEntryPlan[],
  readEntry: (path: string) => MaybePromise<Uint8Array>,
  mtime: Date,
): Promise<Uint8Array> {
  const { time, date } = dosDateTime(mtime);
  const names = entries.map((e) => encodeName(e.path));
  const total = planZipSize(entries);
  if (total > MAX_U32) throw new Error('备份包超过 4GB，当前 ZIP 写入器不支持 ZIP64');

  const out = new Uint8Array(total);
  const view = new DataView(out.buffer);
  let p = 0;
  const offsets: number[] = [];

  const u16 = (v: number) => {
    view.setUint16(p, v, true);
    p += 2;
  };
  const u32 = (v: number) => {
    view.setUint32(p, v, true);
    p += 4;
  };

  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    const name = names[i];
    offsets.push(p);

    u32(LOCAL_SIG);
    u16(VERSION_NEEDED);
    u16(FLAG_UTF8);
    u16(METHOD_STORE);
    u16(time);
    u16(date);
    u32(e.crc32);
    u32(e.size);
    u32(e.size);
    u16(name.length);
    u16(0);
    out.set(name, p);
    p += name.length;

    const data = await readEntry(e.path);
    if (data.length !== e.size) {
      throw new Error(`媒体文件在两次读取之间变长/变短了：${e.path}`);
    }
    out.set(data, p);
    p += data.length;
  }

  const cdOffset = p;
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    const name = names[i];
    u32(CENTRAL_SIG);
    u16(VERSION_NEEDED);
    u16(VERSION_NEEDED);
    u16(FLAG_UTF8);
    u16(METHOD_STORE);
    u16(time);
    u16(date);
    u32(e.crc32);
    u32(e.size);
    u32(e.size);
    u16(name.length);
    u16(0); // extra
    u16(0); // comment
    u16(0); // disk start
    u16(0); // internal attrs
    u32(0); // external attrs
    u32(offsets[i]);
    out.set(name, p);
    p += name.length;
  }
  const cdSize = p - cdOffset;

  u32(EOCD_SIG);
  u16(0);
  u16(0);
  u16(entries.length);
  u16(entries.length);
  u32(cdSize);
  u32(cdOffset);
  u16(0);

  if (p !== total) throw new Error(`ZIP 组装长度不符：预期 ${total}，实际 ${p}`);
  return out;
}

function findEocd(bytes: Uint8Array): number {
  const min = Math.max(0, bytes.length - (EOCD_MIN + MAX_COMMENT));
  for (let i = bytes.length - EOCD_MIN; i >= min; i--) {
    if (
      bytes[i] === (EOCD_SIG & 0xff) &&
      bytes[i + 1] === ((EOCD_SIG >>> 8) & 0xff) &&
      bytes[i + 2] === ((EOCD_SIG >>> 16) & 0xff) &&
      bytes[i + 3] === ((EOCD_SIG >>> 24) & 0xff)
    ) {
      return i;
    }
  }
  throw new Error('备份包内容不是有效 ZIP：找不到中央目录结尾');
}

export function readZip(bytes: Uint8Array): ZipReadEntry[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const eocd = findEocd(bytes);
  const count = view.getUint16(eocd + 10, true);
  const cdOffset = view.getUint32(eocd + 16, true);
  const cdSize = view.getUint32(eocd + 12, true);
  if (cdOffset + cdSize > bytes.length) throw new Error('备份包内容不是有效 ZIP：中央目录越界');

  const out: ZipReadEntry[] = [];
  let p = cdOffset;
  for (let i = 0; i < count; i++) {
    if (view.getUint32(p, true) !== CENTRAL_SIG) throw new Error('备份包内容不是有效 ZIP：中央目录条目损坏');
    const method = view.getUint16(p + 10, true);
    const expectedCrc = view.getUint32(p + 16, true);
    const size = view.getUint32(p + 24, true);
    const nameLen = view.getUint16(p + 28, true);
    const extraLen = view.getUint16(p + 30, true);
    const commentLen = view.getUint16(p + 32, true);
    const localOffset = view.getUint32(p + 42, true);
    const name = decodeName(bytes.subarray(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;

    if (method !== METHOD_STORE) {
      throw new Error(`备份包内 ${name} 使用了压缩存储（method=${method}），本实现只支持 STORE`);
    }
    if (view.getUint32(localOffset, true) !== LOCAL_SIG) {
      throw new Error(`备份包内容不是有效 ZIP：${name} 的本地头损坏`);
    }
    const localNameLen = view.getUint16(localOffset + 26, true);
    const localExtraLen = view.getUint16(localOffset + 28, true);
    const dataStart = localOffset + 30 + localNameLen + localExtraLen;
    if (dataStart + size > bytes.length) throw new Error(`备份包内容不是有效 ZIP：${name} 数据越界`);

    const data = bytes.subarray(dataStart, dataStart + size);
    if (crc32(data) !== expectedCrc) throw new Error(`备份包内 ${name} 校验和不符，文件已损坏`);
    out.push({ path: name, data });
  }
  return out;
}
