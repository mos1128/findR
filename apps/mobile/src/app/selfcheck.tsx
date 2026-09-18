import { useCallback, useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, Panel, Screen } from '@/ui/kit';
import { openFindrDb } from '@/platform/db';
import { runSelfCheck, type CheckResult } from '@/platform/selfcheck';

/**
 * 真机自检：M1 的核心假设（FTS5 / trigram / 同步驱动 / 嵌套事务）都在这块屏上验证。
 * 与业务库共用同一个连接，但只在临时表上做增删，结束即 DROP。
 */
export default function SelfCheckScreen() {
  const theme = useTheme();
  const [results, setResults] = useState<CheckResult[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dbPath, setDbPath] = useState('');

  const run = useCallback(() => {
    setError(null);
    setResults(null);
    try {
      const opened = openFindrDb();
      setDbPath(opened.path);
      setResults(runSelfCheck(opened.driver));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  useEffect(() => {
    run();
  }, [run]);

  const failed = results?.filter((r) => !r.ok).length ?? 0;

  return (
    <Screen>
      <Text style={{ color: theme.textSecondary, fontSize: 13, lineHeight: 19 }}>
        M1 的核心假设都在这里验证：FTS5 与 trigram 是否编进 SQLite、同步驱动与嵌套事务是否可用、
        Hermes 下分类名归一化会不会炸。
      </Text>

      {error ? (
        <Panel style={{ borderColor: theme.danger }}>
          <Text style={{ color: theme.danger, fontWeight: '700' }}>自检无法启动</Text>
          <Text style={{ color: theme.textSecondary, fontSize: 12 }}>{error}</Text>
        </Panel>
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
            <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 17 }}>{r.detail}</Text>
          </View>
        </View>
      ))}

      {dbPath ? (
        <Text style={{ color: theme.textMuted, fontSize: 11 }}>数据库：{dbPath}</Text>
      ) : null}

      <Button title="重新自检" onPress={run} />
      <Pressable onPress={() => setResults(null)} style={{ height: 0 }} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: Spacing.two, alignItems: 'flex-start', borderRadius: Radius.sm },
});
