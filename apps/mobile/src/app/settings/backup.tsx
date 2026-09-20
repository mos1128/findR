import { useCallback, useEffect, useRef, useState } from 'react';
import { Alert, Text, View } from 'react-native';
import type { File } from 'expo-file-system';
import type { ImportResult } from '@findr/core';

import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, ListRow, Panel, Screen, SectionTitle } from '@/ui/kit';
import { useRuntime } from '@/platform/runtime';
import {
  canShare,
  exportToFile,
  importFromBytes,
  pickBackupFile,
  readBackupBytes,
  shareBackup,
  type ExportOutcome,
  type ExportPhase,
} from '@/platform/backup';

/**
 * 备份页（MVP 最后一块）。
 *
 * 两条硬约束来自需求与《技术设计》第七节，改这里之前先读那两处：
 *   1. 导出文件**永远不含 API Key 与安全存储内容**（core 侧走白名单，不是靠过滤）；
 *   2. 导入**不删除本地任何数据**，同 id 按 `updated_at` 新者胜。
 *
 * ⚠️ **这一版没有加密**（2026-09-20 决策）：`.findrpack` 就是一个套了 7 字节头的 ZIP，
 * 谁拿到谁能读到全部内容。界面上必须把这件事说白，不能让人误以为它是加密的 ——
 * 加密排在后续版本，那时 core 会提 format version，这里只需跟着改文案。
 */

export default function BackupScreen() {
  const theme = useTheme();
  const { state: rt, refresh } = useRuntime();

  const [busy, setBusy] = useState(false);
  const [phase, setPhase] = useState<ExportPhase | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [exported, setExported] = useState<ExportOutcome | null>(null);
  const [shareOk, setShareOk] = useState(true);

  const [picked, setPicked] = useState<File | null>(null);
  const [imported, setImported] = useState<ImportResult | null>(null);
  const [note, setNote] = useState<string | null>(null);

  /** 媒体多的库打包要几秒没有反馈，给个秒表让人知道还活着 */
  const startedAt = useRef(0);
  useEffect(() => {
    if (!busy) return;
    startedAt.current = Date.now();
    setElapsed(0);
    const timer = setInterval(() => setElapsed(Math.round((Date.now() - startedAt.current) / 1000)), 1000);
    return () => clearInterval(timer);
  }, [busy]);

  useEffect(() => {
    void canShare().then(setShareOk);
  }, []);

  const runExport = useCallback(async () => {
    if (!rt) return;
    setBusy(true);
    setNote(null);
    setExported(null);
    try {
      const out = await exportToFile(rt.driver, setPhase);
      setExported(out);
      if (await canShare()) {
        await shareBackup(out.uri, out.fileName);
      } else {
        setNote(`系统没有可用的分享面板。文件已生成在 App 私有目录：${out.fileName}`);
      }
    } catch (e) {
      Alert.alert('导出失败', e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
      setPhase(null);
    }
  }, [rt]);

  /**
   * 明文导出等于把整个记忆库摊开给任何拿到文件的人，而分享面板一点就发出去。
   * 所以这里挡一道：说清楚它不是加密的，再让用户决定。
   */
  const onExport = useCallback(() => {
    Alert.alert(
      '这份备份没有加密',
      '文件里就是你全部卡片的内容与图片、录音，拿到它的人不需要密码就能直接打开。\n\n'
        + '请只保存到自己信得过的地方（自己的电脑、私人云盘），别发到群聊里。'
        + '\n\n加密会在这个功能的下一个版本补上。',
      [
        { text: '取消', style: 'cancel' },
        { text: '继续导出', onPress: () => void runExport() },
      ],
    );
  }, [runExport]);

  const onPick = useCallback(async () => {
    setNote(null);
    setImported(null);
    try {
      const file = await pickBackupFile();
      if (!file) return;
      setPicked(file);
    } catch (e) {
      Alert.alert('打开文件选择器失败', e instanceof Error ? e.message : String(e));
    }
  }, []);

  const onImport = useCallback(async () => {
    if (!rt || !picked) return;
    setBusy(true);
    setNote(null);
    try {
      const bytes = await readBackupBytes(picked);
      const res = await importFromBytes(rt.driver, bytes);
      setImported(res);
      // 导入直接改了 DB，必须让运行时把设置重新读一遍，否则界面还是旧的
      await refresh();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      Alert.alert('导入失败', `${msg}\n\n最常见的原因：文件不是 Findr 的备份，或者传输过程中损坏了。`);
    } finally {
      setBusy(false);
    }
  }, [rt, picked, refresh]);

  if (!rt) return <Screen />;

  return (
    <Screen>
      <Text style={{ color: theme.textSecondary, fontSize: 13, lineHeight: 19 }}>
        备份用来换手机或重装后把记忆搬回去。它是一个文件（.findrpack），
        内容就是你全部卡片与图片、录音。
      </Text>

      <Panel style={{ borderColor: theme.danger }}>
        <Text style={{ color: theme.danger, fontWeight: '700' }}>当前版本不加密</Text>
        <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 18 }}>
          这个文件没有任何密码保护 —— 用解压工具就能直接看到里面的全部内容。
          请只把它放在自己信得过的地方（自己的电脑、私人云盘），不要发到群聊或公共空间。
          {'\n'}加密计划在这个功能的下一个版本补上。
        </Text>
      </Panel>

      {/* ── 导出 ───────────────────────────────────────────── */}
      <Panel>
        <SectionTitle hint="含全部卡片、分类、位置、别名与图片音频">导出</SectionTitle>
        <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
          不含 API Key、不含任何安全存储内容 —— 导进去也还是要在新机器上重新填一次 Key。
        </Text>
        <Button
          title={busy && phase ? PHASE_TEXT(phase, elapsed) : '导出并分享'}
          loading={busy}
          onPress={onExport}
        />
        {exported ? (
          <Panel style={{ borderColor: theme.success }}>
            <Text style={{ color: theme.success, fontWeight: '600' }}>已生成 {exported.fileName}</Text>
            <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 17 }}>
              {`卡片 ${exported.report.cards} · 分类 ${exported.report.categories} · 位置 ${exported.report.locations} · 别名 ${exported.report.aliases}`}
              {'\n'}
              {`媒体 ${exported.report.mediaWritten}/${exported.report.mediaTotal} 个 · ${fmtBytes(exported.report.bytes)}`}
            </Text>
            {exported.report.mediaMissing.length > 0 ? (
              <Text style={{ color: theme.danger, fontSize: 12, lineHeight: 17 }}>
                {`有 ${exported.report.mediaMissing.length} 个媒体文件在磁盘上已不存在，没能进包（DB 里仍引用着它们）：\n${exported.report.mediaMissing.slice(0, 5).join('\n')}`}
              </Text>
            ) : null}
            {shareOk ? (
              <Button
                title="再分享一次"
                variant="secondary"
                compact
                onPress={() => void shareBackup(exported.uri, exported.fileName)}
              />
            ) : null}
          </Panel>
        ) : null}
      </Panel>

      {/* ── 导入 ───────────────────────────────────────────── */}
      <Panel>
        <SectionTitle hint="不会删除本机任何东西">导入</SectionTitle>
        <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
          同一张卡在两台机器上都改过时，修改时间较新的那份保留；分类与位置按名字对齐，
          对齐不上才新建。媒体按相对路径覆盖。
        </Text>
        <Button title="选择备份文件" variant="secondary" onPress={() => void onPick()} />
        {picked ? (
          <>
            <ListRow title={picked.name} subtitle="已选中，点下面开始导入" />
            <Button title="开始导入" variant="danger" loading={busy} onPress={() => void onImport()} />
            <Button
              title="换一个文件"
              variant="ghost"
              compact
              onPress={() => {
                setPicked(null);
                setImported(null);
              }}
            />
          </>
        ) : null}

        {imported ? (
          <Panel style={{ borderColor: theme.success }}>
            <Text style={{ color: theme.success, fontWeight: '600' }}>
              {`导入完成 · 备份来自 ${fmtWhen(imported.manifestInfo.exportedAt)}`}
            </Text>
            <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 18 }}>
              {`卡片：新增 ${imported.report.cardsInserted} / 更新 ${imported.report.cardsUpdated} / 保留本机 ${imported.report.cardsKeptLocal}`}
              {'\n'}
              {`媒体：写入 ${imported.report.mediaWritten}（覆盖 ${imported.report.mediaOverwritten}）`}
              {'\n'}
              {`分类：新增 ${imported.report.categoriesInserted} / 保留本机 ${imported.report.categoriesKeptLocal}`}
              {'\n'}
              {`位置：新增 ${imported.report.locationsInserted} / 保留本机 ${imported.report.locationsKeptLocal}`}
              {'\n'}
              {`别名：新增 ${imported.report.aliasesInserted} · 设置：写入 ${imported.report.settingsWritten} / 保留本机 ${imported.report.settingsKeptLocal}`}
              {imported.report.remappedCategoryRefs + imported.report.remappedLocationRefs > 0
                ? `\n按名字重新对齐的引用：分类 ${imported.report.remappedCategoryRefs} · 位置 ${imported.report.remappedLocationRefs}`
                : ''}
              {imported.report.droppedRefs > 0
                ? `\n⚠ 有 ${imported.report.droppedRefs} 处引用对不上、只能置空`
                : ''}
            </Text>
            {imported.report.conflicts.length > 0 ? (
              <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
                {`同名冲突 ${imported.report.conflicts.length} 处（保留了本机那份）：\n${imported.report.conflicts
                  .slice(0, 6)
                  .map((c) => `· ${c.kind === 'category' ? '分类' : '位置'}「${c.name}」`)
                  .join('\n')}`}
              </Text>
            ) : null}
          </Panel>
        ) : null}
      </Panel>

      {note ? (
        <Panel>
          <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 17 }}>{note}</Text>
        </Panel>
      ) : null}

      {/* ── 说明 ───────────────────────────────────────────── */}
      <Panel>
        <SectionTitle>几条要记住的</SectionTitle>
        <View style={{ gap: Spacing.one }}>
          {[
            '文件是明文的：别把它交给别人，也别放在共享空间里。',
            '导出的文件在 App 的缓存目录里，递出去之后系统随时可能清掉它 —— 导出完就分享/保存到别处。',
            '导入是合并，不是覆盖：本机多出来的卡片不会被删。',
            '重复导入同一个文件是安全的，结果一致（按 id 幂等）。',
            '文件传坏了能被发现（包里每个文件都带校验和），会明确报「校验和不符」。',
          ].map((line) => (
            <Text key={line} style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 17 }}>
              · {line}
            </Text>
          ))}
        </View>
      </Panel>
    </Screen>
  );
}

function PHASE_TEXT(phase: ExportPhase, elapsed: number): string {
  const secs = elapsed > 0 ? `（${elapsed}s）` : '';
  if (phase === 'packing') return `正在打包…${secs}`;
  return `正在写入文件…${secs}`;
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(2)} MB`;
}

function fmtWhen(iso: string): string {
  if (!iso) return '未知时间';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
