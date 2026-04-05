import '../agent_state.dart';

/// 带状态追踪的消息记录
class TrackedMessage {
  final String messageId;
  final Map<String, dynamic> messageData;
  AgentMessageStatus status;
  final DateTime createdAt;

  TrackedMessage({
    required this.messageId,
    required this.messageData,
    this.status = AgentMessageStatus.none,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 消息内容（快捷访问）
  String get content => messageData['content'] as String? ?? '';

  @override
  String toString() {
    return 'TrackedMessage(id: $messageId, status: $status, content: ${content.substring(0, content.length.clamp(0, 20))}...)';
  }
}

/// 消息追踪器 - 维护所有用户消息的完整列表
class MessageTracker {
  final List<TrackedMessage> _messages = [];

  /// 追踪新消息
  void track(String messageId, Map<String, dynamic> messageData) {
    _messages.add(TrackedMessage(
      messageId: messageId,
      messageData: messageData,
      status: AgentMessageStatus.queued,
    ));
  }

  /// 更新消息状态
  void updateStatus(String messageId, AgentMessageStatus status) {
    final msg = _messages.where((m) => m.messageId == messageId).firstOrNull;
    if (msg != null) msg.status = status;
  }

  /// 获取当前处理中的消息
  TrackedMessage? getProcessingMessage() {
    return _messages.where((m) => m.status == AgentMessageStatus.processing).firstOrNull;
  }

  /// 获取所有排队中的消息
  List<TrackedMessage> getQueuedMessages() {
    return _messages.where((m) => m.status == AgentMessageStatus.queued).toList();
  }

  /// 获取全部消息（只读副本）
  List<TrackedMessage> get allMessages => List.unmodifiable(_messages);

  /// 清空追踪
  void clear() => _messages.clear();

  /// 释放资源
  void dispose() => _messages.clear();
}
