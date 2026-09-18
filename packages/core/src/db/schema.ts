// schema v1 —— 与《技术设计.md》第三节保持一致（PRAGMA 与连接参数由驱动层负责）
export const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS categories (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL UNIQUE,
  emoji          TEXT,
  description    TEXT,
  structure_type TEXT NOT NULL CHECK (structure_type IN ('item','todo','procedure')),
  sort           INTEGER NOT NULL DEFAULT 0,
  is_preset      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS locations (
  id        TEXT PRIMARY KEY,
  parent_id TEXT REFERENCES locations(id),
  name      TEXT NOT NULL,
  sort      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS aliases (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('entity','location')),
  name        TEXT NOT NULL,
  card_id     TEXT,
  location_id TEXT,
  UNIQUE (kind, name)
);

CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- structure_type 允许 NULL：P1 解析完成前的草稿态
CREATE TABLE IF NOT EXISTS cards (
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
  source           TEXT CHECK (source IN ('photo','voice','text')),
  retry_count      INTEGER NOT NULL DEFAULT 0,
  next_retry_at    TEXT,
  last_error       TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cards_status_retry ON cards(status, next_retry_at);
CREATE INDEX IF NOT EXISTS idx_cards_category ON cards(category_id);
CREATE INDEX IF NOT EXISTS idx_cards_path ON cards(path_names);
CREATE INDEX IF NOT EXISTS idx_cards_updated ON cards(updated_at DESC);

-- 全文索引：外部内容表 + trigram（中文子串匹配）
CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(
  transcript, desc_text, entity, tags,
  content='cards', content_rowid='rowid',
  tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS cards_ai AFTER INSERT ON cards BEGIN
  INSERT INTO cards_fts(rowid, transcript, desc_text, entity, tags)
  VALUES (new.rowid, COALESCE(new.transcript,''), COALESCE(new.desc_text,''), COALESCE(new.entity,''), COALESCE(new.tags,''));
END;

CREATE TRIGGER IF NOT EXISTS cards_ad AFTER DELETE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, transcript, desc_text, entity, tags)
  VALUES ('delete', old.rowid, COALESCE(old.transcript,''), COALESCE(old.desc_text,''), COALESCE(old.entity,''), COALESCE(old.tags,''));
END;

CREATE TRIGGER IF NOT EXISTS cards_au AFTER UPDATE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, transcript, desc_text, entity, tags)
  VALUES ('delete', old.rowid, COALESCE(old.transcript,''), COALESCE(old.desc_text,''), COALESCE(old.entity,''), COALESCE(old.tags,''));
  INSERT INTO cards_fts(rowid, transcript, desc_text, entity, tags)
  VALUES (new.rowid, COALESCE(new.transcript,''), COALESCE(new.desc_text,''), COALESCE(new.entity,''), COALESCE(new.tags,''));
END;
`;

export const SEED_SQL = `
INSERT OR IGNORE INTO categories (id, name, emoji, description, structure_type, sort, is_preset) VALUES
  ('cat_item', '物品存取', '📍', '东西放在哪里的记录', 'item', 0, 1),
  ('cat_todo', '待买补货', '🛒', '要做什么、该买什么', 'todo', 1, 1),
  ('cat_procedure', '流程备忘', '📋', '怎么做的步骤与材料', 'procedure', 2, 1);
`;
