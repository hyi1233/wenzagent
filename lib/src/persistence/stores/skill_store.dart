import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/skill_entity.dart';

/// 技能数据存储
///
/// 使用 SQLite 实现。
/// Skill 绑定员工（employeeId），不绑定设备（deviceId）。
/// deviceId 仅作为元数据保留，不参与查询过滤。
class SkillStore {
  final DatabaseManager _dbManager;

  SkillStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  /// 从数据库行解码为实体
  AiEmployeeSkillEntity _rowToEntity(Row row) {
    return AiEmployeeSkillEntity.fromMap({
      'uuid': row['uuid'],
      'employeeId': row['employee_id'],
      'deviceId': row['device_id'] as String? ?? '',
      'name': row['name'],
      'description': row['description'],
      'skillType': row['skill_type'],
      'config': row['config'],
      'enabled': row['enabled'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'deleteTime': row['delete_time'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
    });
  }

  /// 获取员工的技能列表（只按 employeeId，不按 deviceId）
  Future<List<AiEmployeeSkillEntity>> findByEmployee(String employeeId) async {
    final resultSet = _db.select(
      'SELECT * FROM skills WHERE employee_id = ? AND deleted = 0 ORDER BY sort_order ASC',
      [employeeId],
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查找单个技能（只按 uuid，不按 deviceId）
  Future<AiEmployeeSkillEntity?> find(String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM skills WHERE uuid = ? AND deleted = 0',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 保存技能
  Future<void> save(AiEmployeeSkillEntity entity) async {
    _db.execute('''
      INSERT OR REPLACE INTO skills (
        uuid, employee_id, device_id, name, description, skill_type,
        config, enabled, sort_order, deleted, delete_time, create_time, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.employeeId,
      entity.deviceId,
      entity.name,
      entity.description,
      entity.skillType,
      entity.config,
      entity.enabled,
      entity.sortOrder,
      entity.deleted,
      entity.deleteTime?.millisecondsSinceEpoch,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 删除技能（软删除，只按 uuid）
  Future<void> delete(String uuid) async {
    _db.execute(
      'UPDATE skills SET deleted = 1, delete_time = ? WHERE uuid = ?',
      [DateTime.now().millisecondsSinceEpoch, uuid],
    );
  }

  /// 硬删除技能（只按 uuid）
  Future<void> hardDelete(String uuid) async {
    _db.execute('DELETE FROM skills WHERE uuid = ?', [uuid]);
  }

  /// 删除员工的所有技能（软删除，只按 employeeId）
  Future<void> deleteByEmployee(String employeeId) async {
    _db.execute(
      'UPDATE skills SET deleted = 1, delete_time = ? WHERE employee_id = ?',
      [DateTime.now().millisecondsSinceEpoch, employeeId],
    );
  }

  /// 获取技能数量（只按 employeeId）
  Future<int> count(String employeeId) async {
    final resultSet = _db.select(
      'SELECT COUNT(*) as cnt FROM skills WHERE employee_id = ? AND deleted = 0',
      [employeeId],
    );
    return resultSet.first['cnt'] as int;
  }

  /// 查找单个技能（包含已删除的，用于同步合并场景）
  Future<AiEmployeeSkillEntity?> findIncludingDeleted(String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM skills WHERE uuid = ?',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 获取所有技能（包含已删除的，用于同步拉取）
  Future<List<AiEmployeeSkillEntity>> findAll() async {
    final resultSet = _db.select(
      'SELECT * FROM skills ORDER BY sort_order ASC',
    );
    return resultSet.map(_rowToEntity).toList();
  }
}
