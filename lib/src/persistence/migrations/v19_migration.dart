import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 19: skills 表索引重建 — 移除 device_id 查询隔离
///
/// Skill 绑定员工（employeeId），不绑定设备（deviceId）。
/// - 删除旧的联合索引 idx_skills_employee（如果存在）
/// - 创建新的单列索引 idx_skills_employee（只按 employee_id）
/// - device_id 列保留作为元数据，不再用于查询过滤
class V19Migration extends Migration {
  @override
  int get version => 19;

  @override
  void onUpgrade(Database db) {
    // 1. 删除可能存在的旧索引（联合索引或单列索引同名）
    _dropIndexIfExists(db, 'idx_skills_employee');

    // 2. 创建新的单列索引（只按 employee_id）
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_skills_employee
        ON skills(employee_id);
    ''');

    // 3. device_id 列保留，不删除，仅作为元数据
  }

  /// 安全删除索引（如果存在）
  void _dropIndexIfExists(Database db, String indexName) {
    try {
   final result = db.select(
        "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
        [indexName],
      );
      if (result.isNotEmpty) {
        db.execute('DROP INDEX $indexName');
      }
    } catch (_) {
      // 忽略错误，索引可能不存在
    }
  }
}