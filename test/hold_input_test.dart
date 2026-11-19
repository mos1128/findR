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
          onHoldStart: onHoldStart,
          onHoldEnd: onHoldEnd,
          onCancelChanged: onCancelChanged,
          // 和真界面同形：字比药丸窄，两边都是不接手势的留白
          child: const Center(child: Text('按住 说话')),
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

  testWidgets('按下就报 onHoldStart：不等任何阈值', (tester) async {
    var starts = 0;
    await tester.pumpWidget(
      host(
        onHoldStart: () => starts++,
        onHoldEnd: () {},
        onCancelChanged: (_) {},
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldInput)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(starts, 1, reason: '说话的第一句不该被「按稳判定」吃掉');

    await gesture.up();
    await tester.pump();
  });

  testWidgets('按在字旁边的留白上也算按住', (tester) async {
    var starts = 0;
    await tester.pumpWidget(
      host(
        onHoldStart: () => starts++,
        onHoldEnd: () {},
        onCancelChanged: (_) {},
      ),
    );

    // 药丸比那行字宽得多，手指常常落在字的外面
    final rect = tester.getRect(find.byType(HoldInput));
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(6, 0),
    );
    await tester.pump();
    expect(starts, 1, reason: '留白不接手势，用户会以为「这颗按不动」');

    await gesture.up();
    await tester.pump();
  });
}
