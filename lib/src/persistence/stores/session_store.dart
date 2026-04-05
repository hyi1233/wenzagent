import '../hive_manager.dart';
import '../entities/session_entity.dart';

/// 会话数据存储
///
/// 使用employeeUuid作为主键：一个员工只有一个会话
class SessionStore {
  final HiveManager _hiveManager;

  SessionStore({HiveManager? hiveManager})
    : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 构建Session key（使用employeeUuid作为主键）
  String _buildKey(String employeeUuid) {
    return 'sess:$employeeUuid';
  }

  /// 获取Session（主键查找）
  Future<AiEmployeeSessionEntity?> find(String employeeUuid) async {
    final box = _hiveManager.sessionBox;
    final key = _buildKey(employeeUuid);
    return box.get(key);
  }

  /// 获取或创建Session
  /// 只需要employeeUuid
  Future<AiEmployeeSessionEntity> getOrCreate(String employeeUuid) async {
    var session = await find(employeeUuid);
    if (session != null) return session;

    final now = DateTime.now();
    session = AiEmployeeSessionEntity(
      employeeUuid: employeeUuid,
      createTime: now,
      updateTime: now,
    );

    await save(session);
    return session;
  }

  /// 保存Session
  Future<void> save(AiEmployeeSessionEntity session) async {
    final box = _hiveManager.sessionBox;
    final key = _buildKey(session.employeeUuid);
    await box.put(key, session);
  }

  /// 获取所有Session（会话列表）
  Future<List<AiEmployeeSessionEntity>> findAll({
    bool includeArchived = false,
    bool includeDeleted = false,
  }) async {
    final box = _hiveManager.sessionBox;
    var sessions = box.values.where((s) {
      if (!includeDeleted && s.deleted == 1) return false;
      if (!includeArchived && s.isArchived == 1) return false;
      return true;
    }).toList();

    // 按置顶和更新时间排序
    sessions.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return b.isPinned.compareTo(a.isPinned);
      }
      return b.updateTime.compareTo(a.updateTime);
    });

    return sessions;
  }

  /// 删除Session（软删除）
  Future<void> delete(String employeeUuid) async {
    final session = await find(employeeUuid);
    if (session != null) {
      await save(session.copyWith(deleted: 1, updateTime: DateTime.now()));
    }
  }

  /// 硬删除Session
  Future<void> hardDelete(String employeeUuid) async {
    final box = _hiveManager.sessionBox;
    final key = _buildKey(employeeUuid);
    await box.delete(key);
  }

  /// 获取会话数量
  Future<int> count() async {
    final sessions = await findAll();
    return sessions.length;
  }

  // ===== 兼容旧API的方法（过渡期使用）=====

  /// 通过旧key格式查找会话（用于数据迁移）
  Future<AiEmployeeSessionEntity?> findByLegacyKey(
    String? spaceId,
    String uuid,
  ) async {
    final box = _hiveManager.sessionBox;
    final legacyKey = 'sess:$spaceId:$uuid';
    return box.get(legacyKey);
  }

  /// 删除旧格式的会话（用于数据迁移后清理）
  Future<void> deleteLegacyKey(String? spaceId, String uuid) async {
    final box = _hiveManager.sessionBox;
    final legacyKey = 'sess:$spaceId:$uuid';
    await box.delete(legacyKey);
  }
}
