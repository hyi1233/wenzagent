import 'package:sqlite3/sqlite3.dart';

/// session_summary 表 schema
///
/// 会话摘要表，作为未读计数和最新消息的权威数据源。
/// 通过 UPSERT 原子操作维护，O(1) 读写。
class SessionSummarySchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_summary (
        employee_id      TEXT    NOT NULL,
        device_id        TEXT    NOT NULL DEFAULT '',
        unread_count     INTEGER NOT NULL DEFAULT 0,
        last_msg_id      TEXT,
        last_msg_role    TEXT,
        last_msg_content TEXT,
        last_msg_time    INTEGER,
        last_msg_seq     INTEGER,
        update_time      INTEGER NOT NULL,
        PRIMARY KEY (employee_id, device_id)
      )
    ''');

    // 全局未读查询优化：只扫描有未读的行
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_unread
        ON session_summary(unread_count) WHERE unread_count > 0
    ''');

    // 会话列表排序优化：按最新消息时间倒序
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_last_msg_time
        ON session_summary(last_msg_time DESC)
    ''');
  }
}
