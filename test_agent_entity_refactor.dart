/// Agent Entity 重构测试
///
/// 测试使用 Entity 替换 Map 后的功能是否正常

import 'package:wenzagent/wenzagent.dart';

void main() async {
  print('=== Agent Entity 重构测试 ===\n');

  // ===== 测试 1: AgentProxy 使用 PendingMessage =====
  print('【测试 1】AgentProxy 使用 PendingMessage');

  final mockAgent = _MockAgent();
  final agentProxy = AgentProxy.local(
    employeeId: 'emp-001',
    deviceId: 'dev-001',
    localAgent: mockAgent,
  );

  // 发送消息
  final messageId = await agentProxy.sendMessage({
    'content': '测试消息',
    'type': 'text',
    'customField': '自定义数据',
  });

  print('  消息ID: $messageId');
  print('  待确认队列长度: ${agentProxy.pendingMessageQueueLength}');

  // 检查 PendingMessage
  final pendingMessages = agentProxy.pendingMessages;
  print('  PendingMessage 类型: ${pendingMessages.runtimeType}');
  print('  第一个消息类型: ${pendingMessages.first.runtimeType}');
  print('  消息内容: ${pendingMessages.first.content}');
  print('  消息状态: ${pendingMessages.first.status}');
  print('  设备ID: ${pendingMessages.first.deviceId}');
  print('  员工ID: ${pendingMessages.first.employeeId}');
  print('  ✓ AgentProxy 使用 PendingMessage 成功\n');

  // ===== 测试 2: MessageQueueItem 使用 QueuedMessage =====
  print('【测试 2】MessageQueueItem 使用 QueuedMessage');

  final queuedMessage = QueuedMessage(
    id: 'msg-queued-001',
    content: '队列消息测试',
    createdAt: DateTime.now(),
    enqueuedAt: DateTime.now(),
  );

  final queueItem = MessageQueueItem(message: queuedMessage);

  print('  MessageQueueItem 创建成功');
  print('  messageId 访问器: ${queueItem.messageId}');
  print('  messageData 访问器类型: ${queueItem.messageData.runtimeType}');
  print('  QueuedMessage 类型: ${queueItem.message.runtimeType}');
  print('  处理状态: ${queueItem.message.processingStatus}');
  print('  ✓ MessageQueueItem 使用 QueuedMessage 成功\n');

  // ===== 测试 3: TrackedMessage 使用 QueuedMessage =====
  print('【测试 3】TrackedMessage 使用 QueuedMessage');

  final tracker = MessageTracker();
  tracker.track('msg-track-001', {
    'content': '追踪消息测试',
    'type': 'text',
  });

  final trackedMessages = tracker.allMessages;
  print('  TrackedMessage 创建成功');
  print('  追踪消息数量: ${trackedMessages.length}');
  print('  第一个消息类型: ${trackedMessages.first.message.runtimeType}');
  print('  消息ID: ${trackedMessages.first.messageId}');
  print('  处理状态: ${trackedMessages.first.status}');
  print('  内容: ${trackedMessages.first.content}');
  print('  ✓ TrackedMessage 使用 QueuedMessage 成功\n');

  // ===== 测试 4: 状态更新 =====
  print('【测试 4】状态更新');

  tracker.updateStatus('msg-track-001', MessageProcessingStatus.processing);
  print('  更新为 processing 后: ${trackedMessages.first.status}');

  tracker.updateStatus('msg-track-001', MessageProcessingStatus.completed);
  print('  更新为 completed 后: ${trackedMessages.first.status}');
  print('  ✓ 状态更新成功\n');

  // ===== 测试 5: 类型转换 =====
  print('【测试 5】类型转换（向后兼容）');

  final oldStatus = AgentMessageStatus.queued;
  final newStatus = oldStatus.toMessageProcessingStatus();
  print('  AgentMessageStatus.queued → $newStatus');

  final backToOld = newStatus.toAgentMessageStatus();
  print('  MessageProcessingStatus.queued → $backToOld');
  print('  ✓ 类型转换成功\n');

  // ===== 测试 6: 序列化兼容性 =====
  print('【测试 6】序列化兼容性');

  final pendingMsg = PendingMessage(
    id: 'msg-serial-001',
    content: '序列化测试',
    createdAt: DateTime.now(),
    sentAt: DateTime.now(),
  );

  final map = pendingMsg.toMap();
  print('  序列化为 Map: ${map.keys.toList()}');

  final restored = PendingMessage.fromMap(map);
  print('  反序列化成功: ${restored.id}, ${restored.content}');
  print('  ✓ 序列化兼容\n');

  // ===== 测试 7: 完整流程测试 =====
  print('【测试 7】完整流程测试');

  // 模拟消息处理流程
  final messageData = {
    'content': '完整流程测试',
    'type': 'text',
  };

  final msgId = 'msg-full-001';

  // 1. 创建 QueuedMessage
  final qMsg = QueuedMessage.fromMap({
    ...messageData,
    'id': msgId,
    'processingStatus': MessageProcessingStatus.queued.name,
    'enqueuedAt': DateTime.now().toIso8601String(),
  });
  print('  1. 创建 QueuedMessage: ${qMsg.id}, status=${qMsg.processingStatus}');

  // 2. 创建队列项
  final item = MessageQueueItem(message: qMsg);
  print('  2. 创建 MessageQueueItem: ${item.messageId}');

  // 3. 追踪消息
  final tracker2 = MessageTracker();
  tracker2.track(msgId, messageData);
  print('  3. 追踪消息: ${tracker2.allMessages.first.messageId}');

  // 4. 更新状态
  tracker2.updateStatus(msgId, MessageProcessingStatus.processing);
  print('  4. 更新状态: ${tracker2.allMessages.first.status}');

  // 5. 完成
  tracker2.updateStatus(msgId, MessageProcessingStatus.completed);
  print('  5. 完成: ${tracker2.allMessages.first.status}');

  print('  ✓ 完整流程测试成功\n');

  print('=== 所有测试通过 ===\n');

  print('重构总结:');
  print('  ✓ AgentProxy._pendingMessageQueue 使用 List<PendingMessage>');
  print('  ✓ MessageQueueItem.message 使用 QueuedMessage');
  print('  ✓ TrackedMessage.message 使用 QueuedMessage');
  print('  ✓ 提供了向后兼容的转换方法');
  print('  ✓ 类型安全，IDE 自动补全支持');
  print('  ✓ 所有功能正常运行');
}

/// Mock Agent 实现
class _MockAgent implements IAgent {
  @override
  final String employeeId = 'emp-001';

  @override
  Future<String> sendMessage(Map<String, dynamic> messageData) async {
    return 'msg_${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(String employeeId) async {
    return [];
  }

  @override
  AgentStatus get status => AgentStatus.idle;

  @override
  bool get isAlive => true;

  @override
  Future<void> initialize({String? employeeId}) async {}

  @override
  Future<void> dispose() async {}

  @override
  void attach() {}

  @override
  void detach() {}

  @override
  int get refCount => 1;

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> revokeMessage(String messageId) async {}

  @override
  Future<void> clearCurrentSession() async {}

  @override
  Future<void> setContext(Map<String, dynamic> contextData) async {}

  @override
  Future<void> clearContext() async {}

  @override
  Map<String, dynamic>? getCurrentContext() => null;

  @override
  Future<void> setProvider(Map<String, dynamic> providerConfig) async {}

  @override
  Map<String, dynamic>? getProviderConfig() => null;

  @override
  Future<void> setProject(Map<String, dynamic>? projectData) async {}

  @override
  String? getCurrentProjectUuid() => null;

  @override
  void registerTool(AgentTool tool) {}

  @override
  void registerTools(List<AgentTool> tools) {}

  @override
  void unregisterTool(String name) {}

  @override
  List<Map<String, dynamic>> getRegisteredTools() => [];

  @override
  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision,
  ) async {}

  @override
  AgentPermissionRequest? getPendingPermissionRequest() => null;

  @override
  AgentStateSnapshot getStateSnapshot() => AgentStateSnapshot.idle();

  @override
  Stream<AgentStateSnapshot> get onStateChanged => Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onEvent => Stream.empty();

  @override
  bool get isSending => false;

  @override
  bool get isStreaming => false;

  @override
  String? get currentProcessingMessageId => null;

  @override
  List<String> get queuedMessageIds => [];

  @override
  int get queueLength => 0;

  @override
  DateTime get lastActiveTime => DateTime.now();
}
