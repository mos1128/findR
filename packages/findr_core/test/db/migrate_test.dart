// 迁移测试 —— 逐条对应 TS 的 `packages/core/test/migrate.test.ts`。
//
// 这里**故意用冻结的 v1 DDL 手搓一个旧库**，而不是复用当前 schema —— 那才是真机上
// 用户手里那个库的样子。v2 是一次重建（建新表 → 拷贝 → 删旧表 → 改名），
// 一旦写错，用户打开 App 直接看到「数据库没能打开」，所以每个环节都得钉死：
//   - 列真的删掉了，而不是留着没数据；
//   - 该留的数据一列不漏（尤其是 path / steps / tags 这些 JSON 列）；
//   - cards_fts 重建过，检索不是静默返回空；
//   - 触发器跟着重建，之后新插入的行也能被搜到；
//   - PRAGMA foreign_keys 被恢复成 ON（v2 临时关过）。
//
// 与 TS 版的差别：那边用 repository 的 `insertCard` / `listCategories` 造数据与断言，
// 而 repository 还没译。这里改用等价的原始 SQL —— **等 repository 译完要把这几处换回来**，
// 否则「仓储写入的列名与迁移脚本对得上」这一层就没人押着了。

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// 造一个「用户手机里那个 v1 库」：v1 DDL + v1 预设分类 + 一些真实数据。
SqliteDriver makeV1Db() {
  final db = Sqlite3Driver.openInMemory();
  for (final statement in schemaV1Statements) {
    db.exec(statement);
  }
  db.exec(
    r'''INSERT INTO categories (id, name, emoji, description, structure_type, sort, is_preset) VALUES
    ('cat_item', '物品存取', '📍', '东西放在哪里的记录', 'item', 0, 1),
    ('cat_todo', '待买补货', '🛒', '要做什么、该买什么', 'todo', 1, 1)''',
  );
  db.exec(
    r'''INSERT INTO locations (id, parent_id, name, sort) VALUES
    ('l1', NULL, '主卧', 0), ('l2', 'l1', '衣柜', 1)''',
  );

  // c1：把「要删的列」全部填满，并带上所有 JSON 列 —— 迁移后这些废弃值应当整体消失，
  //     而该留的（path / tags / images / confidence / 时间戳）必须一列不漏。
  db.exec(
    r'''INSERT INTO cards (id, status, needs_confirm, needs_organize, structure_type, category_id,
       entity, path_ids, path_names, item_status, todo_status, procedure_status, steps,
       related_person, due_at, cycle, transcript, desc_text, images, audio_path, vision_analyzed,
       tags, confidence, ask, path_suggestion, path_matched, source, retry_count, next_retry_at,
       last_error, created_at, updated_at)
     VALUES ('c1','active',0,0,'item','cat_item',
       '备用手电筒','["l1","l2"]','主卧/衣柜','in_stock',NULL,NULL,NULL,
       '老王','2026-04-01','半年一次','备用手电筒放主卧衣柜顶层',
       '备用手电筒放在主卧衣柜顶层收纳盒里。','["files/cards/202609/c1/01.webp"]',NULL,1,
       '["应急","备用"]',0.86,NULL,NULL,1,'photo',0,NULL,
       NULL,'2026-09-01T00:00:00.000Z','2026-09-01T00:00:00.000Z')''',
  );

  // c2：故意带着 needs_confirm = 1 —— 该列已于第二十版退役（读写两侧都摘掉了），
  //     让它继续留在老库里，是为了押住「带这个标志的老行照样读得出来、不报错」。
  db.exec(
    r'''INSERT INTO cards (id, status, needs_confirm, needs_organize, structure_type, category_id, entity,
       path_ids, path_names, item_status, todo_status, procedure_status, steps, related_person,
       due_at, cycle, transcript, desc_text, images, audio_path, vision_analyzed, tags, confidence,
       ask, path_suggestion, path_matched, source, retry_count, next_retry_at, last_error,
       created_at, updated_at)
     VALUES ('c2','pending_transcript',1,0,'todo','cat_todo','买牙膏',NULL,NULL,NULL,'open',NULL,
       '[{"text":"看看家里还缺什么","done":false}]',NULL,NULL,NULL,'买牙膏','牙膏快用完了，需要补货。',
       NULL,'files/cards/202609/c2/audio.m4a',NULL,'["日用"]',NULL,'',NULL,NULL,'voice',2,NULL,NULL,
       '2026-09-02T00:00:00.000Z','2026-09-02T00:00:00.000Z')''',
  );
  db
      .prepare(
        "INSERT INTO aliases (id, kind, name, card_id) VALUES ('al1','entity','电筒','c1')",
      )
      .run();

  // v1 的 schema_meta 由 migrate() 自己建，这里补上以模拟「已经跑到 v1」的库
  db.exec('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  db.exec("INSERT INTO schema_meta (key, value) VALUES ('schema_version', '1')");
  return db;
}

void main() {
  test('v1 → v2：列真的没了，该留的数据一列不漏', () {
    final db = makeV1Db();
    addTearDown(db.close);
    expect(currentSchemaVersion(db), 1);

    migrate(db);

    expect(currentSchemaVersion(db), schemaVersion);

    final cols = columnsOf(db, 'cards');
    for (final gone in <String>[
      'structure_type',
      'item_status',
      'todo_status',
      'procedure_status',
      'related_person',
      'due_at',
      'cycle',
    ]) {
      expect(cols, isNot(contains(gone)), reason: 'cards 仍残留列 $gone');
    }
    expect(
      columnsOf(db, 'categories'),
      isNot(contains('structure_type')),
      reason: 'categories 仍残留 structure_type',
    );

    // 卡片本身：id / 分类 / 位置 / JSON 列 / 生命周期字段统统不能丢
    final c1 = db.prepare('SELECT * FROM cards WHERE id = ?').get(['c1'])!;
    expect(c1['entity'], '备用手电筒');
    expect(c1['category_id'], 'cat_item');
    expect(parseJsonArray<String>(c1['path_ids']), ['l1', 'l2']);
    expect(c1['path_names'], '主卧/衣柜');
    expect(parseJsonArray<String>(c1['tags']), ['应急', '备用']);
    expect(parseJsonArray<String>(c1['images']), [
      'files/cards/202609/c1/01.webp',
    ]);
    expect(c1['vision_analyzed'], 1);
    expect(c1['confidence'] as double, closeTo(0.86, 1e-9));
    expect(c1['created_at'], '2026-09-01T00:00:00.000Z');

    final c2 = db.prepare('SELECT * FROM cards WHERE id = ?').get(['c2'])!;
    expect(c2['status'], 'pending_transcript');
    expect(c2['retry_count'], 2);
    expect(c2['source'], 'voice');
    expect(c2['audio_path'], 'files/cards/202609/c2/audio.m4a');
    expect(parseJsonArray<Map<String, Object?>>(c2['steps']), [
      {'text': '看看家里还缺什么', 'done': false},
    ]);

    // 分类、位置、别名：一张表都不能少
    expect(
      db.prepare('SELECT name FROM categories ORDER BY sort').all().map(
        (r) => r['name'],
      ),
      ['物品存取', '待买补货'],
    );
    expect(
      db.prepare('SELECT name FROM locations ORDER BY sort').all().map(
        (r) => r['name'],
      ),
      ['主卧', '衣柜'],
    );
    expect(
      db.prepare('SELECT name FROM aliases WHERE id = ?').get(['al1']),
      {'name': '电筒'},
    );

    // v1 的预设分类已存在 ⇒ 不该因为 current!=0 就漏播种，也不该被重复插入
    expect(db.prepare('SELECT COUNT(*) AS n FROM categories').get()!['n'], 2);
  });

  test('v1 → v2：FTS 索引被重建，触发器与 PRAGMA 都回到正常状态', () {
    final db = makeV1Db();
    addTearDown(db.close);
    migrate(db);

    // 外键在 v2 里临时关过，必须被恢复
    expect(db.prepare('PRAGMA foreign_keys').get(), {'foreign_keys': 1});
    expect(db.prepare('PRAGMA foreign_key_check').all(), isEmpty);

    expect(
      (objectsOf(db, 'trigger')..sort()),
      ['cards_ad', 'cards_ai', 'cards_au'],
    );

    // 重建前的数据能被搜到（cards_fts 整表重扫过）
    expect(_ftsIds(db, '手电筒'), ['c1']);

    // 触发器确实接上了：新插入的行也进索引
    db.exec(
      r'''INSERT INTO cards (id, status, needs_confirm, needs_organize, category_id, entity,
         transcript, desc_text, tags, created_at, updated_at)
       VALUES ('c3','active',0,0,NULL,'护照','护照放书房抽屉','护照放在书房抽屉的文件袋里。',
         '["证件"]','2026-09-03T00:00:00.000Z','2026-09-03T00:00:00.000Z')''',
    );
    expect(_ftsIds(db, '书房抽屉'), ['c3']);
  });

  test('全新安装：一次跑到 v2，表结构直接是最终形态且预设分类已播种', () {
    final db = makeDb();
    addTearDown(db.close);

    expect(currentSchemaVersion(db), schemaVersion);
    expect(
      db.prepare('SELECT name FROM categories ORDER BY sort').all().map(
        (r) => r['name'],
      ),
      ['物品存取', '待买补货', '流程备忘'],
    );
    expect(db.prepare('SELECT * FROM locations').all(), isEmpty);
    // 新库不该有「先建 v1 再重建」留下的痕迹
    expect(
      db
          .prepare(
            "SELECT name FROM sqlite_master WHERE name IN ('cards_new','categories_new')",
          )
          .all(),
      isEmpty,
    );
    // 最终形态：v2 的 cards 就是当前 schema，废弃列一个都不该有
    expect(columnsOf(db, 'cards'), isNot(contains('structure_type')));
  });

  test('重复 migrate 是幂等的（每次开库都会跑一遍）', () {
    final db = makeV1Db();
    addTearDown(db.close);
    migrate(db);
    migrate(db);
    migrate(db);

    expect(currentSchemaVersion(db), schemaVersion);
    expect(db.prepare('SELECT COUNT(*) AS n FROM categories').get()!['n'], 2);
    expect(db.prepare('SELECT COUNT(*) AS n FROM cards').get()!['n'], 2);
  });
}

/// 用 FTS5 检索拿卡片 id（走外部内容表的 rowid 关联，与 search/builder.ts 同一写法）。
List<Object?> _ftsIds(SqliteDriver db, String query) => db
    .prepare(
      'SELECT c.id FROM cards_fts JOIN cards c ON c.rowid = cards_fts.rowid '
      'WHERE cards_fts MATCH ?',
    )
    .all([query])
    .map((r) => r['id'])
    .toList();
