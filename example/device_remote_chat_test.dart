import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

/// 模拟的 ChatAdapter - 用于测试
class MockChatAdapter implements IChatAdapter {
  final String _employeeUuid;
  String? _currentSessionUuid;
  final List<Map<String, dynamic>> _messages = [];
  Map<String, dynamic>? _context;
  Map<String, dynamic>? _providerConfig;
  bool _isStreaming = false;

  // 模拟的会话存储（内存）
  static final Map<String, List<Map<String, dynamic>>> _sessionMessages = {};
  static final Map<String, Map<String, dynamic>> _sessionMeta = {};

  MockChatAdapter(this._employeeUuid);

  @override
  String? get currentSessionUuid => _currentSessionUuid;

  @override
  List<Map<String, dynamic>> get currentMessages => _messages;

  @override
  Map<String, dynamic>? get currentContext => _context;

  @override
  bool get isStreaming => _isStreaming;

  @override
  Future<void> initSession({
    required String employeeUuid,
    String? sessionUuid,
  }) async {
    if (sessionUuid != null) {
      _currentSessionUuid = sessionUuid;
    } else {
      // 创建新会话
      _currentSessionUuid = 'session-${DateTime.now().millisecondsSinceEpoch}';
      _sessionMeta[_currentSessionUuid!] = {
        'uuid': _currentSessionUuid,
        'employeeUuid': employeeUuid,
        'title': 'New Session',
        'createdAt': DateTime.now().toIso8601String(),
      };
      _sessionMessages[_currentSessionUuid!] = [];
    }

    // 加载会话消息
    _messages.clear();
    _messages.addAll(_sessionMessages[_currentSessionUuid!] ?? []);
  }

  @override
  Stream<StreamResponse> streamMessage(
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  }) async* {
    _isStreaming = true;

    // 添加用户消息
    final userMessage = {
      'id': messageData['id'] ?? 'msg-${DateTime.now().millisecondsSinceEpoch}',
      'role': 'user',
      'content': messageData['content'],
      'createdAt': DateTime.now().toIso8601String(),
    };
    _messages.add(userMessage);
    _sessionMessages[_currentSessionUuid!]?.add(userMessage);

    // 模拟 AI 响应
    final aiContent =
        '收到消息: "${messageData['content']}"。这是来自 Agent[$_employeeUuid] 的回复。';
    final aiMessageId = 'msg-ai-${DateTime.now().millisecondsSinceEpoch}';

    // 模拟流式输出
    final words = aiContent.split('');
    final buffer = StringBuffer();

    for (int i = 0; i < words.length; i++) {
      if (cancellationToken?.isCancelled == true) {
        yield StreamResponse(error: 'Cancelled');
        _isStreaming = false;
        return;
      }

      buffer.write(words[i]);
      await Future.delayed(const Duration(milliseconds: 20));

      yield StreamResponse(
        content: buffer.toString(),
        isDone: i == words.length - 1,
      );
    }

    // 添加 AI 消息到历史
    final aiMessage = {
      'id': aiMessageId,
      'role': 'assistant',
      'content': aiContent,
      'createdAt': DateTime.now().toIso8601String(),
    };
    _messages.add(aiMessage);
    _sessionMessages[_currentSessionUuid!]?.add(aiMessage);

    _isStreaming = false;
  }

  @override
  Future<void> stopStreaming() async {
    _isStreaming = false;
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionsByEmployee(
    String employeeUuid,
  ) async {
    return _sessionMeta.values
        .where((s) => s['employeeUuid'] == employeeUuid)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String sessionUuid,
  ) async {
    return _sessionMessages[sessionUuid] ?? [];
  }

  @override
  Future<String> createNewSession({
    required String employeeUuid,
    String? title,
  }) async {
    final sessionUuid = 'session-${DateTime.now().millisecondsSinceEpoch}';
    _sessionMeta[sessionUuid] = {
      'uuid': sessionUuid,
      'employeeUuid': employeeUuid,
      'title': title ?? 'New Session',
      'createdAt': DateTime.now().toIso8601String(),
    };
    _sessionMessages[sessionUuid] = [];
    return sessionUuid;
  }

  @override
  Future<void> switchSession(String sessionUuid) async {
    if (!_sessionMeta.containsKey(sessionUuid)) {
      throw Exception('Session not found: $sessionUuid');
    }
    _currentSessionUuid = sessionUuid;
    _messages.clear();
    _messages.addAll(_sessionMessages[sessionUuid] ?? []);
  }

  @override
  Future<void> clearCurrentSession() async {
    _messages.clear();
    if (_currentSessionUuid != null) {
      _sessionMessages[_currentSessionUuid!] = [];
    }
  }

  @override
  void setContext(Map<String, dynamic> contextData) {
    _context = {...?_context, ...contextData};
  }

  @override
  void clearContext() {
    _context = null;
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    _providerConfig = providerConfig;
  }

  @override
  Map<String, dynamic>? getProviderConfig() => _providerConfig;

  @override
  Future<void> updateProjectContext(
    Map<String, dynamic>? projectContext,
  ) async {
    if (projectContext != null) {
      _context = {...?_context, ...projectContext};
    }
  }

  @override
  void setToolRegistry(ToolRegistry? registry) {}

  @override
  void setPermissionManager(ToolPermissionManager? manager) {}

  @override
  void setToolEventCallback(
    void Function(Map<String, dynamic> event)? callback,
  ) {}

  @override
  Future<void> dispose() async {
    _isStreaming = false;
  }
}

/// 测试：两个设备的远程对话
Future<void> main() async {
  print('========================================');
  print('  DeviceClient 远程对话测试');
  print('========================================\n');

  // 1. 启动 Host
  print('【步骤1】启动 Host...');
  final host = LanHostServiceImpl();
  await host.start(port: 0); // 使用端口 0 让系统自动分配
  print('  ✓ Host 已启动: ${host.localIp}:${host.port}\n');

  try {
    // 2. 创建设备A
    print('【步骤2】创建设备A (device-alpha)...');
    final deviceA = DeviceClientImpl(
      deviceId: 'device-alpha',
      deviceName: 'Device Alpha',
      host: host.localIp!,
      port: host.port,
    );
    await deviceA.connect();
    print('  ✓ 设备A 已连接\n');

    // 3. 创建设备B
    print('【步骤3】创建设备B (device-beta)...');
    final deviceB = DeviceClientImpl(
      deviceId: 'device-beta',
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
    );
    await deviceB.connect();
    print('  ✓ 设备B 已连接\n');

    // 等待 clientInfo 消息被 Host 处理
    await Future.delayed(const Duration(milliseconds: 500));

    // 打印 Host 上的客户端信息
    print('  Host 客户端列表:');
    for (final c in host.clients) {
      print('    - id: ${c.id}, deviceId: ${c.deviceId}, name: ${c.name}');
    }
    print('');

    // 4. 在设备A上注册本地Agent
    print('【步骤4】在设备A上注册本地Agent (employee-alice)...');
    final agentA = AgentImpl(
      employeeUuid: 'employee-alice',
      chatAdapter: MockChatAdapter('employee-alice'),
    );
    await agentA.initialize();
    deviceA.registerLocalAgent('employee-alice', agentA);
    print('  ✓ Agent A 已注册\n');

    // 5. 在设备B上注册本地Agent
    print('【步骤5】在设备B上注册本地Agent (employee-bob)...');
    final agentB = AgentImpl(
      employeeUuid: 'employee-bob',
      chatAdapter: MockChatAdapter('employee-bob'),
    );
    await agentB.initialize();
    deviceB.registerLocalAgent('employee-bob', agentB);
    print('  ✓ Agent B 已注册\n');

    // 6. 设备B 远程访问设备A的Agent
    print('【步骤6】设备B 远程访问设备A的Agent...');
    final remoteProxyA = deviceB.getAgent(
      deviceId: 'device-alpha',
      employeeId: 'employee-alice',
    );
    print('  ✓ 远程代理已创建\n');

    // 7. 发送消息并验证响应
    print('【步骤7】设备B 向设备A的Agent发送消息...');

    // 监听 Host 消息流
    final hostSub = host.messageStream.listen((msg) {
      if (msg.type == LanMessageType.rpcRequest ||
          msg.type == LanMessageType.rpcResponse ||
          msg.type == LanMessageType.rpcError) {
        print(
          '  [Host] ${msg.type?.name ?? "unknown"}: from=${msg.fromId}, to=${msg.toDeviceId}',
        );
      }
    });

    try {
      final messageId = await remoteProxyA
          .sendMessage({'content': '你好，我是来自设备B的消息'})
          .timeout(const Duration(seconds: 10));
      print('  ✓ 消息已发送: $messageId\n');
    } catch (e) {
      print('  ✗ 发送消息失败: $e\n');
      // 继续测试，不直接退出
    } finally {
      await hostSub.cancel();
    }

    // 等待响应
    await Future.delayed(const Duration(seconds: 2));

    // 8. 获取远程Agent的会话消息
    print('【步骤8】获取远程Agent的会话消息...');
    final sessionUuid = agentA.currentSessionUuid;
    if (sessionUuid != null) {
      final messages = await remoteProxyA.getSessionMessages(sessionUuid);
      print('  会话消息数量: ${messages.length}');
      for (final msg in messages) {
        final role = msg['role'];
        final content = msg['content'];
        print(
          '  - [$role] ${content.length > 50 ? '${content.substring(0, 50)}...' : content}',
        );
      }
      print('');
    }

    // 9. 验证会话数据一致性
    print('【步骤9】验证会话数据一致性...');

    // 从本地Agent获取消息
    final localMessages = await agentA.getSessionMessages(sessionUuid!);

    // 从远程代理获取消息
    final remoteMessages = await remoteProxyA.getSessionMessages(sessionUuid);

    print('  本地消息数量: ${localMessages.length}');
    print('  远程消息数量: ${remoteMessages.length}');

    if (localMessages.length == remoteMessages.length) {
      print('  ✓ 消息数量一致');
    } else {
      print('  ✗ 消息数量不一致!');
    }

    // 验证消息内容
    bool contentMatch = true;
    for (int i = 0; i < localMessages.length; i++) {
      final localContent = localMessages[i]['content'];
      final remoteContent = remoteMessages[i]['content'];
      if (localContent != remoteContent) {
        contentMatch = false;
        print('  ✗ 消息 $i 内容不一致');
      }
    }
    if (contentMatch) {
      print('  ✓ 消息内容一致\n');
    }

    // 10. 设备A 远程访问设备B的Agent
    print('【步骤10】设备A 远程访问设备B的Agent...');
    final remoteProxyB = deviceA.getAgent(
      deviceId: 'device-beta',
      employeeId: 'employee-bob',
    );

    await remoteProxyB.sendMessage({'content': '你好，我是来自设备A的消息'});
    print('  ✓ 消息已发送\n');

    await Future.delayed(const Duration(seconds: 2));

    // 11. 验证双向通信
    print('【步骤11】验证双向通信...');
    final sessionB = agentB.currentSessionUuid;
    if (sessionB != null) {
      final messagesB = await agentB.getSessionMessages(sessionB);
      print('  设备B的Agent消息数量: ${messagesB.length}');
      for (final msg in messagesB) {
        final role = msg['role'];
        final content = msg['content'];
        print(
          '  - [$role] ${content.length > 50 ? '${content.substring(0, 50)}...' : content}',
        );
      }
    }
    print('');

    // 12. 清理
    print('【步骤12】清理资源...');
    await deviceA.dispose();
    await deviceB.dispose();
    print('  ✓ 资源已清理\n');

    print('========================================');
    print('  测试完成！');
    print('========================================');
  } finally {
    await host.stop();
    print('\nHost 已停止');
  }
}
