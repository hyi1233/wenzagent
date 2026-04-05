/// 设备会话配置
///
/// 存储某个设备上的Agent配置
class DeviceSessionConfig {
  /// 项目UUID
  String? projectUuid;

  /// AI模型配置 (JSON)
  /// 格式: {provider, model, apiKey, baseUrl, modelConfig}
  String? providerConfig;

  /// 系统提示词覆盖（可选）
  String? systemPromptOverride;

  /// 上下文数据 (JSON)
  String? contextData;

  /// 统计信息
  int totalInputTokens;
  int totalOutputTokens;
  int totalMessageCount;

  /// 更新时间
  DateTime updateTime;

  DeviceSessionConfig({
    this.projectUuid,
    this.providerConfig,
    this.systemPromptOverride,
    this.contextData,
    this.totalInputTokens = 0,
    this.totalOutputTokens = 0,
    this.totalMessageCount = 0,
    required this.updateTime,
  });

  /// 从Map创建
  factory DeviceSessionConfig.fromMap(Map<String, dynamic> map) {
    return DeviceSessionConfig(
      projectUuid: map['projectUuid'] as String?,
      providerConfig: map['providerConfig'] as String?,
      systemPromptOverride: map['systemPromptOverride'] as String?,
      contextData: map['contextData'] as String?,
      totalInputTokens: map['totalInputTokens'] as int? ?? 0,
      totalOutputTokens: map['totalOutputTokens'] as int? ?? 0,
      totalMessageCount: map['totalMessageCount'] as int? ?? 0,
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['updateTime'] as int? ?? 0),
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'projectUuid': projectUuid,
      'providerConfig': providerConfig,
      'systemPromptOverride': systemPromptOverride,
      'contextData': contextData,
      'totalInputTokens': totalInputTokens,
      'totalOutputTokens': totalOutputTokens,
      'totalMessageCount': totalMessageCount,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  DeviceSessionConfig copyWith({
    String? projectUuid,
    String? providerConfig,
    String? systemPromptOverride,
    String? contextData,
    int? totalInputTokens,
    int? totalOutputTokens,
    int? totalMessageCount,
    DateTime? updateTime,
  }) {
    return DeviceSessionConfig(
      projectUuid: projectUuid ?? this.projectUuid,
      providerConfig: providerConfig ?? this.providerConfig,
      systemPromptOverride: systemPromptOverride ?? this.systemPromptOverride,
      contextData: contextData ?? this.contextData,
      totalInputTokens: totalInputTokens ?? this.totalInputTokens,
      totalOutputTokens: totalOutputTokens ?? this.totalOutputTokens,
      totalMessageCount: totalMessageCount ?? this.totalMessageCount,
      updateTime: updateTime ?? this.updateTime,
    );
  }
}

/// AI员工Session实体
///
/// 主键：employeeId（一个员工只有一个会话）
/// 不存储deviceId（由Employee.currentDeviceId管理）
/// config存储各设备的配置：config[deviceId].projectUuid
class AiEmployeeSessionEntity {
  // ===== 主键 =====

  /// 员工UUID（主键）
  final String employeeUuid;

  // ===== 各设备的配置 =====

  /// 设备配置映射
  /// Key: deviceId
  /// Value: 该设备的配置（projectUuid, providerConfig等）
  ///
  /// 访问方式：
  /// - session.config[deviceId].projectUuid
  /// - session.config[deviceId].providerConfig
  Map<String, DeviceSessionConfig> config;

  // ===== 会话数据 =====

  /// 会话标题
  String title;

  // ===== 状态 =====

  int isArchived;
  int isPinned;
  int deleted;
  DateTime createTime;
  DateTime updateTime;

  // ===== 便捷访问器 =====

  /// 获取指定设备的配置
  DeviceSessionConfig? getConfig(String deviceId) => config[deviceId];

  /// 获取或创建设备配置
  DeviceSessionConfig getOrCreateConfig(String deviceId) {
    return config.putIfAbsent(
      deviceId,
      () => DeviceSessionConfig(updateTime: DateTime.now()),
    );
  }

  AiEmployeeSessionEntity({
    required this.employeeUuid,
    Map<String, DeviceSessionConfig>? config,
    this.title = '新对话',
    this.isArchived = 0,
    this.isPinned = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
  }) : config = config ?? {};

  /// 从Map创建
  factory AiEmployeeSessionEntity.fromMap(Map<String, dynamic> map) {
    // 解析config字段
    Map<String, DeviceSessionConfig> config = {};
    if (map['config'] != null) {
      final configMap = map['config'] as Map<String, dynamic>;
      config = configMap.map((key, value) {
        return MapEntry(
          key,
          DeviceSessionConfig.fromMap(value as Map<String, dynamic>),
        );
      });
    }

    return AiEmployeeSessionEntity(
      employeeUuid: map['employeeUuid'] as String,
      config: config,
      title: map['title'] as String? ?? '新对话',
      isArchived: map['isArchived'] as int? ?? 0,
      isPinned: map['isPinned'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
      createTime: map['createTime'] is DateTime
          ? map['createTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['createTime'] as int? ?? 0),
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['updateTime'] as int? ?? 0),
    );
  }

  /// 从旧格式Map创建（向后兼容）
  factory AiEmployeeSessionEntity.fromLegacyMap(Map<String, dynamic> map) {
    // 旧格式：uuid, employeeUuid, providerConfig, projectUuid等在顶层
    final employeeUuid =
        map['employeeUuid'] as String? ?? map['uuid'] as String;

    // 创建默认设备配置（从旧字段迁移）
    Map<String, DeviceSessionConfig> config = {};
    if (map['providerConfig'] != null || map['projectUuid'] != null) {
      // 使用空字符串作为默认设备ID，后续需要用户指定
      config[''] = DeviceSessionConfig(
        projectUuid: map['projectUuid'] as String?,
        providerConfig: map['providerConfig'] as String?,
        contextData: map['contextData'] as String?,
        totalInputTokens: map['inputTokens'] as int? ?? 0,
        totalOutputTokens: map['outputTokens'] as int? ?? 0,
        totalMessageCount: map['messageCount'] as int? ?? 0,
        updateTime: map['updateTime'] is DateTime
            ? map['updateTime'] as DateTime
            : DateTime.fromMillisecondsSinceEpoch(
                map['updateTime'] as int? ?? 0,
              ),
      );
    }

    return AiEmployeeSessionEntity(
      employeeUuid: employeeUuid,
      config: config,
      title: map['title'] as String? ?? '新对话',
      isArchived: map['isArchived'] as int? ?? 0,
      isPinned: map['isPinned'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
      createTime: map['createTime'] is DateTime
          ? map['createTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['createTime'] as int? ?? 0),
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['updateTime'] as int? ?? 0),
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    final configMap = config.map((key, value) => MapEntry(key, value.toMap()));

    return {
      'employeeUuid': employeeUuid,
      'config': configMap,
      'title': title,
      'isArchived': isArchived,
      'isPinned': isPinned,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  AiEmployeeSessionEntity copyWith({
    String? employeeUuid,
    Map<String, DeviceSessionConfig>? config,
    String? title,
    int? isArchived,
    int? isPinned,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeSessionEntity(
      employeeUuid: employeeUuid ?? this.employeeUuid,
      config: config ?? this.config,
      title: title ?? this.title,
      isArchived: isArchived ?? this.isArchived,
      isPinned: isPinned ?? this.isPinned,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  @override
  String toString() {
    return 'AiEmployeeSessionEntity(employeeUuid: $employeeUuid, title: $title, configDevices: ${config.keys.toList()})';
  }
}
