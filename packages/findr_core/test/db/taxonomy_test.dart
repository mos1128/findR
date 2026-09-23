import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// 分类与位置树的验收网。
/// （settings 相关用例见 `db/settings_test.dart`，此处不重复。）
void main() {
  test('预设分类只在首次建库播种，删掉后重启不复活', () {
    final db = makeDb();
    expect(listCategories(db), hasLength(3));

    deleteCategory(db, 'cat_item', testNow);
    expect(listCategories(db).map((c) => c.id), isNot(contains('cat_item')));

    // 模拟重启：同一个库再跑一次 migrate
    migrate(db);
    expect(listCategories(db).map((c) => c.id), isNot(contains('cat_item')));
  });

  test('删除分类会把引用它的卡片置空而不是留下悬空引用', () {
    final db = makeDb();
    insertCard(db, makeCard(id: 'c1', categoryId: 'cat_todo'));
    expect(deleteCategory(db, 'cat_todo', testNow), 1);
    expect(getCard(db, 'c1')!.categoryId, isNull);
  });

  test('分类重名会被 UNIQUE 约束挡住（P1 路由是按名字匹配的）', () {
    final db = makeDb();
    expect(
      () => upsertCategory(
        db,
        const Category(
          id: 'cat_custom',
          name: '物品存取',
          emoji: null,
          description: null,
          sort: 9,
          isPreset: false,
        ),
      ),
      throwsException,
    );
  });

  test('分类可新增、改名与重排', () {
    final db = makeDb();
    upsertCategory(
      db,
      const Category(
        id: 'cat_custom',
        name: '装修记录',
        emoji: '🔨',
        description: '装修期间临时堆放',
        sort: 3,
        isPreset: false,
      ),
    );
    expect(listCategories(db).map((c) => c.name), contains('装修记录'));

    upsertCategory(
      db,
      const Category(
        id: 'cat_custom',
        name: '装修',
        emoji: '🔨',
        description: null,
        sort: 3,
        isPreset: false,
      ),
    );
    final updated = listCategories(db).firstWhere((c) => c.id == 'cat_custom');
    expect(updated.name, '装修');
    expect(updated.description, isNull);

    reorderCategories(db, <String>['cat_custom', 'cat_item', 'cat_todo', 'cat_procedure']);
    expect(listCategories(db).map((c) => c.id), <String>[
      'cat_custom',
      'cat_item',
      'cat_todo',
      'cat_procedure',
    ]);
  });

  test('同一父节点下位置重名被唯一索引挡住（防路径分裂）', () {
    final db = makeDb();
    upsertLocation(db, const LocationNode(id: 'l1', parentId: null, name: '主卧', sort: 0));
    upsertLocation(db, const LocationNode(id: 'l2', parentId: null, name: '主卧室', sort: 1));
    // 不同名可以共存
    expect(listLocations(db), hasLength(2));
    // 重名（同父）被忽略
    upsertLocation(db, const LocationNode(id: 'l3', parentId: null, name: '主卧', sort: 2));
    expect(listLocations(db).map((l) => l.id), <String>['l1', 'l2']);
  });

  test('位置可改名、可挂到父节点下', () {
    final db = makeDb();
    upsertLocationNode(db, const LocationNode(id: 'l1', parentId: null, name: '主卧', sort: 0));
    upsertLocationNode(db, const LocationNode(id: 'l2', parentId: null, name: '衣柜', sort: 1));
    renameLocation(db, 'l2', '衣帽间');
    upsertLocationNode(db, const LocationNode(id: 'l2', parentId: 'l1', name: '衣帽间', sort: 0));

    final l2 = listLocations(db).firstWhere((l) => l.id == 'l2');
    expect(l2.name, '衣帽间');
    expect(l2.parentId, 'l1');
  });

  test('有子节点或被卡片引用的位置拒绝删除', () {
    final db = makeDb();
    upsertLocation(db, const LocationNode(id: 'l1', parentId: null, name: '主卧', sort: 0));
    upsertLocation(db, const LocationNode(id: 'l2', parentId: 'l1', name: '衣柜', sort: 0));
    insertCard(db, makeCard(id: 'c1', pathIds: <String>['l1', 'l2'], pathNames: '主卧/衣柜'));

    final withChildren = deleteLocation(db, 'l1');
    expect(withChildren.ok, isFalse);
    expect(withChildren.reason, DeleteLocationRejection.hasChildren);
    expect(withChildren.count, 1);

    final referenced = deleteLocation(db, 'l2');
    expect(referenced.ok, isFalse);
    expect(referenced.reason, DeleteLocationRejection.referencedByCards);
    expect(referenced.count, 1);

    // 未被引用且无子节点的可以删
    upsertLocation(db, const LocationNode(id: 'l3', parentId: null, name: '书房', sort: 2));
    expect(deleteLocation(db, 'l3').ok, isTrue);
  });

  test('位置改名后 refreshPathNames 让冗余串跟上（改名后检索仍命中）', () {
    final db = makeDb();
    upsertLocation(db, const LocationNode(id: 'l1', parentId: null, name: '主卧', sort: 0));
    upsertLocation(db, const LocationNode(id: 'l2', parentId: 'l1', name: '衣柜', sort: 0));
    insertCard(db, makeCard(id: 'c1', pathIds: <String>['l1', 'l2'], pathNames: '主卧/衣柜'));

    renameLocation(db, 'l2', '衣帽间');
    expect(refreshPathNames(db, testNow), 1);
    expect(getCard(db, 'c1')!.pathNames, '主卧/衣帽间');

    // 没有变化时不重复写
    expect(refreshPathNames(db, testNow), 0);
  });

  test('refreshPathNames 跳过节点已缺失的卡片，不写出空洞', () {
    final db = makeDb();
    upsertLocation(db, const LocationNode(id: 'l1', parentId: null, name: '主卧', sort: 0));
    insertCard(db, makeCard(id: 'c1', pathIds: <String>['l1', 'gone'], pathNames: '主卧/旧名'));
    expect(refreshPathNames(db, testNow), 0);
    expect(getCard(db, 'c1')!.pathNames, '主卧/旧名');
  });

  test('ASR 热词取一二级位置名 + 高频实体', () {
    final db = makeDb();
    upsertLocation(db, const LocationNode(id: 'l1', parentId: null, name: '主卧', sort: 0));
    upsertLocation(db, const LocationNode(id: 'l2', parentId: 'l1', name: '衣柜', sort: 0));
    upsertLocation(db, const LocationNode(id: 'l3', parentId: 'l2', name: '顶层', sort: 0));
    insertCard(db, makeCard(id: 'c1', entity: '手电筒'));
    insertCard(db, makeCard(id: 'c2', entity: '手电筒'));
    insertCard(db, makeCard(id: 'c3', entity: '猫砂'));

    final words = collectHotwords(db);
    expect(words, contains('主卧'));
    expect(words, contains('衣柜'));
    // 三级容器不进热词
    expect(words, isNot(contains('顶层')));
    expect(words.indexOf('手电筒'), lessThan(words.indexOf('猫砂')));
  });
}
