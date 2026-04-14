/// 会话摘要实体
///
/// 存储在 session_summary 表中，作为未读计数和最新消息的权威数据源。
/// 由 SessionSummaryStore 管理，DeviceNotificationManager 和 AgentNotificationHub 读取。
class SessionSummaryEntity {
  final String employeeId;
  final String deviceId;
  int unreadCount;

  String? lastMsgId;
  String? lastMsgRole;
  String? lastMsgContent;
  int? lastMsgTime;
  int? lastMsgSeq;

  int updateTime;

  SessionSummaryEntity({
    required this.employeeId,
    required this.deviceId,
    this.unreadCount = 0,
    this.lastMsgId,
    this.lastMsgRole,
    this.lastMsgContent,
    this.lastMsgTime,
    this.lastMsgSeq,
    required this.updateTime,
  });

  bool get hasLatestMessage =>
      lastMsgId != null && lastMsgId!.isNotEmpty;

  String get previewText {
    if (lastMsgContent == null) return '';
    return lastMsgContent!.length <= 100
        ? lastMsgContent!
        : '${lastMsgContent!.substring(0, 100)}...';
  }

  Map<String, dynamic> toMap() => {
    'employee_id': employeeId,
    'device_id': deviceId,
    'unread_count': unreadCount,
    'last_msg_id': lastMsgId,
    'last_msg_role': lastMsgRole,
    'last_msg_content': lastMsgContent,
    'last_msg_time': lastMsgTime,
    'last_msg_seq': lastMsgSeq,
    'update_time': updateTime,
  };

  factory SessionSummaryEntity.fromMap(Map<String, dynamic> map) {
    return SessionSummaryEntity(
      employeeId: map['employee_id'] as String,
      deviceId: map['device_id'] as String? ?? '',
      unreadCount: map['unread_count'] as int? ?? 0,
      lastMsgId: map['last_msg_id'] as String?,
      lastMsgRole: map['last_msg_role'] as String?,
      lastMsgContent: map['last_msg_content'] as String?,
      lastMsgTime: map['last_msg_time'] as int?,
      lastMsgSeq: map['last_msg_seq'] as int?,
      updateTime: map['update_time'] as int? ?? 0,
    );
  }
}
