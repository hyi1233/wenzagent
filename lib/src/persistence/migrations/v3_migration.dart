import 'package:sqlite3/sqlite3.dart';

import '../schemas/sync_watermark_schema.dart';
import 'migration.dart';

/// 版本 3: 添加消息递增序列号 (LSN) + 同步水位线表
///
/// - messages 表新增 seq INTEGER NOT NULL 列（用于增量同步）
/// - 为已有消息按 create_time 顺序分配 seq
/// - 创建 sync_watermark 表（客户端记录每个 employee 的已同步 seq）
class V3Migration extends Migration {
  @override
  int get version => 3;

  /// 检查表中是否存在指定列
  bool _columnExists(Database db, String table, String column) {
    final result = db.select('''
      SELECT count(*) as cnt FROM pragma_table_info('$table')
        WHERE name = '$column'
    ''');
    return (result.first['cnt'] as int) > 0;
  }

  /// 检查表是否存在
  bool _tableExists(Database db, String table) {
    final result = db.select(
      "SELECT count(*) as cnt FROM sqlite_master WHERE type='table' AND name='$table'",
    );
    return (result.first['cnt'] as int) > 0;
  }

  @override
  void onUpgrade(Database db) {
    // 1. messages 表添加 seq 列
    if (!_columnExists(db, 'messages', 'seq')) {
      // SQLite 不支持直接添加 NOT NULL 列（无默认值），
      // 使用表重建模式：创建新表 → 迁移数据 → 重命名
      db.execute('''
        CREATE TABLE messages_new (
          uuid              TEXT PRIMARY KEY,
          employee_id       TEXT NOT NULL,
          role              TEXT DEFAULT 'user',
          type              TEXT DEFAULT 'text',
          content           TEXT,
          tool_call_id      TEXT,
          tool_name         TEXT,
          tool_arguments    TEXT,
          tool_result       TEXT,
          tool_calls        TEXT,
          processing_status TEXT DEFAULT 'none',
          processing_error  TEXT,
          input_tokens      INTEGER,
          output_tokens     INTEGER,
          is_read           INTEGER DEFAULT 0,
          deleted           INTEGER DEFAULT 0,
          create_time       INTEGER NOT NULL,
          update_time       INTEGER NOT NULL,
          json_data         TEXT,
          seq               INTEGER NOT NULL
        )
      ''');

      // 迁移数据，用 ROW_NUMBER 按 create_time 分配 seq
      db.execute('''
        INSERT INTO messages_new (
          uuid, employee_id, role, type, content,
          tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
          processing_status, processing_error, input_tokens, output_tokens,
          is_read, deleted, create_time, update_time, json_data, seq
        )
        SELECT
          uuid, employee_id, role, type, content,
          tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
          processing_status, processing_error, input_tokens, output_tokens,
          is_read, deleted, create_time, update_time, json_data,
          ROW_NUMBER() OVER (ORDER BY create_time ASC, uuid ASC)
        FROM messages
      ''');

      db.execute('DROP TABLE messages');
      db.execute('ALTER TABLE messages_new RENAME TO messages');
    }

    // 重建索引（确保包含 seq 索引）
    db.execute('DROP INDEX IF EXISTS idx_messages_employee');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_employee
        ON messages(employee_id, create_time)
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_seq
        ON messages(seq)
    ''');

    // 2. 创建 sync_watermark 表
    if (!_tableExists(db, 'sync_watermark')) {
      SyncWatermarkSchema.create(db);
    }
  }
}
