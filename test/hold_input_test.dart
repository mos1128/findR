/// 手势壳（`HoldInput`）的验收网：**上滑松手必须把取消态带到 `onHoldEnd` 里**。
///
/// 曾经这里松手前先补一个 `onCancelChanged(false)`，调用方在 `onHoldEnd` 里读到的
/// 就是「没取消」—— 录音照存、转写照跑，两边都不会报错，只有用户发现自己白划了。
library;

import 'package:findr_app/ui/hold_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host({
  required VoidCallback onHoldStart,
  required VoidCallback onHoldEnd,
  required ValueChanged<bool> onCancelChanged,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 280,
        height: 44,
        child: HoldInput(
          focused: false,
          onTap: () {},
          onHoldStart: onHoldStart,
          onHoldEnd: onHoldEnd,
          onCancelChanged: onCancelChanged,
          placeholder: const Text('长按说话'),
          child: const TextField(),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('上滑松手：onHoldEnd 里还看得见取消态', (tester) async {
    var armed = false;
    var ended = false;
    bool? seenAtEnd;

    await tester.pumpWidget(
      host(
        onHoldStart: () {},
        onHoldEnd: () {
          ended = true;
          seenAtEnd = armed;
        },
        onCancelChanged: (v) => armed = v,
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldInput)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(armed, isTrue, reason: '滑过 64px 就该进取消区');

    await gesture.up();
    await tester.pump();
    expect(ended, isTrue);
    expect(seenAtEnd, isTrue, reason: '松手时抹掉取消态，这段录音就会被当成正常结束');
  });

  testWidgets('原地松手：不算取消', (tester) async {
    var armed = false;
    bool? seenAtEnd;

    await tester.pumpWidget(
      host(
        onHoldStart: () {},
        onHoldEnd: () => seenAtEnd = armed,
        onCancelChanged: (v) => armed = v,
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldInput)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(seenAtEnd, isFalse, reason: '20px 离取消区还远，松手就是正常结束');
  });
}
