/// 备份带回来的 API Key，怎么写进本机 —— 见 `platform/secure.dart` 的
/// [keysToRestore]。
///
/// 规则是**全量覆盖**：备份里带了哪几把，就用它覆盖本机同名 Key；
/// 备份里没有的槽位返回 null，表示清空本机。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:findr_app/platform/secure.dart';

const String llmStorage = 'findr.llm.apiKey';
const String asrStorage = 'findr.asr.apiKey';

void main() {
  group('导入备份时恢复 API Key', () {
    test('备份里带几把就覆盖几把', () {
      final plan = keysToRestore(<String, String>{
        llmStorage: 'sk-new-llm',
        asrStorage: 'sk-new-asr',
      });
      expect(plan, <ApiKeySlot, String?>{
        ApiKeySlot.llm: 'sk-new-llm',
        ApiKeySlot.asr: 'sk-new-asr',
      });
    });

    test('只有一把：另一把为 null（清空本机）', () {
      final plan = keysToRestore(<String, String>{llmStorage: 'sk-from-backup'});
      expect(plan, <ApiKeySlot, String?>{
        ApiKeySlot.llm: 'sk-from-backup',
        ApiKeySlot.asr: null,
      });
    });

    test('备份里的空值等同没有：清空本机', () {
      final plan = keysToRestore(<String, String>{
        llmStorage: '',
        asrStorage: 'sk-asr',
      });
      expect(plan, <ApiKeySlot, String?>{
        ApiKeySlot.llm: null,
        ApiKeySlot.asr: 'sk-asr',
      });
    });

    test('这份包一把 Key 都没有：两个槽位都清空', () {
      expect(keysToRestore(const <String, String>{}), <ApiKeySlot, String?>{
        ApiKeySlot.llm: null,
        ApiKeySlot.asr: null,
      });
    });

    test('包里出现了不认识的槽位名：忽略，两个已知槽位仍按没有处理', () {
      final plan = keysToRestore(const <String, String>{
        'findr.somethingElse.apiKey': 'sk-x',
      });
      expect(plan, <ApiKeySlot, String?>{
        ApiKeySlot.llm: null,
        ApiKeySlot.asr: null,
      });
    });

    test('掩码只露首尾各 4 位，太短的整个糊掉', () {
      expect(maskApiKey(null), '未配置');
      expect(maskApiKey(''), '未配置');
      expect(maskApiKey('abcd'), '••••••');
      expect(maskApiKey('sk-12345678-wxyz'), 'sk-1••••wxyz');
    });
  });
}
