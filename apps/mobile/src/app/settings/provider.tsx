import { useMemo, useState } from 'react';
import { Alert, Text, View } from 'react-native';
import { useLocalSearchParams } from 'expo-router';
import {
  makeAsrAdapter,
  makeLlmAdapter,
  probeLlm,
  testWavBase64,
  toAsrProviderConfig,
  toProviderConfig,
  writeAsrSettings,
  writeLlmSettings,
  type AsrSettings,
  type CapabilityStatus,
  type LlmSettings,
  type LlmProviderType,
} from '@findr/core';

import { useTheme } from '@/hooks/use-theme';
import { Button, Chip, Field, Panel, Screen, SectionTitle } from '@/ui/kit';
import { maskApiKey, setApiKey } from '@/platform/secure';
import { deviceMediaIO } from '@/platform/media';
import { runQueueNow, useRuntime } from '@/platform/runtime';

type Slot = 'llm' | 'asr';

/** 布尔 → 一个符号；旧缓存里没记录的项目显示「未记录」，别装成「不支持」 */
function capsMark(ok: boolean | undefined): string {
  if (ok === undefined) return '未记录';
  return ok ? '✅' : '⬜';
}

/**
 * 一项能力的结论行。**「不支持」与「没测出来」必须分开说** ——
 * 后者不是否定的证据，用户不需要为它改配置，更不该因此被锁掉功能。
 */
function capLine(
  label: string,
  status: CapabilityStatus | undefined,
  detail: string,
  ok: boolean,
): string {
  if (status === undefined) {
    return `${ok ? '✅' : '⬜'} ${label}：${ok ? '可用' : '不可用'} —— ${detail}`;
  }
  if (status === 'ok') return `✅ ${label}：可用 —— ${detail}`;
  if (status === 'unsupported') return `⬜ ${label}：不支持 —— ${detail}`;
  if (status === 'unknown') return `⬜ ${label}：没测出来 —— ${detail}`;
  return `⬜ ${label}：不可用 —— ${detail}`;
}

/**
 * 探测结果的摘要。顺序刻意如此：**先说「配置本身对不对」**（用户最想知道的），再说图片能力。
 *
 * 第十三版删掉了原来的「语音识别」那一行：它测的是主模型 chat 的 `input_audio` 内容块，
 * 而那条路从来没有被业务代码走过 —— 转写始终只走 ASR 槽。测一个不存在的功能，
 * 只会让用户在设置页看到一句对自己毫无用处、还会误导的「不支持」。
 */
function probeSummary(caps: {
  text?: boolean;
  textDetail?: string;
  vision: boolean;
  visionStatus?: CapabilityStatus;
  visionDetail: string;
}): string {
  const connectivity =
    caps.text === undefined
      ? '⬜ 配置连通性：未记录 —— 旧版探测没记这一项，重新探测一次'
      : `${caps.text ? '✅ 配置连通性：可用' : '⬜ 配置连通性：不可用'} —— ${caps.textDetail ?? ''}`;

  const lines = [
    connectivity,
    capLine('图片分析', caps.visionStatus, caps.visionDetail, caps.vision),
  ];

  if (caps.text === false) {
    lines.push('先解决第一条：地址 / Key / 模型名有问题，与模型能力无关。');
  }
  return lines.join('\n');
}

export default function ProviderScreen() {
  const theme = useTheme();
  const params = useLocalSearchParams<{ slot?: string }>();
  const { state: rt, refresh } = useRuntime();
  const [slot, setSlot] = useState<Slot>(params.slot === 'asr' ? 'asr' : 'llm');

  const [providerType, setProviderType] = useState<LlmProviderType>(
    rt?.llm?.providerType ?? 'anthropic',
  );
  const [baseUrl, setBaseUrl] = useState(rt?.llm?.baseUrl ?? rt?.asr?.baseUrl ?? '');
  const [model, setModel] = useState(rt?.llm?.model ?? rt?.asr?.model ?? '');
  const [authStyle, setAuthStyle] = useState<'x-api-key' | 'bearer'>(
    rt?.llm?.authStyle ?? 'bearer',
  );
  const [userAgent, setUserAgent] = useState(rt?.llm?.userAgent ?? '');
  const [apiKey, setApiKeyValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [probeText, setProbeText] = useState<string | null>(null);

  const currentKey = slot === 'llm' ? rt?.llmKey : rt?.asrKey;
  const known = useMemo(
    () => (slot === 'llm' ? rt?.llm : rt?.asr) ?? null,
    [rt, slot],
  );

  if (!rt) return <Screen />;

  const onSave = async () => {
    setBusy(true);
    try {
      if (apiKey.trim()) await setApiKey(slot, apiKey.trim());

      if (slot === 'llm') {
        const next: LlmSettings = {
          providerType,
          baseUrl: baseUrl.trim() || undefined,
          model: model.trim(),
          authStyle,
          userAgent: userAgent.trim() || undefined,
          // 换了模型，旧的探测结果不再可信
          capabilities: known && 'capabilities' in known ? known.capabilities : undefined,
        };
        if (next.capabilities && next.capabilities.probedModel !== next.model) {
          next.capabilities = undefined;
        }
        writeLlmSettings(rt.driver, next);
      } else {
        const next: AsrSettings = {
          providerType: 'openai-compat',
          baseUrl: baseUrl.trim() || undefined,
          model: model.trim(),
        };
        writeAsrSettings(rt.driver, next);
      }
      setApiKeyValue('');
      await refresh();
      Alert.alert('已保存');
    } catch (e) {
      Alert.alert('保存失败', e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const onProbe = async () => {
    setBusy(true);
    setProbeText(null);
    try {
      if (slot === 'llm') {
        const cfg: LlmSettings = {
          providerType,
          baseUrl: baseUrl.trim() || undefined,
          model: model.trim(),
          authStyle,
          userAgent: userAgent.trim() || undefined,
        };
        const key = apiKey.trim() || rt.llmKey;
        const adapter = makeLlmAdapter(cfg);
        const caps = await probeLlm(adapter, toProviderConfig(cfg, key));
        writeLlmSettings(rt.driver, {
          ...cfg,
          capabilities: {
            ...caps,
            probedAt: new Date().toISOString(),
            probedModel: cfg.model,
          },
        });
        await refresh();
        setProbeText(probeSummary(caps));
      } else {
        const cfg: AsrSettings = {
          providerType: 'openai-compat',
          baseUrl: baseUrl.trim() || undefined,
          model: model.trim(),
        };
        const key = apiKey.trim() || rt.asrKey;
        const adapter = makeAsrAdapter(cfg, deviceMediaIO);
        // 用内嵌的 1 秒 WAV 试转一次，能返回就算通了
        const res = await adapter.transcribe(
          {
            audio: { kind: 'base64', base64: testWavBase64(), mime: 'audio/wav' },
            filename: 'probe.wav',
          },
          toAsrProviderConfig(cfg, key),
        );
        setProbeText(`ASR 可用，返回：${res.text || '（空文本，仍算连通）'}`);
      }
    } catch (e) {
      setProbeText(`探测失败：${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  };

  const isLlm = slot === 'llm';

  return (
    <Screen>
      <Panel>
        <SectionTitle>配置哪个槽位</SectionTitle>
        <View style={{ flexDirection: 'row', gap: 6 }}>
          <Chip label="主 LLM" active={isLlm} onPress={() => setSlot('llm')} />
          <Chip label="ASR" active={!isLlm} onPress={() => setSlot('asr')} />
        </View>
        <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
          {isLlm
            ? '主模型负责图片理解、描述生成与结构抽取。没有图片能力的模型也能用，图片会降级成纯附件。'
            : 'ASR 是可选的。不配也能用：语音会先存着，之后补一句话即可。'}
        </Text>
      </Panel>

      <Panel>
        {isLlm ? (
          <>
            <SectionTitle>协议</SectionTitle>
            <View style={{ flexDirection: 'row', gap: 6 }}>
              <Chip
                label="Anthropic"
                active={providerType === 'anthropic'}
                onPress={() => setProviderType('anthropic')}
              />
              <Chip
                label="OpenAI 兼容"
                active={providerType === 'openai-compat'}
                onPress={() => setProviderType('openai-compat')}
              />
            </View>
            {providerType === 'anthropic' ? (
              <>
                <SectionTitle>认证方式</SectionTitle>
                <View style={{ flexDirection: 'row', gap: 6 }}>
                  <Chip
                    label="x-api-key（官方）"
                    active={authStyle === 'x-api-key'}
                    onPress={() => setAuthStyle('x-api-key')}
                  />
                  <Chip
                    label="Bearer（网关）"
                    active={authStyle === 'bearer'}
                    onPress={() => setAuthStyle('bearer')}
                  />
                </View>
              </>
            ) : null}
          </>
        ) : null}

        <Field
          label="Base URL"
          value={baseUrl}
          onChangeText={setBaseUrl}
          autoCapitalize="none"
          placeholder={isLlm ? 'http://192.168.1.9:7788' : 'https://api.openai.com'}
          hint="局域网网关请填 PC 的局域网 IP；手机要与 PC 在同一个 Wi-Fi 下"
        />
        <Field
          label="模型名"
          value={model}
          onChangeText={setModel}
          autoCapitalize="none"
          placeholder={isLlm ? 'claude-opus-5' : 'whisper-1'}
        />
        {isLlm ? (
          <Field
            label="User-Agent（可选）"
            value={userAgent}
            onChangeText={setUserAgent}
            autoCapitalize="none"
            placeholder="claude-cli/2.1.268 (external, cli)"
            hint="部分网关按 UA 路由，需要伪装成已知客户端"
          />
        ) : null}
        <Field
          label="API Key"
          value={apiKey}
          onChangeText={setApiKeyValue}
          autoCapitalize="none"
          secureTextEntry
          placeholder={currentKey ? `已保存（${maskApiKey(currentKey)}），留空则不变` : 'sk-...'}
          hint="只写入系统密钥库，不入库、不进备份"
        />
      </Panel>

      <Panel>
        <SectionTitle hint={isLlm ? '发一条纯文本与一张 64×64 测试图各试一次' : '发一段 1 秒测试音频试转'}>
          连通性 / 能力探测
        </SectionTitle>
        <Button title="开始探测" variant="secondary" loading={busy} onPress={() => void onProbe()} />
        {probeText ? (
          <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 18 }}>{probeText}</Text>
        ) : null}
        {isLlm && rt.llm?.capabilities ? (
          <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
            上次探测（{rt.llm.capabilities.probedModel}，{rt.llm.capabilities.probedAt.slice(0, 19)}）：
            配置{capsMark(rt.llm.capabilities.text)}、图片{capsMark(rt.llm.capabilities.vision)}
          </Text>
        ) : null}
      </Panel>

      <Button title="保存配置" loading={busy} onPress={() => void onSave()} />
      <Button
        title="保存并立刻补跑一次队列"
        variant="secondary"
        onPress={() => {
          void (async () => {
            await onSave();
            const next = await refresh();
            if (next) await runQueueNow(next);
          })();
        }}
      />
    </Screen>
  );
}
