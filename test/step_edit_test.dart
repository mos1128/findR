/// 步骤文字编辑的纯逻辑验收：空输入不写库、编辑保留完成状态、越界不崩。
library;

import 'package:findr_app/screens/card_detail_screen.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('添加步骤：空输入不写库，非空追加到末尾', () {
    const steps = <StepItem>[StepItem(text: '一', done: true)];

    expect(stepsWithEditedText(steps, null, '   '), isNull);

    final next = stepsWithEditedText(steps, null, ' 二 ');
    expect(next, isNotNull);
    expect(next!.map((s) => s.text).toList(), <String>['一', '二']);
    expect(next.last.done, isFalse);
  });

  test('编辑步骤：保留完成状态，越界返回 null', () {
    const steps = <StepItem>[StepItem(text: '一', done: true)];

    final next = stepsWithEditedText(steps, 0, '新的');
    expect(next, isNotNull);
    expect(next!.single.text, '新的');
    expect(next.single.done, isTrue);

    expect(stepsWithEditedText(steps, 3, '新的'), isNull);
  });
}
