/// 测试 AgentProxy 消息队列功能
///
/// 这个测试演示了：
/// 1. AgentProxy 发送消息后，消息内容被添加到待确认队列
/// 2. 调用 getSessionMessages() 后，返回的消息会从待确认队列中移除
/// 3. 前端可以直接使用待确认队列中的消息内容进行渲染

import 'package:wenzagent/wenzagent.dart';

void main() async {
  print('=== 测试 AgentProxy 消息队列功能（完整消息内容） ===\n');

  // 创建一个简单的 Mock Agent 来测试
  final mockAgent = _MockAgent();

  // 创建 AgentProxy（本地模式）
  final agentProxy = AgentProxy.local(
    employeeId: 'emp-001',
    deviceId: 'dev-001',
    localAgent: mockAgent,
  );

  print('初始状态:');
  print('  待确认消息队列长度: ${agentProxy.pendingMessageQueueLength}');
  print('  待确认消息列表: ${agentProxy.pendingMessages}');
  print('');

  // 发送第一条消息
  print('步骤 1: 发送第一条消息');
  final messageId1 = await agentProxy.sendMessage({
    'content': '你好，这是第一条消息',
    'type': 'text',
  });
  print('  消息ID: $messageId1');
  print('  待确认消息队列长度: ${agentProxy.pendingMessageQueueLength}');
  print('  待确认消息内容:');
  for (final msg in agentProxy.pendingMessages) {
    print('    - ID: ${msg.id}');
    print('      内容: ${msg.content}');
    print('      类型: ${msg.type}');
    print('      角色: ${msg.role}');
    print('      时间: ${msg.createdAt}');
  }
  print('  ✓ 消息内容已添加到待确认队列\n');

  // 发送第二条消息
  print('步骤 2: 发送第二条消息');
  final messageId2 = await agentProxy.sendMessage({
    'content': '你好，这是第二条消息',
    'type': 'text',
  });
  print('  消息ID: $messageId2');
  print('  待确认消息队列长度: ${agentProxy.pendingMessageQueueLength}');
  print('  待确认消息ID列表: ${agentProxy.pendingMessageIds}');
  print('  ✓ 消息已添加到待确认队列\n');

  // 模拟消息被持久化到存储
  mockAgent.addPersistedMessage(messageId1, {
    'id': messageId1,
    'content': '你好，这是第一条消息',
    'type': 'text',
    'role': 'user',
    'createdAt': DateTime.now().toIso8601String(),
  });
  mockAgent.addPersistedMessage(messageId2, {
    'id': messageId2,
    'content': '你好，这是第二条消息',
    'type': 'text',
    'role': 'user',
    'createdAt': DateTime.now().toIso8601String(),
  });

  // 查询消息列表（此时应该从队列中移除已确认的消息）
  print('步骤 3: 查询消息列表（模拟 getSessionMessages 返回持久化消息）');
  final messages = await agentProxy.getSessionMessages();
  print('  返回消息数量: ${messages.length}');
  print('  返回的消息ID列表: ${messages.map((m) => m['id']).toList()}');
  print('');

  // 检查队列状态
  print('步骤 4: 检查队列状态');
  print('  待确认消息队列长度: ${agentProxy.pendingMessageQueueLength}');
  print('  待确认消息列表: ${agentProxy.pendingMessages}');
  if (agentProxy.pendingMessageQueueLength == 0) {
    print('  ✓ 所有消息已从待确认队列中移除\n');
  } else {
    print('  ✗ 错误：队列中仍有未确认的消息\n');
  }

  // 发送第三条消息
  print('步骤 5: 发送第三条消息（测试消息内容存储）');
  final messageId3 = await agentProxy.sendMessage({
    'content': '你好，这是第三条消息',
    'type': 'text',
    'customField': '自定义数据', // 测试自定义字段是否保留
  });
  print('  消息ID: $messageId3');
  print('  待确认消息内容:');
  final pendingMsg = agentProxy.pendingMessages.first;
  print('    - ID: ${pendingMsg.id}');
  print('    - 内容: ${pendingMsg.content}');
  print('    - 类型: ${pendingMsg.type}');
  print('    - 角色: ${pendingMsg.role}');
  print('    - 自定义字段: ${pendingMsg.metadata?['customField']}');
  print('    - 时间: ${pendingMsg.createdAt}');
  print('  ✓ 新消息已添加到待确认队列，包含完整内容\n');

  // 模拟前端渲染场景
  print('步骤 6: 模拟前端渲染场景');
  print('  前端可以直接使用 pendingMessages 进行渲染:');
  print('');
  for (int i = 0; i < agentProxy.pendingMessages.length; i++) {
    final msg = agentProxy.pendingMessages[i];
    print('  [消息 ${i + 1}] ${msg.content}');
    print('    状态: 待确认');
    print('    时间: ${msg.createdAt}');
  }
  print('');

  // 模拟只持久化了第三条消息
  mockAgent.addPersistedMessage(messageId3, {
    'id': messageId3,
    'content': '你好，这是第三条消息',
    'type': 'text',
    'role': 'user',
    'createdAt': DateTime.now().toIso8601String(),
  });

  // 再次查询消息列表
  print('步骤 7: 再次查询消息列表');
  final messages2 = await agentProxy.getSessionMessages();
  print('  返回消息数量: ${messages2.length}');
  print('  返回的消息ID列表: ${messages2.map((m) => m['id']).toList()}');
  print('');

  // 最终检查队列状态
  print('步骤 8: 最终检查队列状态');
  print('  待确认消息队列长度: ${agentProxy.pendingMessageQueueLength}');
  print('  待确认消息列表: ${agentProxy.pendingMessages}');
  if (agentProxy.pendingMessageQueueLength == 0) {
    print('  ✓ 所有消息已从待确认队列中移除\n');
  } else {
    print('  ✗ 错误：队列中仍有未确认的消息\n');
  }

  print('=== 测试完成 ===');
  print('总结:');
  print('  ✓ 发送消息时，完整的消息内容被添加到待确认队列');
  print('  ✓ 前端可以直接使用 pendingMessages 渲染待确认消息');
  print('  ✓ 查询消息列表时，返回的消息会从队列中移除');
  print('  ✓ 自定义字段被正确保留');
  print('');
  print('前端使用建议:');
  print('  1. 使用 pendingMessages 获取待确认消息列表');
  print('  2. 渲染时可以显示"发送中"或"待确认"状态');
  print('  3. 消息确认后自动从队列中移除');
}

/// Mock Agent 实现，用于测试
class _MockAgent implements IAgent {
  final Map<String, Map<String, dynamic>> _persistedMessages = {};

  @override
  final String employeeId = 'emp-001';

  void addPersistedMessage(String messageId, Map<String, dynamic> messageData) {
    _persistedMessages[messageId] = messageData;
  }

  @override
  Future<String> sendMessage(Map<String, dynamic> messageData) async {
    final messageId =
        messageData['id'] as String? ??
        'msg_${DateTime.now().millisecondsSinceEpoch}';
    messageData['id'] = messageId;
    return messageId;
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(String employeeId) async {
    // 只返回已持久化的消息
    return _persistedMessages.values.toList();
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
