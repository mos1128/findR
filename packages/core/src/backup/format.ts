/**
 * .findrpack 容器：**明文**。布局见《技术设计.md》第七节。
 *
 *   magic "FINDR"(5B) + format version u16 (=1) + 载荷（标准 ZIP，STORE 不压缩）
 *
 * ⚠️ **当前版本不做任何加密**（2026-09-20 决策）：载荷就是原样的 ZIP，
 * 拿到文件的人用任何解压工具都能直接读到全部记忆。所以导出/导入的界面必须
 * 把这件事说清楚，别让用户以为它是加密的。
 *
 * 那为什么还留这 7 字节的头？为了**版本判别**：将来把加密加回来时，
 * 加密文件的载荷不再是 ZIP，读取侧需要一个可靠的判据来决定走哪条路。
 * 到时候把 `FORMAT_VERSION` 提到 2（载荷 = salt ‖ nonce_base ‖ 分块密文）即可，
 * 头本身不动。**别在加加密之前动这个头** —— 现在改了，将来就没有判据可用。
 *
 * 完整性：明文没有 GCM tag 兜底，靠 ZIP 每个成员的 CRC32（见 `zip.ts` 的 `readZip`）。
 * 也就是说「截断 / 写坏 / 传输出错」能被抓到（会明确报「校验和不符」），
 * 但「有人有意改过内容再改回 CRC」抓不到 —— 这是明文方案的固有代价，不是 bug。
 */

export const MAGIC = 'FINDR';
/** 1 = 明文 ZIP 载荷。加密回归时提为 2，载荷格式另定 */
export const FORMAT_VERSION = 1;
export const HEADER_LEN = MAGIC.length + 2;

export function encodeHeader(formatVersion = FORMAT_VERSION): Uint8Array {
  const out = new Uint8Array(HEADER_LEN);
  for (let i = 0; i < MAGIC.length; i++) out[i] = MAGIC.charCodeAt(i);
  new DataView(out.buffer).setUint16(MAGIC.length, formatVersion, true);
  return out;
}

function decodeHeader(bytes: Uint8Array): { formatVersion: number } {
  if (bytes.length < HEADER_LEN) throw new Error('备份文件过短，不是有效的 .findrpack');
  for (let i = 0; i < MAGIC.length; i++) {
    if (bytes[i] !== MAGIC.charCodeAt(i)) throw new Error('备份文件标识不符，不是 .findrpack 文件');
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const formatVersion = view.getUint16(MAGIC.length, true);
  if (formatVersion !== FORMAT_VERSION) {
    throw new Error(`备份格式版本 ${formatVersion} 不被支持（当前支持 ${FORMAT_VERSION}）`);
  }
  return { formatVersion };
}

/** 载荷 → 完整 .findrpack 字节（头 + 载荷）。纯拼接，不做任何变换。 */
export function packContainer(payload: Uint8Array): Uint8Array {
  const header = encodeHeader();
  const out = new Uint8Array(header.length + payload.length);
  out.set(header, 0);
  out.set(payload, header.length);
  return out;
}

/** .findrpack 字节 → 载荷。头不对 / 版本不认 / 文件被截断都会在这里抛错。 */
export function unpackContainer(bytes: Uint8Array): Uint8Array {
  decodeHeader(bytes);
  return bytes.subarray(HEADER_LEN);
}
