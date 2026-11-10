/// 备份带回来的 API Key，怎么写进本机 —— 见 `platform/secure.dart` 的
/// [keysToRestore]。
///
/// 规则是**全量覆盖**：备份里带了哪几把，就用它覆盖本机同名 Key。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:findr_app/platform/secure.dart';

const String llmStorage = 'findr.llm.apiKey';
const String asrStorage = 'findr.asr.apiKey';

void main() {
  group('导入备份时恢复 API Key', () {
    test('备份里带几把就写几把，覆盖本机同名 Key', () {
      final plan = keysToRestore(<String, String>{
        llmStorage: 'sk-new-llm',
        asrStorage: 'sk-new-asr',
      });
      expect(plan, <ApiKeySlot, String>{
        ApiKeySlot.llm: 'sk-new-llm',
        ApiKeySlot.asr: 'sk-new-asr',
      });
    });

    test('只有一把也照写，不依赖本机有没有', () {
      final plan = keysToRestore(<String, String>{llmStorage: 'sk-from-backup'});
      expect(plan, <ApiKeySlot, String>{ApiKeySlot.llm: 'sk-from-backup'});
    });

    test('备份里的空值不写', () {
      final plan = keysToRestore(<String, String>{
        llmStorage: '',
        asrStorage: 'sk-asr',
      });
      expect(plan, <ApiKeySlot, String>{ApiKeySlot.asr: 'sk-asr'});
    });

    test('这份包没带 Key：什么都不写', () {
      expect(keysToRestore(const <String, String>{}), isEmpty);
    });

    test('包里出现了不认识的槽位名：忽略，不写入任何东西', () {
      final plan = keysToRestore(const <String, String>{
        'findr.somethingElse.apiKey': 'sk-x',
      });
      expect(plan, isEmpty);
    });

    test('掩码只露首尾各 4 位，太短的整个糊掉', () {
      expect(maskApiKey(null), '未配置');
      expect(maskApiKey(''), '未配置');
      expect(maskApiKey('abcd'), '••••••');
      expect(maskApiKey('sk-12345678-wxyz'), 'sk-1••••wxyz');
    });
  });
}
