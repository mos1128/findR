import { Directory, File, Paths } from 'expo-file-system';

/**
 * 「＋ → 选文件」的那一半：把用户挑中的**纯文本**文件读成一段文字。
 *
 * 为什么只做纯文本：本产品卡片的信息源只有「文字」和「图片」两条
 * （见 需求.md 四『检索』—— 图片里的信息也只能先被模型写进 desc 才可检索）。
 * PDF / Word 要额外引入原生解析依赖，且各家模型对 `file` 内容块的支持不一，
 * 会打破 R2「换模型只改配置」。所以这里明确拒绝，并告诉用户绕行办法
 * （截图，或直接复制文字），**不假装支持**。
 */

/** 允许的扩展名。刻意不含 pdf/doc/docx —— 见上面的理由 */
const TEXT_EXTS = ['txt', 'md', 'markdown', 'json', 'csv', 'tsv', 'log', 'yaml', 'yml'];

/**
 * 单条记忆的文本上限。
 *
 * 这不是技术限制而是**产品限制**：一张卡装的是一件事，不是一本书。
 * 超限**不静默截断** —— 截断会让用户以为整份都记下了，而检索得到的却只有开头一段。
 */
export const MAX_FILE_CHARS = 8000;

/** 读不出来时先复制到本地再读：微信/云盘转存来的 `content://` 虚拟文档常常拿不到可读流 */
const TMP_DIR = 'capture-tmp';

export interface PickedTextFile {
  name: string;
  text: string;
  chars: number;
}

function extOf(name: string): string {
  const i = name.lastIndexOf('.');
  return i >= 0 ? name.slice(i + 1).toLowerCase() : '';
}

function normalize(raw: string): string {
  return raw.replace(/\r\n?/g, '\n').trim();
}

async function readAsText(file: File): Promise<string> {
  try {
    return await file.text();
  } catch (original) {
    try {
      const dir = new Directory(Paths.cache, TMP_DIR);
      if (!dir.exists) dir.create({ intermediates: true });
      const local = new File(dir, `pick-${Date.now()}`);
      if (local.exists) local.delete();
      await file.copy(local, { overwrite: true });
      try {
        return await local.text();
      } finally {
        if (local.exists) local.delete();
      }
    } catch {
      // 复制也失败 ⇒ 抛出**原始**错误，别把「读不出」和「复制不了」混成一句含糊的话
      throw original;
    }
  }
}

/**
 * 让用户挑一个纯文本文件并读成字符串。
 *
 * 返回 `null` 表示用户取消。抛出的都是**人话**，调用方直接 alert 即可。
 *
 * 刻意用「全部类型」的通配 MIME 而不是限定成 text：Android 对 `.md` / `.log`
 * 这类扩展名的类型判定不可靠，一旦限定就会出现「文件明明在，选择器里却是灰的」
 * （备份导入踩过同一个坑，见 platform/backup.ts 的 pickBackupFile）。
 * 真正的把关放在扩展名校验里 —— 挑错文件得到一句人话，比让人压根找不到文件好得多。
 */
export async function pickTextFile(): Promise<PickedTextFile | null> {
  const res = await File.pickFileAsync({ mimeTypes: '*/*' });
  if (res.canceled) return null;
  const file = res.result;

  const ext = extOf(file.name ?? '');
  if (!TEXT_EXTS.includes(ext)) {
    throw new Error(
      `暂时只能读纯文本文件（${TEXT_EXTS.join(' / ')}）。PDF、Word 这类建议先截图，或把要记的那段文字直接打/粘进来。`,
    );
  }

  let raw: string;
  try {
    raw = await readAsText(file);
  } catch (e) {
    throw new Error(`读不了这个文件：${e instanceof Error ? e.message : String(e)}`);
  }

  const text = normalize(raw);
  if (!text) throw new Error('这个文件是空的。');

  const chars = text.length;
  if (chars > MAX_FILE_CHARS) {
    throw new Error(
      `这个文件有 ${chars} 字，超过单条记忆的上限（${MAX_FILE_CHARS} 字）。建议先把要记的那一段摘出来。`,
    );
  }

  return { name: file.name ?? `文件.${ext}`, text, chars };
}
