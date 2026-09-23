/// 备份带回来的 API Key，到底该不该写进本机 —— 见 `platform/secure.dart` 的
/// [planKeyRestore]。
///
/// 这条规则的**代价是不对称的**：写错了（把正在用的 Key 换掉）用户只会发现
/// 「怎么突然调不通了」，很难联想到是上次导入干的；而少写一把，界面上明明白白
/// 显示「未配置」，用户去设置页填一下就好。所以规则是**只填空槽**，这里钉死它。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:findr_app/platform/secure.dart';

const String llmStorage = 'findr.llm.apiKey';
const String asrStorage = 'findr.asr.apiKey';

void main() {
  group('导入备份时恢复 API Key', () {
    test('本机两把都是空的：备份带回来几把就写几把', () {
      final plan = planKeyRestore(
        incoming: <String, String>{llmStorage: 'sk-new-llm', asrStorage: 'sk-new-asr'},
        current: <ApiKeySlot, String?>{ApiKeySlot.llm: null, ApiKeySlot.asr: null},
      );
      expect(plan.toWrite, <ApiKeySlot, String>{
        ApiKeySlot.llm: 'sk-new-llm',
        ApiKeySlot.asr: 'sk-new-asr',
      });
      expect(plan.skipped, 0);
    });

    test('本机已有 Key：不动它（换掉正在用的 Key 比没配上更难查）', () {
      final plan = planKeyRestore(
        incoming: <String, String>{llmStorage: 'sk-from-backup'},
        current: <ApiKeySlot, String?>{ApiKeySlot.llm: 'sk-already-here'},
      );
      expect(plan.toWrite, isEmpty);
      expect(plan.skipped, 1);
    });

    test('一把空一把有：只补那把空的', () {
      final plan = planKeyRestore(
        incoming: <String, String>{llmStorage: 'sk-llm', asrStorage: 'sk-asr'},
        current: <ApiKeySlot, String?>{ApiKeySlot.llm: 'sk-already-here', ApiKeySlot.asr: ''},
      );
      expect(plan.toWrite, <ApiKeySlot, String>{ApiKeySlot.asr: 'sk-asr'});
      expect(plan.skipped, 1);
    });

    test('空串当没配：备份里的空值不写，本机空串也当空槽', () {
      final plan = planKeyRestore(
        incoming: <String, String>{llmStorage: '', asrStorage: 'sk-asr'},
        current: <ApiKeySlot, String?>{ApiKeySlot.llm: null, ApiKeySlot.asr: null},
      );
      expect(plan.toWrite, <ApiKeySlot, String>{ApiKeySlot.asr: 'sk-asr'});
      expect(plan.skipped, 0);
    });

    test('这份包没带 Key：一个槽位都不动，也不算跳过', () {
      final plan = planKeyRestore(
        incoming: const <String, String>{},
        current: <ApiKeySlot, String?>{ApiKeySlot.llm: null, ApiKeySlot.asr: null},
      );
      expect(plan.toWrite, isEmpty);
      expect(plan.skipped, 0);
    });

    test('包里出现了不认识的槽位名：忽略，不写入任何东西', () {
      final plan = planKeyRestore(
        incoming: const <String, String>{'findr.somethingElse.apiKey': 'sk-x'},
        current: <ApiKeySlot, String?>{ApiKeySlot.llm: null, ApiKeySlot.asr: null},
      );
      expect(plan.toWrite, isEmpty);
      expect(plan.skipped, 0);
    });

    test('掩码只露首尾各 4 位，太短的整个糊掉', () {
      expect(maskApiKey(null), '未配置');
      expect(maskApiKey(''), '未配置');
      expect(maskApiKey('abcd'), '••••••');
      expect(maskApiKey('sk-12345678-wxyz'), 'sk-1••••wxyz');
    });
  });
}
