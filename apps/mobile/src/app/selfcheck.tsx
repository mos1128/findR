import { useCallback, useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, Panel, Screen } from '@/ui/kit';
import { runBackupSelfCheck, runSelfCheck, type CheckResult } from '@/platform/selfcheck';
import { useRuntime } from '@/platform/runtime';

/**
 * 真机自检：把 M1 的核心假设（FTS5 / trigram / 同步驱动 / 嵌套事务 / Hermes 兼容性）
 * 一次性验掉，末尾再跑一遍备份链路的检查（那一组是异步的 —— 要读真实文件系统）。
 *
 * **必须复用运行时那一个连接**——op-sqlite 明确要求一个 App 会话只开一个数据库连接，
 * 自己再 open 一次会带来锁冲突与难以解释的失败。只在临时表上做增删，结束即 DROP；
 * 备份那组只读业务表，唯一写的是一份跑完即删的媒体探针。
 */
export default function SelfCheckScreen() {
  const theme = useTheme();
  const { state: rt, error: runtimeError } = useRuntime();
  const [results, setResults] = useState<CheckResult[] | null>(null);
  const [backupResults, setBackupResults] = useState<CheckResult[] | null>(null);
  const [runningBackup, setRunningBackup] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const run = useCallback(() => {
    setError(null);
    setResults(null);
    setBackupResults(null);
    if (!rt) return;
    try {
      setResults(runSelfCheck(rt.driver));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
    setRunningBackup(true);
    runBackupSelfCheck(rt.driver)
      .then(setBackupResults)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setRunningBackup(false));
  }, [rt]);

  useEffect(() => {
    run();
  }, [run]);

  const failed = results?.filter((r) => !r.ok).length ?? 0;
  const backupFailed = backupResults?.filter((r) => !r.ok).length ?? 0;
  const total = (results?.length ?? 0) + (backupResults?.length ?? 0);
  const totalFailed = failed + backupFailed;

  return (
    <Screen>
      <Text style={{ color: theme.textSecondary, fontSize: 13, lineHeight: 19 }}>
        M1 的核心假设都在这里验证：FTS5 与 trigram 是否编进 SQLite、同步驱动与嵌套事务是否可用、
        Hermes 下分类名归一化会不会炸。任一红项都请先停下排查——后面所有功能都建在它上面。
        末尾那组是备份：会真的把整库打一次包，走完整条导出链路（只读，不动你的数据）。
      </Text>

      {runtimeError ? (
        <Panel style={{ borderColor: theme.danger }}>
          <Text style={{ color: theme.danger, fontWeight: '700' }}>数据库没能打开</Text>
          <Text style={{ color: theme.textSecondary, fontSize: 12 }}>{runtimeError}</Text>
        </Panel>
      ) : null}

      {error ? (
        <Panel style={{ borderColor: theme.danger }}>
          <Text style={{ color: theme.danger, fontWeight: '700' }}>自检无法启动</Text>
          <Text style={{ color: theme.textSecondary, fontSize: 12 }}>{error}</Text>
        </Panel>
      ) : null}

      {!rt && !runtimeError ? (
        <Text style={{ color: theme.textMuted, fontSize: 13 }}>正在打开数据库…</Text>
      ) : null}

      {results && !runningBackup ? (
        <Panel style={{ borderColor: totalFailed > 0 ? theme.danger : theme.success }}>
          <Text style={{ color: totalFailed > 0 ? theme.danger : theme.success, fontWeight: '700' }}>
            {totalFailed > 0 ? `${totalFailed} 项未通过` : `全部 ${total} 项通过`}
          </Text>
        </Panel>
      ) : null}

      {results ? <ResultBlock title="核心链路" results={results} /> : null}
      {runningBackup ? (
        <Text style={{ color: theme.textMuted, fontSize: 13 }}>
          正在跑备份自检…（会真实读一遍全库媒体，图多时要几秒）
        </Text>
      ) : null}
      {backupResults ? <ResultBlock title="备份" results={backupResults} /> : null}

      {rt ? (
        <Text style={{ color: theme.textMuted, fontSize: 11 }}>数据库：{rt.dbPath}</Text>
      ) : null}

      <Button title="重新自检" onPress={run} disabled={!rt || runningBackup} />
    </Screen>
  );
}

function ResultBlock({ title, results }: { title: string; results: CheckResult[] }) {
  const theme = useTheme();
  const bad = results.filter((r) => !r.ok).length;
  return (
    <Panel style={{ borderColor: bad > 0 ? theme.danger : theme.border }}>
      <Text style={{ color: theme.textSecondary, fontSize: 13, fontWeight: '600' }}>
        {title}（{results.length - bad}/{results.length}）
      </Text>
      {results.map((r) => (
        <View key={r.name} style={styles.row}>
          <Text style={{ color: r.ok ? theme.success : theme.danger, fontWeight: '700' }}>
            {r.ok ? '✓' : '✗'}
          </Text>
          <View style={{ flex: 1 }}>
            <Text style={{ color: theme.text, fontSize: 14, fontWeight: '600' }}>{r.name}</Text>
            <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 17 }}>
              {r.detail}
            </Text>
          </View>
        </View>
      ))}
    </Panel>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: Spacing.two, alignItems: 'flex-start' },
});
