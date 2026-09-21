// schema —— DDL 内容与《技术设计.md》第三节一致（PRAGMA 与连接参数由驱动层负责）。
//
// 以「一条 DDL = 一个数组元素」拆分而非整段多语句字符串：op-sqlite 的原生 execute 只执行
// 多语句字符串的第一条，逐条 exec 才能让 better-sqlite3 与 op-sqlite 行为一致。
// 注意 trigger 的 body 里含 `;`，因此绝不能靠分号切分字符串，必须手写字面量数组。
//
// ─────────────────────────────────────────────────────────────
// 迁移纪律（改这个文件之前请先读完）
// ─────────────────────────────────────────────────────────────
// 1. **每个版本的语句数组一旦发布就冻结**，只能追加新版本，绝不回头改旧的。
//    旧数组是「历史」：改它会让已经升过级的设备与新装设备长出不同的表。
// 2. 数组里的顺序就是执行顺序，且每个版本整体跑在一个事务里（见 migrate.ts）。
// 3. 删列不能靠 `ALTER TABLE ... DROP COLUMN`：SQLite 拒绝删除被 CHECK 约束引用的列，
//    而本项目几乎所有枚举列都带 CHECK。唯一可行做法是「建新表 → 拷贝 → 删旧表 → 改名」，
//    并且因为 cards.category_id 外键指向 categories，重建期间必须临时关掉外键
//    （`withoutForeignKeys`）。重建 cards 后还要 `INSERT INTO cards_fts(cards_fts) VALUES('rebuild')`
//    把全文索引接回来，否则检索会静默返回空。

/** v1：初版建库。**已冻结，勿改**（结构类型 / 业务状态 / 关联人 / 周期还在的这一版） */
export const SCHEMA_V1_STATEMENTS: readonly string[] = [
  `CREATE TABLE IF NOT EXISTS categories (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL UNIQUE,
  emoji          TEXT,
  description    TEXT,
  structure_type TEXT NOT NULL CHECK (structure_type IN ('item','todo','procedure')),
  sort           INTEGER NOT NULL DEFAULT 0,
  is_preset      INTEGER NOT NULL DEFAULT 0
)`,

  `CREATE TABLE IF NOT EXISTS locations (
  id        TEXT PRIMARY KEY,
  parent_id TEXT REFERENCES locations(id),
  name      TEXT NOT NULL,
  sort      INTEGER NOT NULL DEFAULT 0
)`,

  // 同一父节点下不允许重名（NULL 在 UNIQUE 里互不相等，故用表达式索引兜住根节点）
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_locations_parent_name
  ON locations(COALESCE(parent_id, ''), name)`,

  `CREATE TABLE IF NOT EXISTS aliases (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('entity','location')),
  name        TEXT NOT NULL,
  card_id     TEXT,
  location_id TEXT,
  UNIQUE (kind, name)
)`,

  `CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
)`,

  // structure_type 允许 NULL：P1 解析完成前的草稿态
  //
  // ask / path_suggestion / path_matched 承接 P1 输出中无法从其他列推导的信息：
  //   ask             —— 非空时记忆流展示补问入口（需求 5.1 轻量追问补偿），用户编辑后清空即「最多一次」
  //   path_suggestion —— 位置失配时模型的猜测，供用户点选或新建（需求四「匹配不到才让用户点选或新建」）
  //   path_matched    —— 本次 path 是否命中已有位置树，测试计划「path 命中率 ≥ 80%」的统计依据
  //
  // needs_confirm 是**已退役的残留列**（第二十版整条删掉「待确认」功能，见 pipeline/capture.ts）：
  // 保留不动是因为 SQLite 删列必须重建整张表（见本文件顶部第 3 条），而它
  // NOT NULL DEFAULT 0、读写两侧都已摘除，留在那里零成本；老备份包带着它也能正常导入。
  `CREATE TABLE IF NOT EXISTS cards (
  id               TEXT PRIMARY KEY,
  status           TEXT NOT NULL CHECK (status IN ('pending_transcript','pending','active','archived')),
  needs_confirm    INTEGER NOT NULL DEFAULT 0,
  needs_organize   INTEGER NOT NULL DEFAULT 0,
  structure_type   TEXT CHECK (structure_type IN ('item','todo','procedure') OR structure_type IS NULL),
  category_id      TEXT REFERENCES categories(id),
  entity           TEXT,
  path_ids         TEXT,
  path_names       TEXT,
  item_status      TEXT CHECK (item_status IN ('in_stock','lent','used','discarded')),
  todo_status      TEXT CHECK (todo_status IN ('open','done','dropped')),
  procedure_status TEXT CHECK (procedure_status IN ('draft','ready')),
  steps            TEXT,
  related_person   TEXT,
  due_at           TEXT,
  cycle            TEXT,
  transcript       TEXT,
  desc_text        TEXT,
  images           TEXT,
  audio_path       TEXT,
  vision_analyzed  INTEGER,
  tags             TEXT,
  confidence       REAL,
  ask              TEXT,
  path_suggestion  TEXT,
  path_matched     INTEGER,
  source           TEXT CHECK (source IN ('photo','voice','text')),
  retry_count      INTEGER NOT NULL DEFAULT 0,
  next_retry_at    TEXT,
  last_error       TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
)`,

  `CREATE INDEX IF NOT EXISTS idx_cards_status_retry ON cards(status, next_retry_at)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_category ON cards(category_id)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_path ON cards(path_names)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_updated ON cards(updated_at DESC)`,

  // 全文索引：外部内容表 + trigram（中文子串匹配）
  `CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(
  transcript, desc_text, entity, tags,
  content='cards', content_rowid='rowid',
  tokenize='trigram'
)`,

  `CREATE TRIGGER IF NOT EXISTS cards_ai AFTER INSERT ON cards BEGIN
  INSERT INTO cards_fts(rowid, transcript, desc_text, entity, tags)
  VALUES (new.rowid, COALESCE(new.transcript,''), COALESCE(new.desc_text,''), COALESCE(new.entity,''), COALESCE(new.tags,''));
END`,

  `CREATE TRIGGER IF NOT EXISTS cards_ad AFTER DELETE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, transcript, desc_text, entity, tags)
  VALUES ('delete', old.rowid, COALESCE(old.transcript,''), COALESCE(old.desc_text,''), COALESCE(old.entity,''), COALESCE(old.tags,''));
END`,

  `CREATE TRIGGER IF NOT EXISTS cards_au AFTER UPDATE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, transcript, desc_text, entity, tags)
  VALUES ('delete', old.rowid, COALESCE(old.transcript,''), COALESCE(old.desc_text,''), COALESCE(old.entity,''), COALESCE(old.tags,''));
  INSERT INTO cards_fts(rowid, transcript, desc_text, entity, tags)
  VALUES (new.rowid, COALESCE(new.transcript,''), COALESCE(new.desc_text,''), COALESCE(new.entity,''), COALESCE(new.tags,''));
END`,
];

/**
 * v2：移除「结构类型 / 业务状态 / 关联人与周期」。
 *
 * 为什么是重建而不是 DROP COLUMN：`structure_type` 被 CHECK 引用，SQLite 不允许删；
 * 而且我们要删的列横跨 cards 与 categories 两张表。
 *
 * 重建顺序：先 categories 后 cards。**必须先关外键**（migrate.ts 的 withoutForeignKeys）：
 * cards.category_id 指向 categories，开着外键 DROP TABLE 会触发隐式删除而被约束拒绝。
 *
 * 7 个被丢弃的列（无一处参与检索，真机验证后确认对产品只有噪音贡献）：
 *   cards: structure_type / item_status / todo_status / procedure_status / related_person / due_at / cycle
 *   categories: structure_type
 */
export const V2_STATEMENTS: readonly string[] = [
  // ── categories ──
  `CREATE TABLE categories_new (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  emoji       TEXT,
  description TEXT,
  sort        INTEGER NOT NULL DEFAULT 0,
  is_preset   INTEGER NOT NULL DEFAULT 0
)`,
  `INSERT INTO categories_new (id, name, emoji, description, sort, is_preset)
     SELECT id, name, emoji, description, sort, is_preset FROM categories`,
  `DROP TABLE categories`,
  `ALTER TABLE categories_new RENAME TO categories`,

  // ── cards ──
  `CREATE TABLE cards_new (
  id              TEXT PRIMARY KEY,
  status          TEXT NOT NULL CHECK (status IN ('pending_transcript','pending','active','archived')),
  needs_confirm   INTEGER NOT NULL DEFAULT 0,
  needs_organize  INTEGER NOT NULL DEFAULT 0,
  category_id     TEXT REFERENCES categories(id),
  entity          TEXT,
  path_ids        TEXT,
  path_names      TEXT,
  steps           TEXT,
  transcript      TEXT,
  desc_text       TEXT,
  images          TEXT,
  audio_path      TEXT,
  vision_analyzed INTEGER,
  tags            TEXT,
  confidence      REAL,
  ask             TEXT,
  path_suggestion TEXT,
  path_matched    INTEGER,
  source          TEXT CHECK (source IN ('photo','voice','text')),
  retry_count     INTEGER NOT NULL DEFAULT 0,
  next_retry_at   TEXT,
  last_error      TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
)`,
  `INSERT INTO cards_new (
     id, status, needs_confirm, needs_organize, category_id, entity, path_ids, path_names,
     steps, transcript, desc_text, images, audio_path, vision_analyzed, tags, confidence,
     ask, path_suggestion, path_matched, source, retry_count, next_retry_at, last_error,
     created_at, updated_at)
   SELECT
     id, status, needs_confirm, needs_organize, category_id, entity, path_ids, path_names,
     steps, transcript, desc_text, images, audio_path, vision_analyzed, tags, confidence,
     ask, path_suggestion, path_matched, source, retry_count, next_retry_at, last_error,
     created_at, updated_at
   FROM cards`,
  `DROP TABLE cards`,
  `ALTER TABLE cards_new RENAME TO cards`,

  // cards 被 DROP 时这些索引与触发器会一起消失，必须原样重建
  `CREATE INDEX IF NOT EXISTS idx_cards_status_retry ON cards(status, next_retry_at)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_category ON cards(category_id)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_path ON cards(path_names)`,
  `CREATE INDEX IF NOT EXISTS idx_cards_updated ON cards(updated_at DESC)`,

  `CREATE TRIGGER IF NOT EXISTS cards_ai AFTER INSERT ON cards BEGIN
  INSERT INTO cards_fts(rowid, transcript, desc_text, entity, tags)
  VALUES (new.rowid, COALESCE(new.transcript,''), COALESCE(new.desc_text,''), COALESCE(new.entity,''), COALESCE(new.tags,''));
END`,

  `CREATE TRIGGER IF NOT EXISTS cards_ad AFTER DELETE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, transcript, desc_text, entity, tags)
  VALUES ('delete', old.rowid, COALESCE(old.transcript,''), COALESCE(old.desc_text,''), COALESCE(old.entity,''), COALESCE(old.tags,''));
END`,

  `CREATE TRIGGER IF NOT EXISTS cards_au AFTER UPDATE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, transcript, desc_text, entity, tags)
  VALUES ('delete', old.rowid, COALESCE(old.transcript,''), COALESCE(old.desc_text,''), COALESCE(old.entity,''), COALESCE(old.tags,''));
  INSERT INTO cards_fts(rowid, transcript, desc_text, entity, tags)
  VALUES (new.rowid, COALESCE(new.transcript,''), COALESCE(new.desc_text,''), COALESCE(new.entity,''), COALESCE(new.tags,''));
END`,

  // cards_fts 是外部内容表（content='cards'），重建 cards 后索引与新 rowid 全部对不上，
  // 必须整表重扫。漏掉这一步的表现是「一条都搜不到」，而且不报错。
  `INSERT INTO cards_fts(cards_fts) VALUES('rebuild')`,
];

/**
 * 预设分类，只在首次建库时写入，避免删掉的预设分类重启复活。
 *
 * v2 起不再绑定结构类型 —— 三个预设仍与「东西 / 待办 / 流程」这三类日常记忆对应，
 * 但那只是名字与 Emoji 的暗示，不再有任何字段约束含义。用户可自由增删改。
 */
export const SEED_STATEMENTS: readonly string[] = [
  `INSERT OR IGNORE INTO categories (id, name, emoji, description, sort, is_preset) VALUES
  ('cat_item', '物品存取', '📍', '东西放在哪里的记录', 0, 1),
  ('cat_todo', '待买补货', '🛒', '要做什么、该买什么', 1, 1),
  ('cat_procedure', '流程备忘', '📋', '怎么做的步骤与材料', 2, 1)`,
];
