/// 浮层提示的界面测试：它长在屏幕顶部、不吃点击、到点自己走。
///
/// 钉住的是「别再挡住输入框」这件事 —— 输入框和键盘都在下方，
/// 提示只能在上面；同时只许有一条，连点两下不该叠两条。
library;

import 'package:findr_app/theme/tokens.dart';
import 'package:findr_app/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app() => MaterialApp(
  theme: buildFindrTheme(Brightness.dark),
  home: Scaffold(
    body: Builder(
      builder: (context) => Column(
        children: <Widget>[
          TextButton(
            onPressed: () => showFindrToast(context, '已保存'),
            child: const Text('成功'),
          ),
          TextButton(
            onPressed: () => showFindrToast(context, '保存失败', error: true),
            child: const Text('失败'),
          ),
          // 冒充底部的输入框：提示不该压在它身上
          const Expanded(
            child: Align(alignment: Alignment.bottomCenter, child: Text('输入框')),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('提示长在顶部，压在输入框之上的是它自己的坐标而不是底部', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('成功'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('已保存'), findsOneWidget);
    final toast = tester.getRect(find.text('已保存'));
    // 落在屏幕上部（顶部安全区之外也没关系，这里没有状态栏内边距）
    expect(toast.top, lessThan(80));
    // 离底部那颗「输入框」还差得远
    expect(toast.bottom, lessThan(tester.getRect(find.text('输入框')).top));
  });

  testWidgets('连点两下只留一条，到点自己消失', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('成功'));
    await tester.pump();
    await tester.tap(find.text('失败'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('已保存'), findsNothing);
    expect(find.text('保存失败'), findsOneWidget);

    // 失败那条 4s，到点连同 overlay 一起收走（不留悬空 timer）
    await tester.pump(const Duration(milliseconds: 4000));
    await tester.pump();
    expect(find.text('保存失败'), findsNothing);
  });
}
