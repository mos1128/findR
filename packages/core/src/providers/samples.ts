import { bytesToBase64 } from '../util/base64';

/**
 * 能力探测用的微型样本，运行时生成而非往仓库里塞二进制：
 * PNG 走「存储型 deflate 块」（免实现压缩），WAV 是无损 PCM，两者都是确定性的。
 */

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function adler32(bytes: Uint8Array): number {
  let a = 1;
  let b = 0;
  for (let i = 0; i < bytes.length; i++) {
    a = (a + bytes[i]) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

function pngChunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

/** zlib 容器 + 存储型 deflate 块（不压缩，省掉实现 deflate 的必要） */
function zlibStored(raw: Uint8Array): Uint8Array {
  const parts: Uint8Array[] = [new Uint8Array([0x78, 0x01])];
  let offset = 0;
  do {
    const len = Math.min(65535, raw.length - offset);
    const last = offset + len >= raw.length ? 1 : 0;
    const header = new Uint8Array(5);
    header[0] = last;
    header[1] = len & 0xff;
    header[2] = (len >>> 8) & 0xff;
    header[3] = ~len & 0xff;
    header[4] = (~len >>> 8) & 0xff;
    parts.push(header, raw.subarray(offset, offset + len));
    offset += len;
  } while (offset < raw.length);
  const adler = new Uint8Array(4);
  new DataView(adler.buffer).setUint32(0, adler32(raw));
  parts.push(adler);
  return concat(parts);
}

/** 64×64 灰度 PNG（棋盘图案，避免全平图被当成占位符），约 4KB */
export function makeTestPng(size = 64): Uint8Array {
  const ihdr = new Uint8Array(13);
  const view = new DataView(ihdr.buffer);
  view.setUint32(0, size);
  view.setUint32(4, size);
  ihdr[8] = 8; // 位深
  ihdr[9] = 0; // 颜色类型：灰度

  const raw = new Uint8Array(size * (size + 1));
  for (let y = 0; y < size; y++) {
    const rowStart = y * (size + 1);
    raw[rowStart] = 0; // 每行前置 filter byte（None）
    for (let x = 0; x < size; x++) {
      raw[rowStart + 1 + x] = ((x >> 3) + (y >> 3)) % 2 === 0 ? 40 : 200;
    }
  }

  return concat([
    new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', zlibStored(raw)),
    pngChunk('IEND', new Uint8Array(0)),
  ]);
}

/**
 * 1 秒 8kHz 单声道 8bit PCM WAV，带 440Hz 低幅正弦。
 * 只有设置页的 ASR 槽探测会把它发出去（试转一次，能返回就算连通）。
 */
export function makeTestWav(seconds = 1, sampleRate = 8000): Uint8Array {
  const samples = Math.floor(seconds * sampleRate);
  const out = new Uint8Array(44 + samples);
  const view = new DataView(out.buffer);
  const ascii = (offset: number, s: string) => {
    for (let i = 0; i < s.length; i++) out[offset + i] = s.charCodeAt(i);
  };

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + samples, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, true); // fmt 块长度
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // 单声道
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate, true); // 字节率 = 采样率 × 声道 × 位深/8
  view.setUint16(32, 1, true); // 块对齐
  view.setUint16(34, 8, true); // 位深
  ascii(36, 'data');
  view.setUint32(40, samples, true);

  for (let i = 0; i < samples; i++) {
    out[44 + i] = 128 + Math.round(20 * Math.sin((2 * Math.PI * 440 * i) / sampleRate));
  }
  return out;
}

export function testPngBase64(size = 64): string {
  return bytesToBase64(makeTestPng(size));
}

export function testWavBase64(seconds = 1): string {
  return bytesToBase64(makeTestWav(seconds));
}
