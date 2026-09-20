import { useState } from 'react';
import { Alert, Switch, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import {
  DEFAULT_CAPTURE_SETTINGS,
  DEFAULT_PIPELINE_SETTINGS,
  retryAllTranscriptions,
  writeCaptureSettings,
  writePipelineSettings,
  writeSearchSettings,
} from '@findr/core';

import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, Chip, Field, ListRow, Panel, Screen, SectionTitle } from '@/ui/kit';
import { maskApiKey } from '@/platform/secure';
import { requireDeps, runQueueNow, useRuntime } from '@/platform/runtime';

export default function SettingsScreen() {
  const theme = useTheme();
  const router = useRouter();
  const { state: rt, refresh } = useRuntime();
  const [busy, setBusy] = useState(false);
  const [threshold, setThreshold] = useState(String(rt?.pipeline.confirmThreshold ?? 0.6));

  if (!rt) return <Screen />;

  const asrName = rt.asr ? `${rt.asr.model}` : '未配置';
  const llmName = rt.llm ? `${rt.llm.model}（${rt.llm.providerType}）` : '未配置';

  const runRetranscribe = async () => {
    setBusy(true);
    try {
      const res = await retryAllTranscriptions(requireDeps(rt));
      await refresh();
      Alert.alert('补转写完成', `重置 ${res.reset} 张，完成 ${res.settled} 张。`);
    } catch (e) {
      Alert.alert('补转写失败', e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Screen>
      <Panel>
        <SectionTitle hint="BYOK：模型与 Key 都由你自己提供">模型</SectionTitle>
        <ListRow
          title="主 LLM"
          subtitle={llmName}
          onPress={() => router.push('/settings/provider?slot=llm')}
          right={<Text style={{ color: theme.textMuted }}>›</Text>}
        />
        <ListRow
          title="ASR（语音转写）"
          subtitle={asrName}
          onPress={() => router.push('/settings/provider?slot=asr')}
          right={<Text style={{ color: theme.textMuted }}>›</Text>}
        />
        <Text style={{ color: theme.textMuted, fontSize: 11 }}>
          API Key 存在系统密钥库，不进数据库、也不会出现在导出备份里。当前：LLM{' '}
          {maskApiKey(rt.llmKey)} / ASR {maskApiKey(rt.asrKey)}
        </Text>
      </Panel>

      <Panel>
        <SectionTitle>录入</SectionTitle>
        <ListRow
          title="图片分析默认值"
          subtitle="每次录入仍可临时切换；关掉可省 token，但图中内容搜不到"
          right={
            <Switch
              value={rt.capture.visionDefault}
              onValueChange={(v) => {
                writeCaptureSettings(rt.driver, { ...rt.capture, visionDefault: v });
                void refresh();
              }}
              trackColor={{ true: theme.record, false: theme.surfaceAlt }}
            />
          }
        />
        {rt.capture.visionLast !== null ? (
          <ListRow
            title="上次的选择"
            subtitle={`最近一次录入用的是「${rt.capture.visionLast ? '开' : '关'}」，点这里恢复成跟随默认值`}
            onPress={() => {
              writeCaptureSettings(rt.driver, { ...rt.capture, visionLast: null });
              void refresh();
            }}
            right={<Text style={{ color: theme.record }}>重置</Text>}
          />
        ) : null}
        <Text style={{ color: theme.textMuted, fontSize: 11 }}>
          单卡最多送模型分析 {rt.capture.maxAnalyzeImages} 张图（固定护栏，超出的图片仍会保存）
        </Text>
      </Panel>

      <Panel>
        <SectionTitle hint="低于该置信度会强制你确认">解析</SectionTitle>
        <Field
          label="低置信确认阈值"
          value={threshold}
          onChangeText={setThreshold}
          keyboardType="decimal-pad"
          hint={`当前 ${rt.pipeline.confirmThreshold}；默认 ${DEFAULT_PIPELINE_SETTINGS.confirmThreshold}`}
        />
        <Button
          title="保存阈值"
          variant="secondary"
          compact
          onPress={() => {
            const v = Number(threshold);
            if (!Number.isFinite(v) || v < 0 || v > 1) {
              Alert.alert('阈值要在 0 到 1 之间');
              return;
            }
            writePipelineSettings(rt.driver, { confirmThreshold: v });
            void refresh();
          }}
        />
      </Panel>

      <Panel>
        <SectionTitle hint="每次搜索要不要顺手让模型写一段答案">检索</SectionTitle>
        <ListRow
          title="每次搜索都自动组织答案"
          subtitle="关：只在搜不到、或你点「AI 总结」时才跑。开：搜到也自动跑，答案追加在列表下方"
          right={
            <Switch
              value={rt.search.autoAnswer}
              onValueChange={(v) => {
                writeSearchSettings(rt.driver, { ...rt.search, autoAnswer: v });
                void refresh();
              }}
              trackColor={{ true: theme.record, false: theme.surfaceAlt }}
            />
          }
        />
        <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
          打开后每次搜索都会把最多 8 条命中片段发给模型（单次多花约 0.2 分，可忽略）；
          真正的代价是——关着的时候你不点按钮就不外发任何记忆内容，开着则每次搜索都会。
        </Text>
      </Panel>

      <Panel>
        <SectionTitle hint="位置是检索质量的命脉">词表</SectionTitle>
        <ListRow
          title="位置树"
          subtitle="房间 → 家具 → 容器"
          onPress={() => router.push('/settings/locations')}
          right={<Text style={{ color: theme.textMuted }}>›</Text>}
        />
        <ListRow
          title="分类"
          subtitle="名称、Emoji、识别描述、所属结构类型"
          onPress={() => router.push('/settings/categories')}
          right={<Text style={{ color: theme.textMuted }}>›</Text>}
        />
      </Panel>

      <Panel>
        <SectionTitle hint="配置好 ASR 后用它把积压的语音一次补完">维护</SectionTitle>
        <Button
          title="批量补转写"
          variant="secondary"
          loading={busy}
          onPress={() => void runRetranscribe()}
        />
        <Button
          title="立刻跑一次解析队列"
          variant="secondary"
          onPress={() => {
            void runQueueNow(rt).then(() => refresh());
          }}
        />
        <Button title="打开自检" variant="ghost" onPress={() => router.push('/selfcheck')} />
      </Panel>

      <Panel>
        <SectionTitle>关于</SectionTitle>
        <View style={{ flexDirection: 'row', gap: Spacing.two, flexWrap: 'wrap' }}>
          <Chip label={`图片分析${rt.llm?.capabilities ? (rt.llm.capabilities.vision ? '：支持' : '：不支持') : '：未探测'}`} />
        </View>
        <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
          数据库：{rt.dbPath}
          {'\n'}
          图片压缩参数：长边 ≤1600px、WebP 0.8（默认：图片分析
          {DEFAULT_CAPTURE_SETTINGS.visionDefault ? '开' : '关'}）
        </Text>
      </Panel>
    </Screen>
  );
}
