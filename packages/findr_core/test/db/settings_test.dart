// 「机密项不进 settings 表」是安全口径的一部分，而读坏值不能炸是它的容错面，
// 所以单独押一层。

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  test('set / get 往返：字符串、数字、布尔、对象、数组都能原样取回', () {
    final db = makeDb();
    addTearDown(db.close);

    setSetting(db, 'model', 'gpt-4o-mini');
    setSetting(db, 'timeoutSec', 30);
    setSetting(db, 'autoOrganize', true);
    setSetting(db, 'retry', {'max': 3, 'backoff': 'exp'});
    setSetting(db, 'providers', ['openai', 'anthropic']);

    expect(getSetting<String>(db, 'model'), 'gpt-4o-mini');
    expect(getSetting<int>(db, 'timeoutSec'), 30);
    expect(getSetting<bool>(db, 'autoOrganize'), isTrue);
    expect(getSetting<Map<String, Object?>>(db, 'retry'), {
      'max': 3,
      'backoff': 'exp',
    });
    expect(getSetting<List<Object?>>(db, 'providers'), ['openai', 'anthropic']);
  });

  test('未设置的 key 返回 null', () {
    final db = makeDb();
    addTearDown(db.close);

    expect(getSetting<String>(db, '从未设置过'), isNull);
    expect(listSettings(db), isEmpty);
  });

  test('重复 set 是覆盖（ON CONFLICT），不会留下两行', () {
    final db = makeDb();
    addTearDown(db.close);

    setSetting(db, 'model', 'a');
    setSetting(db, 'model', 'b');

    expect(getSetting<String>(db, 'model'), 'b');
    expect(
      db.prepare('SELECT COUNT(*) AS n FROM settings WHERE key = ?').get(['model'])!['n'],
      1,
    );
  });

  test('delete 之后读不到，也不影响别的 key', () {
    final db = makeDb();
    addTearDown(db.close);

    setSetting(db, 'a', 1);
    setSetting(db, 'b', 2);
    deleteSetting(db, 'a');
    deleteSetting(db, '不存在的');

    expect(getSetting<int>(db, 'a'), isNull);
    expect(getSetting<int>(db, 'b'), 2);
  });

  test('库里的坏 JSON 值：读它是 null，且不阻塞其余设置', () {
    final db = makeDb();
    addTearDown(db.close);

    setSetting(db, 'good', 'ok');
    db
        .prepare('INSERT INTO settings (key, value) VALUES (?, ?)')
        .run(['broken', '{不是 JSON']);

    expect(getSetting<String>(db, 'broken'), isNull);
    expect(listSettings(db), {'good': 'ok'});
  });

  test('类型不符时返回 null 而不是抛异常（T 传错不该炸界面）', () {
    final db = makeDb();
    addTearDown(db.close);

    setSetting(db, 'n', '这是字符串');
    expect(getSetting<int>(db, 'n'), isNull);
  });
}
