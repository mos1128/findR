// schema v1 —— DDL 内容与《技术设计.md》第三节一致（PRAGMA 与连接参数由驱动层负责）。
//
// 以「一条 DDL = 一个数组元素」拆分而非整段多语句字符串：op-sqlite 的原生 execute 只执行
// 多语句字符串的第一条，逐条 exec 才能让 better-sqlite3 与 op-sqlite 行为一致。
// 注意 trigger 的 body 里含 `;`，因此绝不能靠分号切分字符串，必须手写字面量数组。

export const SCHEMA_STATEMENTS: readonly string[] = [
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

/** 仅供文档与调试查看的整段 DDL；执行一律走 SCHEMA_STATEMENTS 逐条 exec */
export const SCHEMA_SQL: string = SCHEMA_STATEMENTS.map((s) => s.trim() + ';').join('\n\n');

/** 预设分类，只在首次建库（schema_version 0 → 1）时写入，避免删掉的预设分类重启复活 */
export const SEED_STATEMENTS: readonly string[] = [
  `INSERT OR IGNORE INTO categories (id, name, emoji, description, structure_type, sort, is_preset) VALUES
  ('cat_item', '物品存取', '📍', '东西放在哪里的记录', 'item', 0, 1),
  ('cat_todo', '待买补货', '🛒', '要做什么、该买什么', 'todo', 1, 1),
  ('cat_procedure', '流程备忘', '📋', '怎么做的步骤与材料', 'procedure', 2, 1)`,
];
