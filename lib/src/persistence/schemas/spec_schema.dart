import 'package:sqlite3/sqlite3.dart';

/// spec_groups 表 schema
class SpecGroupSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS spec_groups (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        name         TEXT NOT NULL,
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_spec_groups_employee
        ON spec_groups(employee_id);
    ''');
  }
}

/// spec_items 表 schema
class SpecItemSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS spec_items (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        group_id     TEXT,
        title        TEXT NOT NULL,
        content      TEXT DEFAULT '',
        status       TEXT DEFAULT 'pending',
        priority     TEXT DEFAULT 'medium',
        tags         TEXT DEFAULT '',
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_spec_items_employee
        ON spec_items(employee_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_spec_items_group
        ON spec_items(group_id);
    ''');
  }
}
