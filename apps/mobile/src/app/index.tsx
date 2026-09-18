import { useCallback, useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { openFindrDb } from '@/platform/db';
import { runSelfCheck, type CheckResult } from '@/platform/selfcheck';

export default function SelfCheckScreen() {
  const insets = useSafeAreaInsets();
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
    <ScrollView
      style={styles.screen}
      contentContainerStyle={[styles.content, { paddingBottom: insets.bottom + 32 }]}>
      <Text style={styles.title}>Findr 自检</Text>
      <Text style={styles.subtitle}>
        M1 的核心假设（FTS5 / trigram / 同步驱动 / 嵌套事务）都在这块屏上验证
      </Text>

      {error ? (
        <View style={[styles.card, styles.cardBad]}>
          <Text style={styles.badgeBad}>自检无法启动</Text>
          <Text style={styles.detail}>{error}</Text>
        </View>
      ) : null}

      {results ? (
        <View style={[styles.card, failed > 0 ? styles.cardBad : styles.cardGood]}>
          <Text style={failed > 0 ? styles.badgeBad : styles.badgeGood}>
            {failed > 0 ? `${failed} 项未通过` : `全部 ${results.length} 项通过`}
          </Text>
        </View>
      ) : null}

      {results?.map((r) => (
        <View key={r.name} style={styles.row}>
          <Text style={r.ok ? styles.markOk : styles.markBad}>{r.ok ? '✓' : '✗'}</Text>
          <View style={styles.rowBody}>
            <Text style={styles.name}>{r.name}</Text>
            <Text style={styles.detail}>{r.detail}</Text>
          </View>
        </View>
      ))}

      {dbPath ? <Text style={styles.path}>{dbPath}</Text> : null}

      <Pressable style={styles.button} onPress={run}>
        <Text style={styles.buttonText}>重新自检</Text>
      </Pressable>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#ffffff' },
  content: { padding: 16, gap: 12 },
  title: { fontSize: 24, fontWeight: '700', color: '#111111' },
  subtitle: { fontSize: 13, color: '#60646C', marginBottom: 4 },
  card: { borderRadius: 10, padding: 12, borderWidth: 1 },
  cardGood: { borderColor: '#BFE3C6', backgroundColor: '#F2FBF4' },
  cardBad: { borderColor: '#F3C2C2', backgroundColor: '#FDF3F3' },
  badgeGood: { fontSize: 15, fontWeight: '700', color: '#1D7A34' },
  badgeBad: { fontSize: 15, fontWeight: '700', color: '#B3261E' },
  row: { flexDirection: 'row', gap: 8, alignItems: 'flex-start' },
  rowBody: { flex: 1 },
  markOk: { fontSize: 15, color: '#1D7A34', fontWeight: '700', lineHeight: 20 },
  markBad: { fontSize: 15, color: '#B3261E', fontWeight: '700', lineHeight: 20 },
  name: { fontSize: 14, fontWeight: '600', color: '#111111' },
  detail: { fontSize: 12, color: '#60646C', lineHeight: 17 },
  path: { fontSize: 11, color: '#9AA0A6', marginTop: 8 },
  button: {
    marginTop: 16,
    backgroundColor: '#208AEF',
    borderRadius: 10,
    paddingVertical: 14,
    alignItems: 'center',
  },
  buttonText: { color: '#ffffff', fontSize: 15, fontWeight: '600' },
});
