import { useCallback, useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, Panel, Screen } from '@/ui/kit';
import { runSelfCheck, type CheckResult } from '@/platform/selfcheck';
import { useRuntime } from '@/platform/runtime';

/**
 * 真机自检：把 M1 的核心假设（FTS5 / trigram / 同步驱动 / 嵌套事务 / Hermes 兼容性）
 * 一次性验掉。
 *
 * **必须复用运行时那一个连接**——op-sqlite 明确要求一个 App 会话只开一个数据库连接，
 * 自己再 open 一次会带来锁冲突与难以解释的失败。只在临时表上做增删，结束即 DROP。
 */
export default function SelfCheckScreen() {
  const theme = useTheme();
  const { state: rt, error: runtimeError } = useRuntime();
  const [results, setResults] = useState<CheckResult[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const run = useCallback(() => {
    setError(null);
    setResults(null);
    if (!rt) return;
    try {
      setResults(runSelfCheck(rt.driver));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [rt]);

  useEffect(() => {
    run();
  }, [run]);

  const failed = results?.filter((r) => !r.ok).length ?? 0;

  return (
    <Screen>
      <Text style={{ color: theme.textSecondary, fontSize: 13, lineHeight: 19 }}>
        M1 的核心假设都在这里验证：FTS5 与 trigram 是否编进 SQLite、同步驱动与嵌套事务是否可用、
        Hermes 下分类名归一化会不会炸。任一红项都请先停下排查——后面所有功能都建在它上面。
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

      {results ? (
        <Panel style={{ borderColor: failed > 0 ? theme.danger : theme.success }}>
          <Text style={{ color: failed > 0 ? theme.danger : theme.success, fontWeight: '700' }}>
            {failed > 0 ? `${failed} 项未通过` : `全部 ${results.length} 项通过`}
          </Text>
        </Panel>
      ) : null}

      {results?.map((r) => (
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

      {rt ? (
        <Text style={{ color: theme.textMuted, fontSize: 11 }}>数据库：{rt.dbPath}</Text>
      ) : null}

      <Button title="重新自检" onPress={run} disabled={!rt} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: Spacing.two, alignItems: 'flex-start' },
});
