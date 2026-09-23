import 'dart:convert';

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// `settings.dart` 的验收网 —— 它是「设置项的唯一权威定义」，
/// 读错一个字段的后果是用户改了设置却不生效。
///
/// ⚠️ 重点盯的是**浅合并的语义**（`{...DEFAULTS, ...stored}`），
/// 实现上是手写的 `containsKey` 判断。
/// 最容易写错的一处：**键存在但值是 null 时不能再退回默认值** ——
/// `visionLast: null` 是有意义的状态（「用户还没手动切过」），不是「缺这个字段」。
void main() {
  late SqliteDriver db;

  setUp(() => db = makeDb());
  tearDown(() => db.close());

  group('主模型设置', () {
    test('没写过时读出来是 null', () {
      expect(readLlmSettings(db), isNull);
    });

    test('写读往返：字段与 JSON 形状都对得上', () {
      const value = LlmSettings(
        providerType: ProviderType.anthropic,
        baseUrl: 'http://192.168.1.9:7788',
        model: 'claude-sonnet-4',
        userAgent: 'claude-cli/1.0',
      );
      writeLlmSettings(db, value);

      final read = readLlmSettings(db)!;
      expect(read.providerType, ProviderType.anthropic);
      expect(read.baseUrl, 'http://192.168.1.9:7788');
      expect(read.model, 'claude-sonnet-4');
      expect(read.userAgent, 'claude-cli/1.0');
      expect(read.capabilities, isNull);

      // 落库的是字面 wire 值，不是枚举下标 —— 换实现也不能变
      final raw = getSetting<Map<String, Object?>>(db, SettingsKeys.llm)!;
      expect(raw['providerType'], 'anthropic');
    });

    test('认证头不再是可配项：老安装残留的 authStyle 被忽略，不报错', () {
      // authStyle 已删；老数据里它还在 JSON 里，读的时候必须无视
      setSetting(db, SettingsKeys.llm, {
        'providerType': 'openai-compat',
        'baseUrl': 'http://host',
        'model': 'gpt-4o-mini',
        'authStyle': 'x-api-key',
      });
      final read = readLlmSettings(db)!;
      expect(read.model, 'gpt-4o-mini');
      expect(read.providerType, ProviderType.openaiCompat);
    });

    test('值不合规的 providerType 退回 openai-compat（有意为之，见代码注释）', () {
      setSetting(db, SettingsKeys.llm, {'providerType': 'bogus', 'model': 'm'});
      expect(readLlmSettings(db)!.providerType, ProviderType.openaiCompat);
    });

    test('整个值是坏 JSON 时当成没配置（而不是崩）', () {
      db
          .prepare('INSERT INTO settings (key, value) VALUES (?, ?)')
          .run([SettingsKeys.llm, '这不是 JSON']);
      expect(readLlmSettings(db), isNull);
    });

    test('能力缓存写读往返', () {
      writeLlmSettings(
        db,
        const LlmSettings(
          providerType: ProviderType.openaiCompat,
          model: 'qwen-vl-max',
          capabilities: CapabilityCache(
            text: true,
            textDetail: 'ok',
            vision: false,
            visionDetail: '该端点不接受图片输入',
            visionStatus: CapabilityStatus.unsupported,
            probedAt: '2026-03-01T00:00:00.000Z',
            probedModel: 'qwen-vl-max',
          ),
        ),
      );
      final caps = readLlmSettings(db)!.capabilities!;
      expect(caps.vision, isFalse);
      expect(caps.visionStatus, CapabilityStatus.unsupported);
      expect(caps.text, isTrue);
      expect(caps.probedAt, '2026-03-01T00:00:00.000Z');
    });

    test('能力缓存形状不对时整条丢掉（等于没探过），不影响其余设置', () {
      setSetting(db, SettingsKeys.llm, {
        'providerType': 'openai-compat',
        'model': 'm',
        'capabilities': {'vision': 'yes'}, // 该是 bool，且缺 probedAt / probedModel
      });
      final read = readLlmSettings(db)!;
      expect(read.model, 'm');
      expect(read.capabilities, isNull);
    });

    test('capabilitiesStale：没探过算过期，换了模型算过期，同模型才不算', () {
      expect(capabilitiesStale(const LlmSettings(providerType: ProviderType.openaiCompat, model: 'm')), isTrue);

      const cache = CapabilityCache(
        vision: true,
        visionDetail: 'ok',
        probedAt: '2026-03-01T00:00:00.000Z',
        probedModel: 'qwen-vl-max',
      );
      expect(
        capabilitiesStale(
          const LlmSettings(
            providerType: ProviderType.openaiCompat,
            model: 'qwen-vl-max',
            capabilities: cache,
          ),
        ),
        isFalse,
      );
      expect(
        capabilitiesStale(
          const LlmSettings(
            providerType: ProviderType.openaiCompat,
            model: '另一个模型',
            capabilities: cache,
          ),
        ),
        isTrue,
      );
    });
  });

  group('转写设置', () {
    test('写读往返，且落库 JSON 仍带 providerType（形状是契约）', () {
      writeAsrSettings(db, const AsrSettings(baseUrl: 'http://host', model: 'whisper-1'));
      final read = readAsrSettings(db)!;
      expect(read.model, 'whisper-1');
      expect(read.baseUrl, 'http://host');

      final raw = getSetting<Map<String, Object?>>(db, SettingsKeys.asr)!;
      expect(raw['providerType'], 'openai-compat');
    });

    test('没写过时是 null', () {
      expect(readAsrSettings(db), isNull);
    });
  });

  group('录入设置（浅合并语义）', () {
    test('没写过时全用默认值', () {
      final read = readCaptureSettings(db);
      expect(read.visionDefault, isTrue);
      expect(read.visionLast, isNull);
      expect(read.maxAnalyzeImages, 6);
    });

    test('只写了一个键时，其余仍走默认值', () {
      setSetting(db, SettingsKeys.capture, {'maxAnalyzeImages': 3});
      final read = readCaptureSettings(db);
      expect(read.maxAnalyzeImages, 3);
      expect(read.visionDefault, isTrue);
      expect(read.visionLast, isNull);
    });

    test('显式的 visionLast: null 不会被默认值盖掉', () {
      setSetting(db, SettingsKeys.capture, {'visionDefault': false, 'visionLast': null});
      final read = readCaptureSettings(db);
      expect(read.visionDefault, isFalse);
      expect(read.visionLast, isNull);
    });

    test('visionLast 有值时读得出来', () {
      setSetting(db, SettingsKeys.capture, {'visionLast': false});
      expect(readCaptureSettings(db).visionLast, isFalse);
    });

    test('类型不对的字段退回默认值（不崩）', () {
      setSetting(db, SettingsKeys.capture, {'maxAnalyzeImages': '很多', 'visionDefault': 1});
      final read = readCaptureSettings(db);
      expect(read.maxAnalyzeImages, 6);
      expect(read.visionDefault, isTrue);
    });

    test('写读往返', () {
      writeCaptureSettings(
        db,
        const CaptureSettings(visionDefault: false, visionLast: true, maxAnalyzeImages: 2),
      );
      final read = readCaptureSettings(db);
      expect(read.visionDefault, isFalse);
      expect(read.visionLast, isTrue);
      expect(read.maxAnalyzeImages, 2);
    });
  });

  group('检索设置', () {
    test('默认不自动回答（隐私：默认不外发记忆内容）', () {
      expect(readSearchSettings(db).autoAnswer, isFalse);
    });

    test('写读往返', () {
      writeSearchSettings(db, const SearchSettings(autoAnswer: true));
      expect(readSearchSettings(db).autoAnswer, isTrue);
    });

    test('只存了别的键时仍走默认值', () {
      setSetting(db, SettingsKeys.search, {'别的': 1});
      expect(readSearchSettings(db).autoAnswer, isFalse);
    });
  });

  group('派生值', () {
    test('effectiveVision：模型不支持 ⇒ 恒定关（置灰锁定）', () {
      const capture = CaptureSettings(visionDefault: true, visionLast: true, maxAnalyzeImages: 6);
      expect(effectiveVision(capture, false), isFalse);
      expect(effectiveVision(capture, true), isTrue);
    });

    test('effectiveVision：用户手动切过就用上次的，否则用默认', () {
      const neverTouched = CaptureSettings(
        visionDefault: true,
        visionLast: null,
        maxAnalyzeImages: 6,
      );
      expect(effectiveVision(neverTouched, true), isTrue);

      const turnedOff = CaptureSettings(
        visionDefault: true,
        visionLast: false,
        maxAnalyzeImages: 6,
      );
      expect(effectiveVision(turnedOff, true), isFalse);

      const turnedOn = CaptureSettings(
        visionDefault: false,
        visionLast: true,
        maxAnalyzeImages: 6,
      );
      expect(effectiveVision(turnedOn, true), isTrue);
    });
  });

  group('工厂', () {
    test('设置 + Key → ProviderConfig（Key 由调用方从安全存储取出）', () {
      final cfg = toProviderConfig(
        const LlmSettings(
          providerType: ProviderType.anthropic,
          baseUrl: 'http://host',
          model: 'claude-sonnet-4',
          userAgent: 'claude-cli/1.0',
        ),
        'sk-x',
      );
      expect(cfg.providerType, ProviderType.anthropic);
      expect(cfg.model, 'claude-sonnet-4');
      expect(cfg.apiKey, 'sk-x');
      expect(cfg.userAgent, 'claude-cli/1.0');
    });

    test('没有 Key 时 apiKey 是 null（不是空串）', () {
      expect(
        toProviderConfig(const LlmSettings(providerType: ProviderType.openaiCompat, model: 'm'), null).apiKey,
        isNull,
      );
      expect(
        toAsrProviderConfig(const AsrSettings(model: 'whisper-1'), null).apiKey,
        isNull,
      );
      expect(
        toAsrProviderConfig(const AsrSettings(model: 'whisper-1'), null).providerType,
        ProviderType.openaiCompat,
      );
    });

    test('按协议建出对应的适配器', () {
      expect(
        makeLlmAdapter(const LlmSettings(providerType: ProviderType.anthropic, model: 'm')),
        isA<AnthropicAdapter>(),
      );
      expect(
        makeLlmAdapter(const LlmSettings(providerType: ProviderType.openaiCompat, model: 'm')),
        isA<OpenAICompatAdapter>(),
      );
    });

    test('设置里出现不可能用到的协议时显式报错', () {
      expect(
        () => makeLlmAdapter(const LlmSettings(providerType: ProviderType.gemini, model: 'm')),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => makeLlmAdapter(const LlmSettings(providerType: ProviderType.fake, model: 'm')),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('落库 JSON 形状（契约）', () {
    test('写出的 LLM 设置字段名与快照一致', () {
      const value = LlmSettings(
        providerType: ProviderType.openaiCompat,
        baseUrl: 'http://192.168.1.9:7788',
        model: 'qwen-vl-max',
        userAgent: 'ua/1',
        capabilities: CapabilityCache(
          vision: true,
          visionDetail: '棋盘',
          probedAt: '2026-03-01T00:00:00.000Z',
          probedModel: 'qwen-vl-max',
        ),
      );
      expect(
        jsonDecode(jsonEncode(value.toJson())),
        {
          'providerType': 'openai-compat',
          'baseUrl': 'http://192.168.1.9:7788',
          'model': 'qwen-vl-max',
          'userAgent': 'ua/1',
          'capabilities': {
            'vision': true,
            'visionDetail': '棋盘',
            'probedAt': '2026-03-01T00:00:00.000Z',
            'probedModel': 'qwen-vl-max',
          },
        },
      );
    });

    test('可选的空字段不写进 JSON（别把 null 落成 "null" 字符串）', () {
      expect(
        const LlmSettings(providerType: ProviderType.openaiCompat, model: 'm').toJson(),
        {'providerType': 'openai-compat', 'model': 'm'},
      );
      expect(const AsrSettings(model: 'whisper-1').toJson(), {
        'providerType': 'openai-compat',
        'model': 'whisper-1',
      });
    });
  });
}
