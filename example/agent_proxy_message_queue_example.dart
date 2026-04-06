/// AgentProxy 消息队列完整示例
///
/// 展示如何在实际应用中使用消息队列功能进行前端渲染

import 'package:wenzagent/wenzagent.dart';

/// 示例：Flutter 风格的消息管理器
///
/// 这个类展示了如何在实际应用中管理消息状态，
/// 包括持久化消息和待确认消息的合并显示
class MessageManager {
  final AgentProxy agentProxy;

  /// 已持久化的消息列表
  List<Map<String, dynamic>> _persistedMessages = [];

  MessageManager({required this.agentProxy});

  /// 获取所有消息（持久化 + 待确认）
  List<Map<String, dynamic>> get allMessages {
    // 将 PendingMessage 转换为 Map
    final pendingMaps = agentProxy.pendingMessages
        .map((m) => m.toMap())
        .toList();
    return [..._persistedMessages, ...pendingMaps];
  }

  /// 获取消息数量
  int get messageCount => allMessages.length;

  /// 获取待确认消息数量
  int get pendingCount => agentProxy.pendingMessageQueueLength;

  /// 刷新持久化消息列表
  ///
  /// 调用此方法后，待确认队列会自动清理
  Future<void> refreshMessages() async {
    final agentMessages = await agentProxy.getSessionMessages();
    _persistedMessages = agentMessages.map((m) => m.toMap()).toList();
    print('已加载 ${_persistedMessages.length} 条持久化消息');
    print('待确认队列: ${agentProxy.pendingMessageQueueLength} 条');
  }

  /// 发送消息
  ///
  /// 消息发送后会立即出现在 pendingMessages 中，
  /// 前端可以立即渲染，无需等待持久化完成
  Future<String> sendMessage(MessageInput input) async {
    final messageId = await agentProxy.sendMessage(input);
    print('消息已发送: $messageId');
    print('待确认队列长度: $pendingCount');
    return messageId;
  }

  /// 打印消息列表（用于调试）
  void printMessages() {
    print('\n=== 消息列表 ===');
    for (int i = 0; i < allMessages.length; i++) {
      final msg = allMessages[i];
      final isPending = i >= _persistedMessages.length;
      print('${i + 1}. [${isPending ? '待确认' : '已发送'}] ${msg['content']}');
      if (isPending) {
        print('   ID: ${msg['id']}');
        print('   时间: ${msg['createdAt']}');
      }
    }
    print('================\n');
  }
}

/// 示例：消息渲染状态
enum MessageRenderStatus {
  pending, // 待确认（在 pendingMessages 中）
  sent, // 已发送（已持久化）
  failed, // 发送失败
}

/// 示例：带状态的消息包装类
class MessageWithStatus {
  final Map<String, dynamic> data;
  final MessageRenderStatus status;

  MessageWithStatus({required this.data, required this.status});

  String get content => data['content'] ?? '';

  String get id => data['id'] ?? '';

  DateTime? get createdAt {
    final str = data['createdAt'] as String?;
    return str != null ? DateTime.tryParse(str) : null;
  }

  bool get isPending => status == MessageRenderStatus.pending;
}

/// 完整使用示例
Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║          AgentProxy 消息队列 - 前端渲染示例              ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  // 创建 Mock Agent（实际应用中会使用真实的 Agent）
  final mockAgent = _MockAgent();

  // 创建 AgentProxy
  final agentProxy = AgentProxy.local(
    employeeId: 'emp-001',
    deviceId: 'dev-001',
    localAgent: mockAgent,
  );

  // 创建消息管理器
  final messageManager = MessageManager(agentProxy: agentProxy);

  // ===== 场景 1: 用户发送第一条消息 =====
  print('【场景 1】用户发送第一条消息');
  final msgId1 = await messageManager.sendMessage(
    MessageInput(content: '你好，这是第一条消息', type: 'text'),
  );

  messageManager.printMessages();
  // 输出:
  // 1. [待确认] 你好，这是第一条消息
  //    ID: msg_xxx
  //    时间: 2026-04-07T...

  // ===== 场景 2: 前端立即渲染，后台处理消息 =====
  print('【场景 2】前端可以立即渲染待确认消息');
  print('前端渲染:');
  for (final msg in messageManager.allMessages) {
    final isPending = messageManager.pendingCount > 0;
    print('  - ${msg['content']} ${isPending ? '[发送中...]' : '[已发送]'}');
  }
  print('');

  // ===== 场景 3: 消息处理完成，刷新消息列表 =====
  print('【场景 3】消息处理完成，刷新消息列表');

  // 模拟消息被持久化
  mockAgent.addPersistedMessage(msgId1, {
    'id': msgId1,
    'content': '你好，这是第一条消息',
    'type': 'text',
    'role': 'user',
    'createdAt': DateTime.now().toIso8601String(),
  });

  // 刷新消息列表
  await messageManager.refreshMessages();
  messageManager.printMessages();
  // 输出:
  // 1. [已发送] 你好，这是第一条消息

  // ===== 场景 4: 快速发送多条消息 =====
  print('【场景 4】快速发送多条消息');
  final msgIds = <String>[];
  for (int i = 1; i <= 3; i++) {
    final msgId = await messageManager.sendMessage(
      MessageInput(content: '快速消息 $i', type: 'text'),
    );
    msgIds.add(msgId);
  }

  print('发送了 ${msgIds.length} 条消息');
  messageManager.printMessages();
  // 输出:
  // 1. [已发送] 你好，这是第一条消息
  // 2. [待确认] 快速消息 1
  // 3. [待确认] 快速消息 2
  // 4. [待确认] 快速消息 3

  // ===== 场景 5: 模拟实际前端渲染逻辑 =====
  print('【场景 5】模拟 Flutter 前端渲染');
  final messagesWithStatus = <MessageWithStatus>[];

  // 添加持久化消息
  for (final msg in messageManager._persistedMessages) {
    messagesWithStatus.add(
      MessageWithStatus(data: msg, status: MessageRenderStatus.sent),
    );
  }

  // 添加待确认消息
  for (final msg in agentProxy.pendingMessages) {
    messagesWithStatus.add(
      MessageWithStatus(data: msg.toMap(), status: MessageRenderStatus.pending),
    );
  }

  // 渲染
  print('Flutter UI 渲染结果:\n');
  for (final msg in messagesWithStatus) {
    final statusIcon = msg.isPending ? '⏳' : '✅';
    final statusText = msg.isPending ? '发送中' : '已发送';
    print('$statusIcon ${msg.content}');
    print('   状态: $statusText');
    if (msg.isPending) {
      print('   提示: 消息正在发送，请稍候...');
    }
    print('');
  }

  // ===== 场景 6: 持久化完成，清理队列 =====
  print('【场景 6】所有消息持久化完成');

  // 模拟所有消息被持久化
  for (final msgId in msgIds) {
    mockAgent.addPersistedMessage(msgId, {
      'id': msgId,
      'content': '快速消息 ${msgIds.indexOf(msgId) + 1}',
      'type': 'text',
      'role': 'user',
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  // 刷新消息列表，队列自动清理
  await messageManager.refreshMessages();

  print('刷新后:');
  print('  持久化消息: ${messageManager._persistedMessages.length} 条');
  print('  待确认队列: ${messageManager.pendingCount} 条');
  messageManager.printMessages();

  print('\n╔══════════════════════════════════════════════════════════╗');
  print('║                      ✓ 示例完成                          ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  print('关键要点:');
  print('  1. 发送消息后立即可以在 pendingMessages 中看到');
  print('  2. 前端无需等待持久化即可渲染消息');
  print('  3. 提供更好的用户体验（显示"发送中"状态）');
  print('  4. 刷新消息列表后，队列自动清理');
  print('  5. 所有自定义字段都被保留');
}

/// Mock Agent 实现
class _MockAgent implements IAgent {
  final Map<String, Map<String, dynamic>> _persistedMessages = {};

  @override
  final String employeeId = 'emp-001';

  void addPersistedMessage(String messageId, Map<String, dynamic> messageData) {
    _persistedMessages[messageId] = messageData;
  }

  @override
  Future<String> sendMessage(MessageInput input) async {
    final messageId =
        input.id ?? 'msg_${DateTime.now().millisecondsSinceEpoch}';
    return messageId;
  }

  @override
  Future<String> sendMessageFromMap(Map<String, dynamic> messageData) {
    return sendMessage(MessageInput.fromMap(messageData));
  }

  @override
  Future<List<AgentMessage>> getSessionMessages() async {
    return _persistedMessages.values
        .map((m) => AgentMessage.fromMap(m))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessagesAsMap() async {
    final messages = await getSessionMessages();
    return messages.map((m) => m.toMap()).toList();
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

  @override
  ProviderConfig? getProviderConfig() {
    return null;
  }

  @override
  Future<void> setProject(ProjectData? projectData) async {}

  @override
  Future<void> setProvider(ProviderConfig providerConfig) async {}
}
