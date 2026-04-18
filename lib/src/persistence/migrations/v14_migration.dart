import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 14: session_summary 表增加 pending 字段
///
/// 新增列：
/// - pending_permission TEXT: 待处理的权限请求（JSON 序列化）
/// - pending_confirm TEXT: 待处理的确认请求（JSON 序列化）
/// - pending_permission_time INTEGER: 权限请求时间
/// - pending_confirm_time INTEGER: 确认请求时间
class V14Migration extends Migration {
  @override
  int get version => 14;

  @override
  void onUpgrade(Database db) {
    db.execute(
      'ALTER TABLE session_summary ADD COLUMN pending_permission TEXT',
    );
    db.execute(
      'ALTER TABLE session_summary ADD COLUMN pending_confirm TEXT',
    );
    db.execute(
      'ALTER TABLE session_summary ADD COLUMN pending_permission_time INTEGER',
    );
    db.execute(
      'ALTER TABLE session_summary ADD COLUMN pending_confirm_time INTEGER',
    );

    // 查询有 pending 请求的摘要优化索引
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_pending_permission
        ON session_summary(pending_permission) WHERE pending_permission IS NOT NULL
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_pending_confirm
        ON session_summary(pending_confirm) WHERE pending_confirm IS NOT NULL
    ''');
  }
}
