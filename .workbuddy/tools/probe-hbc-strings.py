#!/usr/bin/env python3
"""在 Hermes 字节码（assets/index.android.bundle）里找字符串 —— 出包后的「产物级证据」。

为什么需要它：CI 绿只证明「构建过」，不证明「打进包里的就是这份代码」。
把这个文件从 APK 里抽出来搜本次新写的文案，才算真的验过。

它做两件事：
  1. 按 Hermes 的真实文件格式解析字符串表，把每条字符串解码出来（含中文）；
  2. 对每个探针报三态：table=字符串表里有这一条 / raw=只在原始字节里出现 /
     missing=完全没有。

用法（解释器用托管 Python，别用系统 python）：
  C:/Users/mos/.workbuddy/binaries/python/versions/3.13.12/python.exe \
      .workbuddy/tools/probe-hbc-strings.py <bundle 文件> 探针1 探针2 ...

先把 bundle 抽出来：
  unzip -p findr-apk-<tag>.apk assets/index.android.bundle > hbc.bin

选探针的三条铁律（踩过）：
  * 必须是**源码里字面写出的一段**。模板字符串按 `${}` 切成多段存，插值处必然断开：
    源码 `（全库共 ${total} 条，此处只列出${a ? '与本次问题最相关的' : '最近的'} ${n} 条`
    在包里只剩 ` 条，此处只列出` / `与本次问题最相关的` / `最近的` 这些**片段**，
    拼好后的整句（`此处只列出与本次问题最相关的 200 条`）永远搜不到。
    ⇒ 所以「片段」往往比「整句」命得准；脚本会把这种情形报成 inside 而不是 missing。
  * 优先选整句写死的字面量（UI 标签、整句错误提示），那种一定是独立条目。
  * 中文要按 UTF-16LE 找，grep 找 UTF-8 字节永远 0 命中。
    只要串里有一个非 ASCII 字符（含 emoji），Hermes 就**整串**按 UTF-16 存。
"""
import struct
import sys

HBC_MAGIC = 0x1F1903C103BC1FC6  # "Hermes" 的古希腊文写法的 UTF-16BE 截断成 8 字节
SMALL_HEADER = 12               # 本包实测 SmallFuncHeader = 12 字节
LATIN1, UTF16 = "latin-1", "utf-16-le"


class Hbc:
    """Hermes 字节码文件：只解析到「能读字符串」为止。"""

    def __init__(self, data: bytes):
        self.d = data
        magic, version = struct.unpack_from("<QI", data, 0)
        if magic != HBC_MAGIC:
            raise ValueError(
                "不是 Hermes 字节码（magic=0x%X）。这个 bundle 可能是明文 JS —— 直接 grep 就行" % magic
            )
        self.version = version
        (
            self.file_length,        # 32
            _,                       # 36 globalCodeIndex
            self.function_count,     # 40
            self.string_kind_count,  # 44
            self.identifier_count,   # 48
            self.string_count,       # 52
            self.overflow_count,     # 56
            self.string_storage_size,# 60
        ) = struct.unpack_from("<8I", data, 32)

        # 段顺序由 Hermes 源码的 visitBytecodeSegmentsInOrder 定死：
        # header → 函数头 → stringKind → 标识符哈希 → 字符串表 → 溢出表 → 存储区
        self.func_headers = 128
        self.string_table = (
            self.func_headers
            + self.function_count * SMALL_HEADER
            + self.string_kind_count * 4
            + self.identifier_count * 4
        )
        self.overflow_table = self.string_table + self.string_count * 4
        self.string_storage = self.overflow_table + self.overflow_count * 8

        # 自检：存储区末尾必须落在文件内，且各区算术咬合
        assert self.string_storage + self.string_storage_size <= len(data), "段偏移算错了"

    def strings(self):
        """产出 (索引, isUTF16, 解码后的字符串)。"""
        d = self.d
        for i in range(self.string_count):
            entry = struct.unpack_from("<I", d, self.string_table + 4 * i)[0]
            is_utf16 = entry & 1
            off = (entry >> 1) & 0x7FFFFF
            length = (entry >> 24) & 0xFF
            if length == 255:  # 溢出：真正的偏移/长度在 8 字节的溢出表里
                off, length = struct.unpack_from("<II", d, self.overflow_table + 8 * off)
            start = self.string_storage + off
            raw = d[start:start + length * (2 if is_utf16 else 1)]
            yield i, bool(is_utf16), raw.decode(UTF16 if is_utf16 else LATIN1, "replace")

    def probe(self, needle: str):
        """返回 (命中类型, 细节)。命中类型：table / inside / raw / missing

        table  = 字符串表里有一条**正好等于**它（最理想：源码里整句写死的字面量）
        inside = 它是某条字符串的一段（很常见 —— 模板被 ${} 切断后，编译器会把
                 相邻的常量字面量合并成一条，所以「片段」往往比「整句」命得准）
        raw    = 只在原始字节里出现，不在任何条目内（同一条串被多个表条目共享
                 存储时会这样，见存储区的后缀共享）
        """
        exact, inside = [], []
        for i, _, s in self.strings():
            if s == needle:
                exact.append(i)
            elif needle in s:
                inside.append((i, s))
        if exact:
            return "table", "字符串表条目 #%s" % ",".join(map(str, exact[:5]))
        if inside:
            i, s = inside[0]
            return "inside", "#%d 里含这段：%r%s" % (i, s, "" if len(inside) == 1 else "（共 %d 条）" % len(inside))
        n16 = self.d.count(needle.encode(UTF16))
        n8 = self.d.count(needle.encode("utf-8"))
        if n16 or n8:
            return "raw", "只在原始字节里：utf-16-le=%d utf-8=%d" % (n16, n8)
        return "missing", ""


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    data = open(argv[1], "rb").read()
    print("文件 %s  %d 字节" % (argv[1], len(data)))
    try:
        hbc = Hbc(data)
    except ValueError as e:
        print("⚠ " + str(e))
        for p in argv[2:]:
            print("  %-24s utf-8 命中 %d" % (p, data.count(p.encode("utf-8"))))
        return 1

    strs = list(hbc.strings())
    n_utf16 = sum(1 for _, u, _ in strs if u)
    n_han = sum(1 for _, _, s in strs if any("\u4e00" <= c <= "\u9fff" for c in s))
    print("Hermes 字节码 v%d；字符串 %d 条 = 单字节 %d + 双字节 %d（其中含汉字 %d 条）"
          % (hbc.version, hbc.string_count, hbc.string_count - n_utf16, n_utf16, n_han))
    print("段偏移：函数头 %d（%d 个 × %d B） 字符串表 %d  溢出表 %d  存储区 %d + %d"
          % (hbc.func_headers, hbc.function_count, SMALL_HEADER, hbc.string_table,
             hbc.overflow_table, hbc.string_storage, hbc.string_storage_size))
    print()

    bad = 0
    for p in argv[2:]:
        kind, detail = hbc.probe(p)
        mark = {"table": "✓ 在包里", "inside": "✓ 在包里", "raw": "~ 字节里有", "missing": "✗ 没有"}[kind]
        bad += kind == "missing"
        print("  %s  %-26s %s" % (mark, p, detail))
    print()
    print("结论：%d/%d 命中" % (len(argv) - 2 - bad, len(argv) - 2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
