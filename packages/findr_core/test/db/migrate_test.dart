// 迁移测试。
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
// 旧数据按冻结的 v1 列名直接写入；迁移后用当前仓储读取，避免新增列反过来改变旧库样本。

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

  db.exec(r'''INSERT INTO cards (id, status, category_id, entity, path_ids, path_names, tags,
       transcript, desc_text, images, vision_analyzed, confidence, source, created_at, updated_at)
     VALUES ('c1', 'active', 'cat_item', '备用手电筒', '["l1","l2"]', '主卧/衣柜', '["应急","备用"]',
       '备用手电筒放主卧衣柜顶层', '备用手电筒放在主卧衣柜顶层收纳盒里。',
       '["files/cards/202609/c1/01.webp"]', 1, 0.86, 'photo',
       '2026-09-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z')''');

  // 【手写 SQL 之一】把「要删的列」全部填满：迁移后这些值应当整体消失，而不是被搬到别处。
  // 只能手写 —— 这些列已经从仓储的列清单里摘掉了，而这正是被测的事实本身。
  db
      .prepare(
        "UPDATE cards SET structure_type = 'item', item_status = 'in_stock', todo_status = NULL, "
        "procedure_status = NULL, related_person = '老王', due_at = '2026-04-01', "
        "cycle = '半年一次' WHERE id = 'c1'",
      )
      .run();

  // 【手写 SQL 之二】c2 要带 `needs_confirm = 1`，而这一列已从读写两侧退役。
  // 让一条老行继续带着这个标志，是为了押住「老库里带这个标志的行照样读得出来、不报错」。
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
      .prepare("INSERT INTO aliases (id, kind, name, card_id) VALUES ('al1','entity','电筒','c1')")
      .run();

  // v1 的 schema_meta 由 migrate() 自己建，这里补上以模拟「已经跑到 v1」的库
  db.exec('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  db.exec("INSERT INTO schema_meta (key, value) VALUES ('schema_version', '1')");
  return db;
}

void main() {
  test('v3 升级后保留旧卡片，图片分析选择留空供旧默认值兜底', () {
    final db = Sqlite3Driver.openInMemory();
    addTearDown(db.close);
    for (final statement in [...schemaV1Statements, ...v2Statements, ...v3Statements]) {
      db.exec(statement);
    }
    db.exec('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    db.exec("INSERT INTO schema_meta VALUES ('schema_version', '3')");
    db.exec(
      "INSERT INTO cards (id, status, transcript, created_at, updated_at) "
      "VALUES ('old', 'pending', '护照在抽屉里', '2026-11-01', '2026-11-01')",
    );

    migrate(db);
    migrate(db);

    expect(columnsOf(db, 'cards'), contains('vision_requested'));
    final row = db.prepare("SELECT * FROM cards WHERE id = 'old'").get()!;
    expect(row['vision_requested'], isNull);
    expect(row['transcript'], '护照在抽屉里');
    expect(_ftsIds(db, '护照在'), ['old']);
  });

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
    final c1 = getCard(db, 'c1')!;
    expect(c1.entity, '备用手电筒');
    expect(c1.categoryId, 'cat_item');
    expect(c1.pathIds, <String>['l1', 'l2']);
    expect(c1.pathNames, '主卧/衣柜');
    expect(c1.tags, <String>['应急', '备用']);
    expect(c1.images, <String>['files/cards/202609/c1/01.webp']);
    expect(c1.visionAnalyzed, isTrue);
    expect(c1.confidence, closeTo(0.86, 1e-9));
    expect(c1.createdAt, '2026-09-01T00:00:00.000Z');

    final c2 = getCard(db, 'c2')!;
    expect(c2.status, CardStatus.pendingTranscript);
    expect(c2.retryCount, 2);
    expect(c2.source, SourceKind.voice);
    expect(c2.audioPath, 'files/cards/202609/c2/audio.m4a');
    expect(c2.steps, <StepItem>[const StepItem(text: '看看家里还缺什么', done: false)]);

    // 分类、位置、别名：一张表都不能少
    expect(listCategories(db).map((c) => c.name), <String>['物品存取', '待买补货']);
    expect(listLocations(db).map((l) => l.name), <String>['主卧', '衣柜']);
    expect(db.prepare('SELECT name FROM aliases WHERE id = ?').get(<Object?>['al1']), <String, Object?>{
      'name': '电筒',
    });

    // v1 的预设分类已存在 ⇒ 不该因为 current != 0 就漏播种，也不该被重复插入
    expect(listCategories(db), hasLength(2));
  });

  test('v1 → v2：FTS 索引被重建，触发器与 PRAGMA 都回到正常状态', () {
    final db = makeV1Db();
    addTearDown(db.close);
    migrate(db);

    // 外键在 v2 里临时关过，必须被恢复
    expect(db.prepare('PRAGMA foreign_keys').get()?['foreign_keys'], 1);
    expect(db.prepare('PRAGMA foreign_key_check').all(), isEmpty);

    expect(objectsOf(db, 'trigger')..sort(), <String>['cards_ad', 'cards_ai', 'cards_au']);

    // 重建前的数据能被搜到（cards_fts 整表重扫过）
    expect(_ftsIds(db, '手电筒'), <Object?>['c1']);

    // 触发器确实接上了：**走仓储**新插入的行也进索引
    insertCard(
      db,
      makeCard(
        id: 'c3',
        entity: '护照',
        transcript: '护照放书房抽屉',
        desc: '护照放在书房抽屉的文件袋里。',
        tags: <String>['证件'],
      ),
    );
    expect(_ftsIds(db, '书房抽屉'), <Object?>['c3']);
  });

  test('v1 → v2：卡片引用的分类被删掉后，卡片不消失、只是变成无分类', () {
    final db = makeV1Db();
    addTearDown(db.close);
    migrate(db);
    // 重建后外键关系仍然是活的：deleteCategory 依赖它把引用置空
    expect(deleteCategory(db, 'cat_item', DateTime.parse('2026-09-18T00:00:00.000Z')), 1);
    expect(getCard(db, 'c1')!.entity, '备用手电筒');
    expect(getCard(db, 'c1')!.categoryId, isNull);
  });

  test('全新安装：一次跑到 v2，表结构直接是最终形态且预设分类已播种', () {
    final db = makeDb();
    addTearDown(db.close);

    expect(currentSchemaVersion(db), schemaVersion);
    expect(
      listCategories(db).map((c) => c.name),
      <String>['物品存取', '待买补货', '流程记录', '备忘事项'],
    );
    // 新库不该有「先建 v1 再重建」留下的痕迹
    expect(listLocations(db), isEmpty);
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

  test('v3：created_at 有索引、updated_at 索引已删、FTS 触发器限定文本列', () {
    final db = makeDb();
    addTearDown(db.close);

    expect(objectsOf(db, 'index'), contains('idx_cards_created'));
    expect(
      objectsOf(db, 'index'),
      isNot(contains('idx_cards_updated')),
      reason: '没有任何查询按 updated_at 排序，留着只是纯写成本',
    );

    final triggerSql = db
        .prepare(
          "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'cards_au'",
        )
        .get()!['sql']!
        .toString();
    expect(triggerSql, contains('UPDATE OF transcript, desc_text, entity, tags'));

    // 限定列的效果：改状态 / 改位置这类非文本更新不该重建 FTS 索引。
    // 查询词必须 ≥3 字 —— trigram 对两字词本来就匹配不到。
    insertCard(db, makeCard(id: 'c1', transcript: '护照在主卧抽屉'));
    expect(_ftsIds(db, '主卧抽'), <Object?>['c1']);
    setCardStatus(db, 'c1', CardStatus.archived, DateTime.now());
    expect(
      _ftsIds(db, '主卧抽'),
      <Object?>['c1'],
      reason: '改状态不该把 FTS 行删掉（触发器没限定列时会重建，旧实现能过、新实现也能）',
    );
  });

  test('重复 migrate 是幂等的（每次开库都会跑一遍）', () {
    final db = makeV1Db();
    addTearDown(db.close);
    migrate(db);
    migrate(db);
    migrate(db);

    expect(currentSchemaVersion(db), schemaVersion);
    expect(listCategories(db), hasLength(2));
    expect(db.prepare('SELECT COUNT(*) AS n FROM cards').get()?['n'], 2);
  });
}

/// 用 FTS5 检索拿卡片 id（走外部内容表的 rowid 关联，与 `search/builder.dart` 同一写法）。
List<Object?> _ftsIds(SqliteDriver db, String query) => db
    .prepare(
      'SELECT c.id FROM cards_fts JOIN cards c ON c.rowid = cards_fts.rowid '
      'WHERE cards_fts MATCH ?',
    )
    .all(<Object?>[query])
    .map((r) => r['id'])
    .toList();
