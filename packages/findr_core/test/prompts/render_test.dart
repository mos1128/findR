import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// `prompts/` 的验收网。
///
/// TS 侧没有独立的 render 测试文件（它由 `advise.test.ts` / `pipeline.test.ts` 间接覆盖），
/// 这里直接打这一层 —— 理由和 builder 相同：它是「模板 + 变量 → 真正发出去的字符串」的关口，
/// 而**模板内容是逐字搬过来的**，最怕的就是渲染时把变量注错位置或忘了吃掉占位符。
void main() {
  group('render', () {
    test('替换 {{key}}，未知占位符换成空串', () {
      expect(render('a={{x}}', {'x': '1'}), 'a=1');
      expect(render('a={{x}}', {}), 'a=');
      expect(render('{{a}}-{{b}}', {'a': '1', 'b': '2'}), '1-2');
      // 只认 ASCII 的 \w：中文占位符不算占位符（JS 与 Dart 在这点上一致）
      expect(render('{{位置}}', {'位置': 'x'}), '{{位置}}');
    });
  });

  group('P1', () {
    test('system 注入分类与位置，并带上 schema / 规则 / 示例', () {
      final s = buildP1System(categories: '（暂无）', locations: '主卧/衣柜');
      expect(s, contains('主卧/衣柜'));
      expect(s, contains('输出 schema（字段名与类型不得改动）'));
      expect(s, contains('desc 写作规范'));
      expect(s, contains('ask 规则'));
      expect(s, contains('备用手电筒')); // fewshot
      expect(s, isNot(contains('{{locations}}'))); // 占位符必须被吃掉
      expect(s, isNot(contains('{{categories}}')));
    });

    test('textOnly 两种模式各追加不同的约束，不传则都不加', () {
      final plain = buildP1System(categories: 'x', locations: 'y');
      final off = buildP1System(
        categories: 'x',
        locations: 'y',
        textOnly: TextOnlyMode.off,
      );
      final unsupported = buildP1System(
        categories: 'x',
        locations: 'y',
        textOnly: TextOnlyMode.unsupported,
      );

      expect(off, contains('本次用户选择不分析图片'));
      expect(unsupported, contains('当前模型无法接收图片'));
      expect(plain, isNot(contains('本次用户选择不分析图片')));
      expect(plain, isNot(contains('当前模型无法接收图片')));
      expect(off, isNot(equals(unsupported)));
    });

    test('user：没有文字输入时给出明确说明，而不是空片段', () {
      expect(buildP1User(null), contains('本次没有文字输入，请仅根据图片判断。'));
      expect(buildP1User('放次卧床头柜了'), contains('放次卧床头柜了'));
    });

    test('describeCardFields：只列有值的字段，分类不由这里注入', () {
      final card = makeCard(
        id: 'c1',
        entity: '护照',
        pathNames: '书房/抽屉',
        tags: const ['证件', '出行'],
        steps: const [
          StepItem(text: '复印', done: false),
          StepItem(text: '贴照片', done: true),
        ],
      );
      final s = describeCardFields(card);
      expect(s, contains('- 实体名：护照'));
      expect(s, contains('- 位置：书房/抽屉'));
      expect(s, contains('- 标签：证件、出行'));
      expect(s, contains('- 步骤：复印；贴照片'));
      expect(s, isNot(contains('分类')));
    });

    test('describeCardFields：全空字段 ⇒ 空串（不产出空白行）', () {
      final card = makeCard(id: 'c1', entity: '', pathNames: null, tags: null, steps: null);
      expect(describeCardFields(card), '');
    });

    test('buildRegenerateDescUser：没有既定事实时就是普通 user 串', () {
      final card = makeCard(id: 'c1', entity: '', transcript: '放抽屉了');
      final s = buildRegenerateDescUser(card);
      expect(s, contains('放抽屉了'));
      expect(s, isNot(contains('既定事实')));
    });

    test('buildRegenerateDescUser：有既定事实时追加锁定说明', () {
      final card = makeCard(id: 'c1', entity: '护照', transcript: '放抽屉了');
      final s = buildRegenerateDescUser(card);
      expect(s, contains('放抽屉了'));
      expect(s, contains('用户已确认以下字段，请视为既定事实，不要改动，只重新生成 desc'));
      expect(s, contains('- 实体名：护照'));
    });
  });

  group('P2 / P3 / P4', () {
    test('buildP2System：注入分类位置，且带上 schema / 规则 / 示例', () {
      final s = buildP2System(categories: '- 物品存取', locations: '主卧');
      expect(s, contains('- 物品存取'));
      expect(s, contains('主卧'));
      expect(s, contains('输出 schema：'));
      expect(s, contains('match_mode 默认 any'));
      expect(s, contains('我护照放哪了')); // fewshot
      expect(s, isNot(contains('{{categories}}')));
      expect(s, isNot(contains('{{locations}}')));
    });

    test('buildP3System / buildP3Input', () {
      expect(buildP3System(), contains('只能依据给出的片段，不得补充片段之外的任何信息'));
      final input = buildP3Input('护照在哪', '[1] id=c1');
      expect(input, contains('用户问题：护照在哪'));
      expect(input, contains('[1] id=c1'));
      expect(input, contains('候选片段（最多 8 条）'));
    });

    test('buildP4System：核心那句「用常识判断」必须在（advise 的命根子）', () {
      expect(buildP4System(), contains('用常识判断'));
      expect(buildP4System(), contains('不得编造 id'));
    });

    test('buildP4Input：四个变量都注进去，含条数', () {
      final input = buildP4Input('出国要带什么', '出国旅游', 4, '1 | passport | 护照');
      expect(input, contains('用户的问题：出国要带什么'));
      expect(input, contains('需要判断的情景：出国旅游'));
      expect(input, contains('记忆库条目（共 4 条'));
      expect(input, contains('1 | passport | 护照'));
      expect(input, isNot(contains('{{inventory}}')));
    });
  });

  group('格式化为提示词片段', () {
    test('formatCategoriesForPrompt：空库给占位，有则带 emoji 与描述', () {
      expect(formatCategoriesForPrompt(const <Category>[]), '（暂无）');
      final text = formatCategoriesForPrompt(const [
        Category(
          id: 'c1',
          name: '物品存取',
          emoji: '📦',
          description: '东西放哪了',
          sort: 0,
          isPreset: true,
        ),
        Category(id: 'c2', name: '待买补货', emoji: null, description: null, sort: 1, isPreset: true),
      ]);
      expect(text, '- 📦物品存取：东西放哪了\n- 待买补货');
    });

    test('formatLocationsForPrompt：只注入一二级，三级容器不注入', () {
      // 主卧 ─ 衣柜 ─ 收纳盒（第三级，不该被注入）
      const locations = <LocationNode>[
        LocationNode(id: 'l1', parentId: null, name: '主卧', sort: 0),
        LocationNode(id: 'l2', parentId: 'l1', name: '衣柜', sort: 0),
        LocationNode(id: 'l3', parentId: 'l2', name: '收纳盒', sort: 0),
        LocationNode(id: 'l4', parentId: null, name: '阳台', sort: 1),
      ];
      final text = formatLocationsForPrompt(locations);
      expect(text, contains('主卧'));
      expect(text, contains('主卧/衣柜'));
      expect(text, contains('阳台'));
      expect(text, isNot(contains('收纳盒')));
      expect(formatLocationsForPrompt(const <LocationNode>[]), '（暂无）');
    });
  });
}
