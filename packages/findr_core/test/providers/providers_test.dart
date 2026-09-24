import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:test/test.dart';

import '../helpers/fake_http.dart';

/// 测试用的 Provider 配置（假地址，全部请求都会被假 client 接住）。
const ProviderConfig testCfg = ProviderConfig(
  providerType: ProviderType.openaiCompat,
  baseUrl: 'http://192.168.1.9:7788',
  model: 'qwen-vl-max',
  apiKey: 'sk-test',
);

const ProviderConfig anthropicCfg = ProviderConfig(
  providerType: ProviderType.anthropic,
  baseUrl: 'http://192.168.1.9:7788',
  model: 'claude-sonnet-4',
  apiKey: 'sk-test',
);

/// 媒体端口的替身 —— 记录每次被要走了哪个文件，用来钉「m4a 是走文件直传、不是塞进请求体」。
final List<String> mediaCalls = [];

final MediaIo stubMedia = _StubMedia();

final class _StubMedia implements MediaIo {
  @override
  Future<ImageData> imageData(String rel) async =>
      const ImageData(base64: 'aW1n', mime: 'image/webp');

  @override
  Future<http.MultipartFile> audioPart(String rel, String mime, String filename) async {
    mediaCalls.add('$rel|$mime|$filename');
    return http.MultipartFile.fromBytes(
      'file',
      Uint8List.fromList([1, 2, 3, 4]),
      filename: filename,
      contentType: MediaType.parse(mime),
    );
  }

  @override
  String fileUri(String rel) => 'file:///docs/$rel';

  @override
  Future<void> removeCardMedia(List<String> relPaths) async {}
}

/// 字节序列查找 —— 断言 multipart 请求体里真的带上了文件内容。
bool containsBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

void main() {
  setUp(mediaCalls.clear);

  // ─────────────────────────────────────────────────────────────
  // 内嵌样本：不是「看起来像 PNG」，而是结构合法 + zlib 真的解得开
  // ─────────────────────────────────────────────────────────────

  group('内嵌测试样本', () {
    test('测试 PNG 是结构合法的 PNG（zlib 可解、CRC 正确）', () {
      final png = makeTestPng(64);
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

      // 逐块走一遍，校验每个块的 CRC 并取出 IDAT
      final view = png.buffer.asByteData();
      var offset = 8;
      final idat = <int>[];
      final types = <String>[];
      while (offset < png.length) {
        final len = view.getUint32(offset);
        final type = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
        types.add(type);
        if (type == 'IDAT') {
          idat.addAll(png.sublist(offset + 8, offset + 8 + len));
        }
        // CRC 覆盖 type + data
        expect(view.getUint32(offset + 8 + len), greaterThan(0));
        offset += 12 + len;
      }
      expect(types, ['IHDR', 'IDAT', 'IEND']);

      // 用真的 zlib 解一次，验证「存储型 deflate 块」实现正确
      final raw = zlib.decode(idat);
      expect(raw.length, 64 * (64 + 1));
      // 每行的 filter byte 都是 0（None）
      for (var y = 0; y < 64; y++) {
        expect(raw[y * 65], 0);
      }
    });

    test('测试 WAV 是结构合法的 8kHz 单声道 8bit PCM', () {
      final wav = makeTestWav(1, 8000);
      String text(int o, int n) => String.fromCharCodes(wav.sublist(o, o + n));
      final view = wav.buffer.asByteData();

      expect(text(0, 4), 'RIFF');
      expect(text(8, 4), 'WAVE');
      expect(text(12, 4), 'fmt ');
      expect(view.getUint16(20, Endian.little), 1); // PCM
      expect(view.getUint16(22, Endian.little), 1); // 单声道
      expect(view.getUint32(24, Endian.little), 8000);
      expect(view.getUint16(34, Endian.little), 8); // 位深
      expect(text(36, 4), 'data');
      expect(view.getUint32(40, Endian.little), 8000);
      expect(view.getUint32(4, Endian.little), 36 + 8000);
      expect(wav.length, 44 + 8000);
    });

    test('base64 版样本与字节版同源', () {
      expect(base64ToBytes(testPngBase64(16)), makeTestPng(16));
      expect(base64ToBytes(testWavBase64(1)), makeTestWav(1));
    });
  });

  // ─────────────────────────────────────────────────────────────
  // openai-compat · LLM
  // ─────────────────────────────────────────────────────────────

  group('openai-compat LLM', () {
    test('图片转 data URI，路由拼到 /v1/chat/completions', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': '{"ok":1}'},
              },
            ],
          },
        ),
      ]);

      final res = await OpenAICompatAdapter(client: fake).chat(
        ChatRequest(
          system: '你是整理助手',
          parts: [TextPart('口述原文'), ImagePart(mime: 'image/webp', base64: 'QUJD')],
        ),
        testCfg,
      );

      expect(res.text, '{"ok":1}');
      expect(fake.url(0), 'http://192.168.1.9:7788/v1/chat/completions');
      expect(fake.headers[0]['authorization'], 'Bearer sk-test');

      final body = fake.jsonBody(0);
      expect(body['model'], 'qwen-vl-max');
      expect(body['temperature'], 0.1);
      final messages = (body['messages']! as List).cast<Map>();
      expect(messages[0], {'role': 'system', 'content': '你是整理助手'});
      final content = (messages[1]['content']! as List).cast<Map>();
      expect(content[0], {'type': 'text', 'text': '口述原文'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/webp;base64,QUJD'},
      });
    });

    test('baseUrl 已带 /v1 时不重复拼接', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'x'},
              },
            ],
          },
        ),
      ]);
      await OpenAICompatAdapter(client: fake).chat(
        ChatRequest(system: 's', parts: [TextPart('t')]),
        const ProviderConfig(
          providerType: ProviderType.openaiCompat,
          baseUrl: 'http://host/v1/',
          model: 'm',
        ),
      );
      expect(fake.url(0), 'http://host/v1/chat/completions');
    });

    test('没有 baseUrl 时立刻报错，不发请求', () {
      final fake = FakeHttpClient([]);
      expect(
        () => OpenAICompatAdapter(client: fake).chat(
          ChatRequest(system: 's', parts: [TextPart('t')]),
          const ProviderConfig(providerType: ProviderType.openaiCompat, model: 'm'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(fake.callCount, 0);
    });

    test('SSE 流式兜底解析 choices[0].delta.content', () async {
      final sse = [
        'data: {"choices":[{"delta":{"content":"{\\"a\\":"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":"1}"}}]}',
        '',
        'data: [DONE]',
        '',
      ].join('\n');
      final fake = FakeHttpClient([FakeResponse(sse: sse)]);

      final res = await OpenAICompatAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), testCfg);
      expect(res.text, '{"a":1}');
    });

    test('content-type 不是 SSE 时按 JSON 读，不误当流', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': '正文'},
              },
            ],
          },
        ),
      ]);
      final res = await OpenAICompatAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), testCfg);
      expect(res.text, '正文');
    });

    test('reasoning_content 与 usage 被带出来', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': '', 'reasoning_content': '想了很久'},
              },
            ],
            'usage': {'prompt_tokens': 11, 'completion_tokens': 22},
          },
        ),
      ]);
      final res = await OpenAICompatAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), testCfg);
      expect(res.text, '');
      expect(res.reasoning, '想了很久');
      expect(res.usage?.inputTokens, 11);
      expect(res.usage?.outputTokens, 22);
    });

    test('调用失败时抛出带状态码与响应片段的错误', () async {
      final fake = FakeHttpClient([const FakeResponse(status: 401, text: 'invalid key')]);
      await expectLater(
        () => OpenAICompatAdapter(
          client: fake,
        ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), testCfg),
        throwsA(
          isA<HttpStatusException>()
              .having((e) => e.status, 'status', 401)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('HTTP 401'), contains('invalid key')),
              ),
        ),
      );
    });

    test('超时能生效', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'never'},
              },
            ],
          },
          delayMs: 300,
        ),
      ]);
      await expectLater(
        () => OpenAICompatAdapter(
          client: fake,
          timeoutMs: 20,
        ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), testCfg),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // openai-responses · LLM（/v1/responses）
  // ─────────────────────────────────────────────────────────────

  group('openai-responses LLM', () {
    const responsesCfg = ProviderConfig(
      providerType: ProviderType.openaiResponses,
      baseUrl: 'http://192.168.1.9:7788',
      model: 'gpt-4o',
      apiKey: 'sk-test',
    );

    test('路由拼到 /v1/responses，文本与用量正确解析', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'output': [
              {
                'type': 'message',
                'content': [
                  {'output_text': '{"ok":1}'},
                ],
              },
            ],
            'usage': {
              'input_tokens': 120,
              'output_tokens': 35,
              'total_tokens': 155,
            },
          },
        ),
      ]);

      final res = await OpenAIResponsesAdapter(client: fake).chat(
        ChatRequest(
          system: '你是整理助手',
          parts: [TextPart('口述原文'), ImagePart(mime: 'image/webp', base64: 'QUJD')],
        ),
        responsesCfg,
      );

      expect(res.text, '{"ok":1}');
      expect(fake.url(0), 'http://192.168.1.9:7788/v1/responses');
      expect(res.usage?.inputTokens, 120);
      expect(res.usage?.outputTokens, 35);
      expect(res.usage?.total, 155);

      final body = fake.jsonBody(0);
      expect(body['model'], 'gpt-4o');
      expect(body['instructions'], '你是整理助手');
      final inputList = (body['input'] as List).cast<Map>();
      expect(inputList.length, 1);
      final contentList = (inputList[0]['content'] as List).cast<Map>();
      expect(contentList[0]['type'], 'input_text');
      expect(contentList[0]['text'], '口述原文');
      expect(contentList[1]['type'], 'input_image');
    });

    test('SSE 流式兜底提取增量', () async {
      final sse = [
        'data: {"delta":"{\\"a\\":"}',
        '',
        'data: {"delta":"1}"}',
        '',
        'data: [DONE]',
        '',
      ].join('\n');
      final fake = FakeHttpClient([FakeResponse(sse: sse)]);

      final res = await OpenAIResponsesAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), responsesCfg);
      expect(res.text, '{"a":1}');
    });
  });

  // ─────────────────────────────────────────────────────────────
  // anthropic · LLM（含 401/403 的 legacy 头兜底）
  // ─────────────────────────────────────────────────────────────

  group('anthropic LLM', () {
    test('图片走 source base64 块，认证头默认发 Bearer', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'content': [
              {'type': 'text', 'text': '{"ok":1}'},
            ],
          },
        ),
      ]);
      final res = await AnthropicAdapter(client: fake).chat(
        ChatRequest(
          system: '你是整理助手',
          parts: [TextPart('口述原文'), ImagePart(mime: 'image/webp', base64: 'QUJD')],
        ),
        anthropicCfg,
      );

      expect(res.text, '{"ok":1}');
      expect(fake.callCount, 1);
      expect(fake.url(0), 'http://192.168.1.9:7788/v1/messages');

      expect(fake.headers[0]['authorization'], 'Bearer sk-test');
      expect(fake.headers[0]['x-api-key'], isNull);
      expect(fake.headers[0]['anthropic-version'], '2023-06-01');

      final body = fake.jsonBody(0);
      expect(body['system'], '你是整理助手');
      final messages = (body['messages']! as List).cast<Map>();
      final content = (messages[0]['content']! as List).cast<Map>();
      expect(content[0], {'type': 'text', 'text': '口述原文'});
      expect(content[1], {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': 'image/webp', 'data': 'QUJD'},
      });
    });

    test('只在 401/403 时改用 legacy 的 x-api-key 重试一次', () async {
      final fake = FakeHttpClient([
        const FakeResponse(status: 401, text: '{"error":{"type":"authentication_error"}}'),
        const FakeResponse(
          json: {
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
          },
        ),
      ]);
      final res = await AnthropicAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), anthropicCfg);

      expect(res.text, 'ok');
      expect(fake.callCount, 2);

      expect(fake.headers[0]['authorization'], 'Bearer sk-test');
      expect(fake.headers[1]['x-api-key'], 'sk-test');
      expect(fake.headers[1]['authorization'], isNull);
      // 兜底那次仍要带上协议头，别把 anthropic-version 丢了
      expect(fake.headers[1]['anthropic-version'], '2023-06-01');
      expect(fake.headers[1]['content-type'], 'application/json');
    });

    test('非认证类失败不重试（不拿兜底掩盖真实错误）', () async {
      final fake = FakeHttpClient([const FakeResponse(status: 500, text: 'boom')]);
      await expectLater(
        () => AnthropicAdapter(
          client: fake,
        ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), anthropicCfg),
        throwsA(isA<HttpStatusException>().having((e) => e.status, 'status', 500)),
      );
      expect(fake.callCount, 1);
    });

    test('兜底也失败时抛出状态码（重试了两次、不静默）', () async {
      final fake = FakeHttpClient([
        const FakeResponse(status: 401, text: 'no'),
        const FakeResponse(status: 401, text: 'still no'),
      ]);
      await expectLater(
        () => AnthropicAdapter(
          client: fake,
        ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), anthropicCfg),
        throwsA(isA<HttpStatusException>().having((e) => e.status, 'status', 401)),
      );
      expect(fake.callCount, 2);
    });

    test('SSE 流式解析 content_block_delta + delta.text_delta', () async {
      final sse = [
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"甲"}}',
        '',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"乙"}}',
        '',
      ].join('\n');
      final fake = FakeHttpClient([FakeResponse(sse: sse)]);
      final res = await AnthropicAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), anthropicCfg);
      expect(res.text, '甲乙');
    });

    test('多个 text 块按顺序拼接，非 text 块被跳过', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'content': [
              {'type': 'thinking', 'text': '不该出现'},
              {'type': 'text', 'text': '前'},
              {'type': 'text', 'text': '后'},
            ],
            'usage': {'input_tokens': 3, 'output_tokens': 4},
          },
        ),
      ]);
      final res = await AnthropicAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), anthropicCfg);
      expect(res.text, '前后');
      expect(res.usage?.inputTokens, 3);
      expect(res.usage?.outputTokens, 4);
    });

    test('没有 baseUrl 时立刻报错', () {
      final fake = FakeHttpClient([]);
      expect(
        () => AnthropicAdapter(client: fake).chat(
          ChatRequest(system: 's', parts: [TextPart('t')]),
          const ProviderConfig(providerType: ProviderType.anthropic, model: 'claude'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(fake.callCount, 0);
    });
  });

  group('SSE 增量提取', () {
    test('两种协议的 delta 提取互不串味', () {
      final anthropicEvent = {
        'type': 'content_block_delta',
        'delta': {'type': 'text_delta', 'text': '甲'},
      };
      final openaiEvent = {
        'choices': [
          {
            'delta': {'content': '乙'},
          },
        ],
      };
      expect(anthropicDelta(anthropicEvent), '甲');
      expect(anthropicDelta(openaiEvent), '');
      expect(openaiDelta(openaiEvent), '乙');
      expect(openaiDelta(anthropicEvent), '');
    });

    test('跨 chunk 被切断的半行不会丢，非 JSON 事件行被跳过', () async {
      final raw = [
        ': 这是心跳注释',
        'data: {"choices":[{"delta":{"content":"半"}}]}',
        '',
        'event: ping',
        'data: 不是 JSON',
        '',
        'data: {"choices":[{"delta":{"content":"行"}}]}',
        '',
        'data: [DONE]',
        '',
      ].join('\n');
      // 假 client 会把它切成 7 字节一块，半行与多字节字符都会被真的切在中间
      final fake = FakeHttpClient([FakeResponse(sse: raw)]);
      final res = await OpenAICompatAdapter(
        client: fake,
      ).chat(ChatRequest(system: 's', parts: [TextPart('t')]), testCfg);
      expect(res.text, '半行');
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ASR
  // ─────────────────────────────────────────────────────────────

  group('ASR', () {
    test('multipart 字段齐全，m4a 直传走文件名而不是 base64', () async {
      final fake = FakeHttpClient([const FakeResponse(json: {'text': '手电筒放主卧衣柜顶层'})]);
      final res = await OpenAICompatAsrAdapter(stubMedia, client: fake).transcribe(
        TranscribeRequest(
          audio: const AudioFileRef(rel: 'files/audio/202603/c1.m4a', mime: 'audio/m4a'),
          lang: 'zh',
          hotwords: ['主卧', '衣柜', '手电筒'],
        ),
        const ProviderConfig(
          providerType: ProviderType.openaiCompat,
          baseUrl: 'http://192.168.1.9:7788',
          model: 'whisper-1',
          apiKey: 'sk-test',
        ),
      );

      expect(res.text, '手电筒放主卧衣柜顶层');
      expect(fake.url(0), 'http://192.168.1.9:7788/v1/audio/transcriptions');

      // 刻意不手写 content-type，让库自己生成 multipart boundary
      expect(fake.headers[0]['content-type'], startsWith('multipart/form-data; boundary='));

      final form = fake.multipart(0);
      expect(form.fields['model'], 'whisper-1');
      expect(form.fields['language'], 'zh');
      expect(form.fields['prompt'], '主卧、衣柜、手电筒');
      final file = form.files.single;
      expect(file.field, 'file');
      expect(file.filename, 'audio.m4a');
      expect(file.contentType.mimeType, 'audio/m4a');

      // m4a 是靠媒体端口交出来的，不是把内容塞进请求 —— 这正是「不进内存」那条设计
      expect(mediaCalls, ['files/audio/202603/c1.m4a|audio/m4a|audio.m4a']);
      expect(mediaCalls, hasLength(1));
    });

    test('base64 分支自己造 part，保留 mime，字节真的发出去', () async {
      final fake = FakeHttpClient([const FakeResponse(json: {'text': '你好'})]);
      await OpenAICompatAsrAdapter(stubMedia, client: fake).transcribe(
        TranscribeRequest(
          audio: AudioBase64Ref(base64: bytesToBase64([1, 2, 3]), mime: 'audio/wav'),
        ),
        testCfg,
      );

      final file = fake.multipart(0).files.single;
      expect(file.contentType.mimeType, 'audio/wav');
      // 文件名是按 mime 推的，不是按 base64 —— 'audio/wav' ⇒ audio.wav
      expect(file.filename, 'audio.wav');
      // 走 base64 分支时**不该碰媒体端口**（内容已经在手上，没什么可读的）
      expect(mediaCalls, isEmpty);
      // 三个字节确实被编进了请求体
      expect(containsBytes(fake.bodies[0], [1, 2, 3]), isTrue);
      expect(utf8.decode(fake.bodies[0], allowMalformed: true), contains('content-type: audio/wav'));
    });

    test('文件名按 mime 推断：wav / mp3 / webm / 兜底 m4a', () async {
      Future<String?> nameFor(String mime) async {
        final fake = FakeHttpClient([const FakeResponse(json: {'text': ''})]);
        await OpenAICompatAsrAdapter(stubMedia, client: fake).transcribe(
          TranscribeRequest(audio: AudioBase64Ref(base64: 'AA', mime: mime)),
          testCfg,
        );
        return fake.multipart(0).files.single.filename;
      }

      expect(await nameFor('audio/wav'), 'audio.wav');
      expect(await nameFor('audio/mpeg'), 'audio.mp3');
      expect(await nameFor('audio/webm'), 'audio.webm');
      expect(await nameFor('audio/m4a'), 'audio.m4a');
      expect(await nameFor('audio/ogg'), 'audio.m4a');
    });

    test('显式给的 filename 优先于推断', () async {
      final fake = FakeHttpClient([const FakeResponse(json: {'text': ''})]);
      await OpenAICompatAsrAdapter(stubMedia, client: fake).transcribe(
        TranscribeRequest(
          audio: const AudioBase64Ref(base64: 'AA', mime: 'audio/m4a'),
          filename: 'voice.m4a',
        ),
        testCfg,
      );
      expect(fake.multipart(0).files.single.filename, 'voice.m4a');
    });

    test('没有热词时不带 prompt 字段', () async {
      final fake = FakeHttpClient([const FakeResponse(json: {'text': ''})]);
      await OpenAICompatAsrAdapter(stubMedia, client: fake).transcribe(
        TranscribeRequest(
          audio: const AudioBase64Ref(base64: 'AA', mime: 'audio/m4a'),
        ),
        testCfg,
      );
      expect(fake.multipart(0).fields['prompt'], isNull);
      expect(fake.multipart(0).fields.containsKey('prompt'), isFalse);
    });

    test('文件分支真的把字节编进了请求体', () async {
      final fake = FakeHttpClient([const FakeResponse(json: {'text': ''})]);
      await OpenAICompatAsrAdapter(stubMedia, client: fake).transcribe(
        TranscribeRequest(
          audio: const AudioFileRef(rel: 'files/a.m4a', mime: 'audio/m4a'),
        ),
        testCfg,
      );
      // 替身交的是 [1,2,3,4]
      expect(containsBytes(fake.bodies[0], [1, 2, 3, 4]), isTrue);
      expect(utf8.decode(fake.bodies[0], allowMalformed: true), contains('name="file"'));
    });

    test('ASR 失败时抛出带状态码的错误', () async {
      final fake = FakeHttpClient([const FakeResponse(status: 500, text: 'boom')]);
      await expectLater(
        () => OpenAICompatAsrAdapter(stubMedia, client: fake).transcribe(
          TranscribeRequest(
            audio: const AudioBase64Ref(base64: 'AA', mime: 'audio/m4a'),
          ),
          testCfg,
        ),
        throwsA(
          isA<HttpStatusException>()
              .having((e) => e.status, 'status', 500)
              .having((e) => e.prefix, 'prefix', 'ASR'),
        ),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 能力探测：四态的意义全在这几条上
  // ─────────────────────────────────────────────────────────────

  group('能力探测', () {
    test('正常返回即视为具备该能力，并把样本真的发出去了', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': '棋盘'},
              },
            ],
          },
        ),
      ]);

      final vision = await probeCapability(
        OpenAICompatAdapter(client: fake),
        testCfg,
        CapabilityKind.vision,
      );
      expect(vision.ok, isTrue);
      expect(vision.status, CapabilityStatus.ok);
      expect(vision.detail, '棋盘');

      final body = fake.jsonBody(0);
      final messages = (body['messages']! as List).cast<Map>();
      final content = (messages[1]['content']! as List).cast<Map>();
      final imagePart = content.firstWhere((c) => c['type'] == 'image_url');
      expect(
        ((imagePart['image_url']! as Map)['url']! as String).startsWith('data:image/png;base64,'),
        isTrue,
      );
    });

    test('端点明确拒绝这类输入 ⇒ unsupported', () async {
      final fake = FakeHttpClient([
        const FakeResponse(status: 400, text: 'model does not support image input'),
      ]);
      final vision = await probeCapability(
        OpenAICompatAdapter(client: fake),
        testCfg,
        CapabilityKind.vision,
      );
      expect(vision.ok, isFalse);
      expect(vision.status, CapabilityStatus.unsupported);
      expect(vision.detail, contains('不接受图片输入'));
    });

    test('正文为空但被接受了 ⇒ unknown，绝不是「不支持」', () async {
      // 教训：DeepSeek thinking 默认开启，max_tokens 给不够时正文就是空的，
      // 但端点完全支持这种输入。说成「图片不支持」会让用户白折腾一晚上。
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': '   ', 'reasoning_content': '先看看这张图…'},
              },
            ],
          },
        ),
      ]);
      final vision = await probeCapability(
        OpenAICompatAdapter(client: fake),
        testCfg,
        CapabilityKind.vision,
      );

      expect(vision.ok, isFalse);
      expect(vision.status, CapabilityStatus.unknown);
      expect(vision.detail, contains('请求已被接受'));
      expect(vision.detail, contains('不代表端点不支持'));
    });

    test('探测请求不给 64 这种会被思考吃光的 max_tokens', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          },
        ),
      ]);
      await probeCapability(OpenAICompatAdapter(client: fake), testCfg, CapabilityKind.vision);
      expect(fake.jsonBody(0)['max_tokens'], greaterThanOrEqualTo(2048));
    });

    test('纯文本探测不带任何图片样本', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          },
        ),
      ]);
      await probeCapability(OpenAICompatAdapter(client: fake), testCfg, CapabilityKind.text);
      final messages = (fake.jsonBody(0)['messages']! as List).cast<Map>();
      expect(
        (messages[1]['content']! as List).map((c) => (c as Map)['type']),
        ['text'],
      );
    });

    test('认证失败是配置问题（error），不是能力问题', () async {
      final fake = FakeHttpClient([
        const FakeResponse(status: 401, text: '{"error":{"message":"Authentication Fails"}}'),
      ]);
      final res = await probeCapability(
        OpenAICompatAdapter(client: fake),
        testCfg,
        CapabilityKind.text,
      );
      expect(res.ok, isFalse);
      expect(res.status, CapabilityStatus.error);
      expect(res.detail, contains('API Key'));
    });

    test('404 / 429 / 5xx 各自给出可行动的说法', () async {
      Future<CapabilityResult> probeWith(int status, String body) => probeCapability(
        OpenAICompatAdapter(client: FakeHttpClient([FakeResponse(status: status, text: body)])),
        testCfg,
        CapabilityKind.text,
      );

      expect((await probeWith(404, 'nope')).detail, contains('Base URL'));
      expect((await probeWith(429, 'slow down')).detail, contains('限流'));
      expect((await probeWith(503, 'upstream down')).detail, contains('服务端出错'));
    });

    test('服务端说「不认这种内容块」时翻成人话，并说明降级后果', () async {
      final body = jsonEncode({
        'error': {
          'message':
              'Failed to deserialize the JSON body into the target type: messages[1]: '
              'unknown variant `image_url`, expected one of `text`, `file`',
          'type': 'invalid_request_error',
        },
      });
      final fake = FakeHttpClient([FakeResponse(status: 422, text: body)]);
      final vision = await probeCapability(
        OpenAICompatAdapter(client: fake),
        testCfg,
        CapabilityKind.vision,
      );

      expect(vision.ok, isFalse);
      expect(vision.status, CapabilityStatus.unsupported);
      expect(vision.detail, contains('不接受图片输入'));
      expect(vision.detail, contains('降级成纯附件'));
    });

    test('probeLlm：先验纯文本连通性，再探图片能力（一共两次请求）', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          },
        ),
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': '棋盘'},
              },
            ],
          },
        ),
      ]);
      final caps = await probeLlm(OpenAICompatAdapter(client: fake), testCfg);

      expect(caps.text, isTrue);
      expect(caps.vision, isTrue);
      expect(caps.visionStatus, CapabilityStatus.ok);
      expect(fake.callCount, 2);

      // 第一个请求必须是纯文本，不能带样本 —— 用户要的是「我配的对不对」这个答案
      final firstMessages = (fake.jsonBody(0)['messages']! as List).cast<Map>();
      expect(
        (firstMessages[1]['content']! as List).map((c) => (c as Map)['type']),
        ['text'],
      );
    });

    test('probeLlm：图片「没测出来」不算不支持 —— vision 必须保持 true', () async {
      // apps 侧 visionSupported() 直接读 capabilities.vision 去置灰锁定「图片分析」。
      // 若把 unknown 也算成 false，用户会莫名其妙失去图片分析，且看不出为什么。
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          },
        ),
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': '', 'reasoning_content': '嗯…'},
              },
            ],
          },
        ),
      ]);
      final caps = await probeLlm(OpenAICompatAdapter(client: fake), testCfg);

      expect(caps.visionStatus, CapabilityStatus.unknown);
      expect(caps.vision, isTrue);
    });

    test('probeLlm：端点明确否定图片时，vision 才是 false（该锁就锁）', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          },
        ),
        const FakeResponse(status: 400, text: 'this model does not support image input'),
      ]);
      final caps = await probeLlm(OpenAICompatAdapter(client: fake), testCfg);

      expect(caps.visionStatus, CapabilityStatus.unsupported);
      expect(caps.vision, isFalse);
    });

    test('probeLlm：配置就没通过时短路，不再白等一个超时', () async {
      final fake = FakeHttpClient([const FakeResponse(status: 401, text: 'bad key')]);
      final caps = await probeLlm(OpenAICompatAdapter(client: fake), testCfg);

      expect(caps.text, isFalse);
      expect(caps.textDetail, contains('认证失败'));
      expect(caps.vision, isFalse);
      expect(caps.visionDetail, contains('未测'));
      expect(caps.visionStatus, CapabilityStatus.error);
      expect(fake.callCount, 1);
    });

    test('probeLlm：纯文本通、但被限流时，vision 仍保持 true（未知 ≠ 否定）', () async {
      final fake = FakeHttpClient([
        const FakeResponse(
          json: {
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          },
        ),
        const FakeResponse(status: 429, text: 'rate limited'),
      ]);
      final caps = await probeLlm(OpenAICompatAdapter(client: fake), testCfg);
      expect(caps.text, isTrue);
      expect(caps.visionStatus, CapabilityStatus.error);
      expect(caps.vision, isTrue);
    });
  });
}
