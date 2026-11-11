/// 预设分类只在首次建库时播种一次。
///
/// 回归 `cat_memo` 被 `openRuntime` 反复插回来的 bug：那条补丁跑在每次启动、
/// 每次保存设置、每次增删分类/位置的路径上，导致用户删掉的预设分类立刻复活。
library;

import 'package:findr_app/platform/runtime.dart';
import 'package:findr_app/platform/secure.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('删掉的预设分类不会被 openRuntime 插回来', () async {
    final db = Sqlite3Driver.openInMemory();
    addTearDown(db.close);
    migrate(db);

    expect(
      listCategories(db).map((c) => c.id),
      containsAll(<String>[
        'cat_item',
        'cat_todo',
        'cat_procedure',
        'cat_memo',
      ]),
      reason: '首次建库应播种 4 个预设分类',
    );

    deleteCategory(db, 'cat_memo', DateTime.now());
    expect(listCategories(db).map((c) => c.id), isNot(contains('cat_memo')));

    // 启动、保存设置、改分类/位置都会走 openRuntime
    await openRuntime(db: db, keys: MemoryApiKeyStore());
    await openRuntime(db: db, keys: MemoryApiKeyStore());

    expect(
      listCategories(db).map((c) => c.id),
      isNot(contains('cat_memo')),
      reason: 'openRuntime 不该再执行播种逻辑',
    );
  });
}
