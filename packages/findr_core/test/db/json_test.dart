// 这两个函数是所有 JSON 列的咽喉：`tags` / `images` / `path_ids` / `steps` 全靠它们，
// 写错的表现是「卡片能存进去但读出来是空」，所以单独押一层。

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

void main() {
  test('toJson：null 原样返回 null（不是 "null" 字符串）', () {
    expect(toJson(null), isNull);
  });

  test('toJson：数组与对象编码成 JSON 文本', () {
    expect(toJson(['应急', '备用']), '["应急","备用"]');
    expect(toJson(<String, Object?>{'max': 3}), '{"max":3}');
  });

  test('parseJsonArray：正常数组原样取回', () {
    expect(parseJsonArray<String>('["l1","l2"]'), ['l1', 'l2']);
    expect(parseJsonArray<Map<String, Object?>>('[{"text":"看看","done":false}]'), [
      {'text': '看看', 'done': false},
    ]);
  });

  test('parseJsonArray：null 返回 null', () {
    expect(parseJsonArray<String>(null), isNull);
  });

  test('parseJsonArray：非 JSON 文本返回 null，不抛异常', () {
    expect(parseJsonArray<String>('{不是 JSON'), isNull);
    expect(parseJsonArray<String>(''), isNull);
  });

  test('parseJsonArray：是 JSON 但不是数组时返回 null', () {
    // 显式判掉 —— 坏值一律当「没有值」，别把类型错误漏到下游的 .map() 里才炸。
    // 与 listSettings 同口径。
    expect(parseJsonArray<String>('{"a":1}'), isNull);
    expect(parseJsonArray<String>('123'), isNull);
  });

  test('parseJsonArray：元素类型对不上返回 null（不把类型错误漏到下游）', () {
    expect(parseJsonArray<String>('[1,2]'), isNull);
  });
}
