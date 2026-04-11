/// Agent 事件实体
///
/// 统一封装 Agent 运行过程中产生的各类事件，
/// 用于事件流的类型安全传递。
///
/// 事件类型（[type]）包括：
/// - `agentStatusChanged`：Agent 状态变更
/// - `messageStatusChanged`：消息状态变更（queued/processing/streaming/completed/failed/interrupted/revoked）
/// - `messageReadStatusChanged`：消息已读状态变更
/// - `toolCallStart`：工具调用开始
/// - `toolCallResult`：工具调用结果
/// - `toolPermissionRequest`：工具权限请求
/// - `toolPermissionResponse`：工具权限响应
/// - `messageReplied`：消息被引用回复
/// - `messageQueued`：消息入队
/// - 其他由 ChatAdapter 工具回调产生的事件
class AgentEvent {
  /// 事件类型
  final String type;

  /// 事件携带的数据
  final Map<String, dynamic> data;

  /// 员工 UUID（事件所属的 Agent）
  final String? employeeId;

  /// 事件来源设备 ID（仅设备层转发时填充）
  final String? fromDeviceId;

  const AgentEvent({
    required this.type,
    required this.data,
    this.employeeId,
    this.fromDeviceId,
  });

  factory AgentEvent.fromMap(Map<String, dynamic> map) {
    return AgentEvent(
      type: map['type'] as String? ?? '',
      data: map['data'] as Map<String, dynamic>? ?? {},
      employeeId: map['employeeId'] as String?,
      fromDeviceId:
          map['fromDeviceId'] as String? ?? map['fromId'] as String?,
    );
  }

  /// 转为 Map（用于序列化 / LAN 传输）
  Map<String, dynamic> toMap() {
    return {
      'type': type,
      'data': data,
      if (employeeId != null) 'employeeId': employeeId,
      if (fromDeviceId != null) 'fromDeviceId': fromDeviceId,
    };
  }

  @override
  String toString() => 'AgentEvent(type: $type, employeeId: $employeeId)';
}
