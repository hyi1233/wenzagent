import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 7: 消息表增加 device_id 列（仅作为元数据，不用于查询隔离）
///
/// 消息数据通过 updateTime/deleteTime 同步合并，与员工信息一致。
/// 注意：v1 schema 已经包含 device_id 列，此迁移处理从旧版本升级的场景。
class V7Migration extends Migration {
  @override
  int get version => 7;

  /// 检查表中是否存在指定列
  bool _columnExists(Database db, String table, String column) {
    final result = db.select('''
      SELECT count(*) as cnt FROM pragma_table_info('$table')
        WHERE name = '$column'
    ''');
    return (result.first['cnt'] as int) > 0;
  }

  @override
  void onUpgrade(Database db) {
    // messages 表增加 device_id 列（如果不存在）
    if (!_columnExists(db, 'messages', 'device_id')) {
      db.execute('ALTER TABLE messages ADD COLUMN device_id TEXT DEFAULT \'\'');
    }

    // 重建索引（加上 device_id 列便于按设备统计）
    db.execute('DROP INDEX IF EXISTS idx_messages_employee');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_employee
        ON messages(employee_id, create_time);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_device
        ON messages(employee_id, device_id, create_time);
    ''');
  }
}
