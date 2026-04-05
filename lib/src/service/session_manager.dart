import 'dart:async';

import '../persistence/persistence.dart';

/// 会话变更类型
enum SessionChangeType { created, updated, deleted, archived }

/// 会话变更事件
class SessionChangeEvent {
  final SessionChangeType type;
  final String employeeUuid;
  final AiEmployeeSessionEntity? session;

  SessionChangeEvent({
    required this.type,
    required this.employeeUuid,
    this.session,
  });
}

/// 会话管理器接口
abstract class SessionManager {
  /// 获取或创建Session（只需要employeeUuid）
  Future<AiEmployeeSessionEntity> getOrCreateSession(String employeeUuid);

  /// 获取Session（主键查找）
  Future<AiEmployeeSessionEntity?> getSession(String employeeUuid);

  /// 获取所有Session列表（用于显示会话列表）
  Future<List<AiEmployeeSessionEntity>> getAllSessions({
    bool includeArchived = false,
  });

  /// 更新设备配置（通过session.config[deviceId]访问）
  Future<void> updateDeviceConfig(
    String employeeUuid,
    String deviceId, {
    String? projectUuid,
    String? providerConfig,
    String? systemPromptOverride,
  });

  /// 更新设备统计
  Future<void> updateDeviceStats(
    String employeeUuid,
    String deviceId, {
    int? inputTokens,
    int? outputTokens,
    int? messageCount,
  });

  /// 保存Session
  Future<void> save(AiEmployeeSessionEntity session);

  /// 删除Session
  Future<void> deleteSession(String employeeUuid);

  /// 归档/取消归档会话
  Future<void> archiveSession(String employeeUuid, bool archived);

  /// Session变更通知
  Stream<SessionChangeEvent> get onSessionChanged;
}

/// 会话管理器实现
class SessionManagerImpl implements SessionManager {
  final SessionStore _sessionStore;
  final _changeController = StreamController<SessionChangeEvent>.broadcast();

  SessionManagerImpl({SessionStore? sessionStore})
    : _sessionStore = sessionStore ?? SessionStore();

  @override
  Future<AiEmployeeSessionEntity> getOrCreateSession(
    String employeeUuid,
  ) async {
    return _sessionStore.getOrCreate(employeeUuid);
  }

  @override
  Future<AiEmployeeSessionEntity?> getSession(String employeeUuid) async {
    return _sessionStore.find(employeeUuid);
  }

  @override
  Future<List<AiEmployeeSessionEntity>> getAllSessions({
    bool includeArchived = false,
  }) async {
    return _sessionStore.findAll(includeArchived: includeArchived);
  }

  @override
  Future<void> updateDeviceConfig(
    String employeeUuid,
    String deviceId, {
    String? projectUuid,
    String? providerConfig,
    String? systemPromptOverride,
  }) async {
    final session = await getOrCreateSession(employeeUuid);
    final deviceConfig = session.getOrCreateConfig(deviceId);

    final updatedConfig = deviceConfig.copyWith(
      projectUuid: projectUuid ?? deviceConfig.projectUuid,
      providerConfig: providerConfig ?? deviceConfig.providerConfig,
      systemPromptOverride:
          systemPromptOverride ?? deviceConfig.systemPromptOverride,
      updateTime: DateTime.now(),
    );

    session.config[deviceId] = updatedConfig;
    await save(session.copyWith(updateTime: DateTime.now()));
    _notifyChange(SessionChangeType.updated, session);
  }

  @override
  Future<void> updateDeviceStats(
    String employeeUuid,
    String deviceId, {
    int? inputTokens,
    int? outputTokens,
    int? messageCount,
  }) async {
    final session = await getOrCreateSession(employeeUuid);
    final deviceConfig = session.getOrCreateConfig(deviceId);

    final updatedConfig = deviceConfig.copyWith(
      totalInputTokens: inputTokens ?? deviceConfig.totalInputTokens,
      totalOutputTokens: outputTokens ?? deviceConfig.totalOutputTokens,
      totalMessageCount: messageCount ?? deviceConfig.totalMessageCount,
      updateTime: DateTime.now(),
    );

    session.config[deviceId] = updatedConfig;
    await save(session.copyWith(updateTime: DateTime.now()));
  }

  @override
  Future<void> save(AiEmployeeSessionEntity session) async {
    await _sessionStore.save(session);
  }

  @override
  Future<void> deleteSession(String employeeUuid) async {
    await _sessionStore.hardDelete(employeeUuid);
    _notifyChange(SessionChangeType.deleted, employeeUuid);
  }

  @override
  Future<void> archiveSession(String employeeUuid, bool archived) async {
    final session = await getSession(employeeUuid);
    if (session == null) return;

    final updated = session.copyWith(
      isArchived: archived ? 1 : 0,
      updateTime: DateTime.now(),
    );
    await save(updated);
    _notifyChange(SessionChangeType.archived, updated);
  }

  @override
  Stream<SessionChangeEvent> get onSessionChanged => _changeController.stream;

  void _notifyChange(SessionChangeType type, dynamic sessionOrEmployeeUuid) {
    if (sessionOrEmployeeUuid is AiEmployeeSessionEntity) {
      _changeController.add(
        SessionChangeEvent(
          type: type,
          employeeUuid: sessionOrEmployeeUuid.employeeUuid,
          session: sessionOrEmployeeUuid,
        ),
      );
    } else if (sessionOrEmployeeUuid is String) {
      _changeController.add(
        SessionChangeEvent(type: type, employeeUuid: sessionOrEmployeeUuid),
      );
    }
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
