import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 8: 水位线表 + 技能表增加 device_id 数据隔离
///
/// - sync_watermark: 重建表，主键从 employee_id 改为 (employee_id, device_id) 联合主键
/// - skills: ALTER TABLE ADD COLUMN device_id
class V8Migration extends Migration {
  @override
  int get version => 8;

  @override
  void onUpgrade(Database db) {
    // --- sync_watermark: 重建表（SQLite 不支持 ALTER PRIMARY KEY）---
    _migrateSyncWatermark(db);

    // --- skills: 增加 device_id 列 ---
    _addDeviceIdToSkills(db);
  }

  void _migrateSyncWatermark(Database db) {
    // 幂等检查：如果新表已存在（含 device_id 列），跳过
    if (_columnExists(db, 'sync_watermark', 'device_id')) return;

    db.execute('ALTER TABLE sync_watermark RENAME TO sync_watermark_old');

    db.execute('''
      CREATE TABLE sync_watermark (
        employee_id  TEXT NOT NULL,
        device_id    TEXT NOT NULL DEFAULT '',
        last_seq     INTEGER NOT NULL DEFAULT 0,
        clear_seq    INTEGER DEFAULT NULL,
        update_time  INTEGER NOT NULL,
        PRIMARY KEY (employee_id, device_id)
      )
    ''');

    // 迁移旧数据，device_id 默认空字符串
    db.execute('''
      INSERT INTO sync_watermark (employee_id, device_id, last_seq, clear_seq, update_time)
        SELECT employee_id, '', last_seq, clear_seq, update_time
        FROM sync_watermark_old
    ''');

    db.execute('DROP TABLE sync_watermark_old');
  }

  void _addDeviceIdToSkills(Database db) {
    if (_columnExists(db, 'skills', 'device_id')) return;
    db.execute("ALTER TABLE skills ADD COLUMN device_id TEXT NOT NULL DEFAULT ''");
  }

  /// 检查表中是否已存在指定列（幂等保护）
  bool _columnExists(Database db, String table, String column) {
    final result = db.select('PRAGMA table_info($table)');
    for (final row in result) {
      if (row['name'] == column) return true;
    }
    return false;
  }
}
