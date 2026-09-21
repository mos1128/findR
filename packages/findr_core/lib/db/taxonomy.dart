/// 分类与位置树的增删改 —— 逐字对应 `packages/core/src/db/taxonomy.ts`（174 行）。
///
/// 分类是「用户唯一的组织桶」，位置树是「东西放在哪」的层级结构。两者都是在设置里
/// 手工维护的对象，因此这里的删除动作都带拒绝理由 —— **静默删掉会让卡片的引用指向空洞**
/// （分类是 `cards.category_id` 外键，位置是 `cards.path_ids` 里的 JSON 数组）。
///
/// 改名后的配套动作是 `refreshPathNames`：卡片的权威位置是 `path_ids`，
/// `path_names` 只是冗余串，改名后必须跟上，否则「改名后就搜不到了」。
library;

import '../types.dart';
import '../util/iso.dart';
import 'driver.dart';
import 'json.dart';
import 'repository.dart';

// ─────────────────────────────────────────────────────────────
// 分类
// ─────────────────────────────────────────────────────────────

/// 按 id 新增或更新分类。`name` 上有 UNIQUE 约束，重名会直接抛错 ——
/// **有意如此**：静默改名会让用户以为保存成功，而 P1 的路由是按名字匹配的。
void upsertCategory(SqliteDriver db, Category category) {
  db
      .prepare(
        'INSERT INTO categories (id, name, emoji, description, sort, is_preset) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET '
        '  name = excluded.name, '
        '  emoji = excluded.emoji, '
        '  description = excluded.description, '
        '  sort = excluded.sort',
      )
      .run(<Object?>[
        category.id,
        category.name,
        category.emoji,
        category.description,
        category.sort,
        category.isPreset ? 1 : 0,
      ]);
}

/// 删除分类：先把引用它的卡片置空，避免卡片指向不存在的分类。返回被置空的卡片数。
int deleteCategory(SqliteDriver db, String id, DateTime now) => db.transaction(() {
  final changes = db
      .prepare('UPDATE cards SET category_id = NULL, updated_at = ? WHERE category_id = ?')
      .run(<Object?>[isoUtc(now), id])
      .changes;
  db.prepare('DELETE FROM categories WHERE id = ?').run(<Object?>[id]);
  return changes;
});

/// 批量重排：按传入顺序写 `sort`。
void reorderCategories(SqliteDriver db, List<String> ids) {
  db.transaction(() {
    for (var index = 0; index < ids.length; index++) {
      db
          .prepare('UPDATE categories SET sort = ? WHERE id = ?')
          .run(<Object?>[index, ids[index]]);
    }
  });
}

// ─────────────────────────────────────────────────────────────
// 位置树
// ─────────────────────────────────────────────────────────────

/// 按 id 新增或更新位置节点（与 `repository.upsertLocation` 不同：那个是 INSERT OR IGNORE）。
void upsertLocationNode(SqliteDriver db, LocationNode node) {
  db
      .prepare(
        'INSERT INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, '
        'name = excluded.name, sort = excluded.sort',
      )
      .run(<Object?>[node.id, node.parentId, node.name, node.sort]);
}

void renameLocation(SqliteDriver db, String id, String name) {
  db.prepare('UPDATE locations SET name = ? WHERE id = ?').run(<Object?>[name, id]);
}

/// 某一父节点下的直接子节点（`parent_id IS ?`，根节点传 null）。
List<LocationNode> listLocationChildren(SqliteDriver db, String? parentId) => db
    .prepare('SELECT * FROM locations WHERE parent_id IS ? ORDER BY sort')
    .all(<Object?>[parentId])
    .map(
      (r) => LocationNode(
        id: r['id'].toString(),
        parentId: r['parent_id']?.toString(),
        name: r['name'].toString(),
        sort: (r['sort'] as num?)?.toInt() ?? 0,
      ),
    )
    .toList();

/// 位置删除被拒的原因。对应 TS 里联合类型的 `reason` 字面量。
enum DeleteLocationRejection {
  hasChildren('has_children'),
  referencedByCards('referenced_by_cards');

  const DeleteLocationRejection(this.wire);
  final String wire;
}

/// 删除位置的结果。对应 TS 的 `DeleteLocationResult`：
/// **成功不带原因，失败必带原因与计数**（界面直接拿它说人话）。
final class DeleteLocationResult {
  const DeleteLocationResult.ok() : ok = true, reason = null, count = 0;

  const DeleteLocationResult.rejected(DeleteLocationRejection this.reason, this.count) : ok = false;

  final bool ok;

  /// 成功时为 null。
  final DeleteLocationRejection? reason;
  final int count;
}

/// 删除位置节点。**有子节点或被任何卡片引用时拒绝** ——
/// M1 不做 reparent / 合并，静默删掉会让卡片的 `path_ids` 指向空洞。
DeleteLocationResult deleteLocation(SqliteDriver db, String id) {
  final children = db
      .prepare('SELECT COUNT(*) AS n FROM locations WHERE parent_id = ?')
      .get(<Object?>[id]);
  final childCount = (children?['n'] as num?)?.toInt() ?? 0;
  if (childCount > 0) {
    return DeleteLocationResult.rejected(DeleteLocationRejection.hasChildren, childCount);
  }
  // path_ids 存的是 JSON 数组文本，用 `%"id"%` 定位「数组里确实有这一项」，
  // 而不是 LIKE '%id%'（后者会把 loc_1 误判成命中 loc_11）
  final used = db
      .prepare('SELECT COUNT(*) AS n FROM cards WHERE path_ids LIKE ?')
      .get(<Object?>['%"$id"%']);
  final usedCount = (used?['n'] as num?)?.toInt() ?? 0;
  if (usedCount > 0) {
    return DeleteLocationResult.rejected(DeleteLocationRejection.referencedByCards, usedCount);
  }
  db.prepare('DELETE FROM locations WHERE id = ?').run(<Object?>[id]);
  return const DeleteLocationResult.ok();
}

/// 位置改名后重算卡片的 `path_names`（卡片的权威位置是 `path_ids`，这里只是冗余串）。
/// 返回实际改动的卡片数。
///
/// **节点已被删除的卡片跳过**，保留原值而不是写出空洞 —— 那类卡片本来就该在界面上
/// 被标成「位置已失效」由用户处理，替它写一个残缺的路径串只会把问题藏起来。
int refreshPathNames(SqliteDriver db, DateTime now) {
  final byId = <String, LocationNode>{for (final l in listLocations(db)) l.id: l};
  final rows = db
      .prepare('SELECT id, path_names, path_ids FROM cards WHERE path_ids IS NOT NULL')
      .all();

  var changed = 0;
  db.transaction(() {
    for (final row in rows) {
      final ids = parseJsonArray<String>(row['path_ids']);
      if (ids == null || ids.isEmpty) continue;
      final names = <String>[];
      var missing = false;
      for (final i in ids) {
        final node = byId[i];
        if (node == null) {
          missing = true;
          break;
        }
        names.add(node.name);
      }
      if (missing) continue;
      final namesStr = names.join('/');
      if (namesStr == row['path_names']) continue;
      db
          .prepare('UPDATE cards SET path_names = ?, updated_at = ? WHERE id = ?')
          .run(<Object?>[namesStr, isoUtc(now), row['id'].toString()]);
      changed++;
    }
  });
  return changed;
}

// ─────────────────────────────────────────────────────────────
// ASR 热词
// ─────────────────────────────────────────────────────────────

/// 位置树深度（根为 1）。
///
/// ⚠️ 与 TS 一样**不设环检测**：位置树的父子关系由 `ensurePath` 单向增长，
/// 正常路径下不可能成环。这里保持与规格同形，不引入 TS 没有的防护。
int _depthOf(Map<String, LocationNode> byId, LocationNode node) {
  var d = 1;
  LocationNode? cur = node;
  while (cur?.parentId != null) {
    cur = byId[cur!.parentId];
    d++;
  }
  return d;
}

/// 模式 2 专用 ASR 的热词：房间名（**只取一二级**）+ 高频实体名。
/// 需求 3.2 明确热词用来提升「房间名、常用物品名」的转写准确率。
///
/// 实体按「出现次数降序、最近创建降序」取前 [entityLimit] 个 ——
/// 顺序有意义（热词表传给模型时越靠前越重要），测试靠 `indexOf` 的先后关系钉住。
List<String> collectHotwords(SqliteDriver db, {int entityLimit = 20}) {
  final locations = listLocations(db);
  final byId = <String, LocationNode>{for (final l in locations) l.id: l};
  final words = <String>[];
  for (final l in locations) {
    if (_depthOf(byId, l) <= 2) words.add(l.name);
  }
  final rows = db
      .prepare(
        'SELECT entity FROM cards '
        "WHERE entity IS NOT NULL AND entity <> '' "
        'GROUP BY entity '
        'ORDER BY COUNT(*) DESC, MAX(created_at) DESC '
        'LIMIT ?',
      )
      .all(<Object?>[entityLimit]);
  for (final r in rows) {
    final entity = r['entity'].toString();
    if (!words.contains(entity)) words.add(entity);
  }
  return words;
}
