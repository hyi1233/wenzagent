import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

/// 模拟的 ChatAdapter - 用于测试（带持久化模拟）
class MockChatAdapter implements IChatAdapter {
  final String _employeeUuid;
  String? _currentSessionUuid;
  final List<Map<String, dynamic>> _messages = [];
  Map<String, dynamic>? _context;
  Map<String, dynamic>? _providerConfig;
  bool _isStreaming = false;

  // 全局会话存储（模拟持久化，所有 Agent 共享）
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
      _currentSessionUuid =
          'session-${DateTime.now().millisecondsSinceEpoch}-${employeeUuid.substring(0, 8)}';
      _sessionMeta[_currentSessionUuid!] = {
        'uuid': _currentSessionUuid,
        'employeeUuid': employeeUuid,
        'title': 'Session for $employeeUuid',
        'createdAt': DateTime.now().toIso8601String(),
      };
      _sessionMessages[_currentSessionUuid!] = [];
    }

    _messages.clear();
    _messages.addAll(_sessionMessages[_currentSessionUuid!] ?? []);
  }

  @override
  Stream<StreamResponse> streamMessage(
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  }) async* {
    _isStreaming = true;

    final userMessage = {
      'id': messageData['id'] ?? 'msg-${DateTime.now().millisecondsSinceEpoch}',
      'role': 'user',
      'content': messageData['content'],
      'createdAt': DateTime.now().toIso8601String(),
      'fromEmployeeUuid': _employeeUuid,
    };
    _messages.add(userMessage);
    _sessionMessages[_currentSessionUuid!]?.add(userMessage);

    // 模拟 AI 响应
    final aiContent = 'Agent[$_employeeUuid] 回复: 收到"${messageData['content']}"';
    final aiMessageId = 'msg-ai-${DateTime.now().millisecondsSinceEpoch}';

    final words = aiContent.split('');
    final buffer = StringBuffer();

    for (int i = 0; i < words.length; i++) {
      if (cancellationToken?.isCancelled == true) {
        yield StreamResponse(error: 'Cancelled');
        _isStreaming = false;
        return;
      }
      buffer.write(words[i]);
      await Future.delayed(const Duration(milliseconds: 10));
      yield StreamResponse(
        content: buffer.toString(),
        isDone: i == words.length - 1,
      );
    }

    final aiMessage = {
      'id': aiMessageId,
      'role': 'assistant',
      'content': aiContent,
      'createdAt': DateTime.now().toIso8601String(),
      'fromEmployeeUuid': _employeeUuid,
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
    final sessionUuid =
        'session-${DateTime.now().millisecondsSinceEpoch}-${employeeUuid.substring(0, 8)}';
    _sessionMeta[sessionUuid] = {
      'uuid': sessionUuid,
      'employeeUuid': employeeUuid,
      'title': title ?? 'Session for $employeeUuid',
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

  /// 清理所有会话数据（测试用）
  static void clearAllSessions() {
    _sessionMessages.clear();
    _sessionMeta.clear();
  }
}

/// 会话状态快照
class SessionStateSnapshot {
  final String sessionUuid;
  final String ownerDeviceId;
  final String ownerEmployeeUuid;
  final List<Map<String, dynamic>> messages;

  SessionStateSnapshot({
    required this.sessionUuid,
    required this.ownerDeviceId,
    required this.ownerEmployeeUuid,
    required this.messages,
  });

  int get messageCount => messages.length;

  Map<String, dynamic> toMap() => {
    'sessionUuid': sessionUuid,
    'ownerDeviceId': ownerDeviceId,
    'ownerEmployeeUuid': ownerEmployeeUuid,
    'messageCount': messageCount,
    'messages': messages,
  };

  @override
  String toString() =>
      'SessionStateSnapshot(sessionUuid: $sessionUuid, messages: $messageCount)';
}

/// 测试：多设备会话状态一致性
Future<void> main() async {
  print('================================================');
  print('  多设备 Proxy 会话状态一致性测试');
  print('================================================\n');

  // 清理之前的测试数据
  MockChatAdapter.clearAllSessions();

  // 1. 启动 Host
  print('【步骤1】启动 Host...');
  final host = LanHostServiceImpl();
  await host.start(port: 0);
  print('  ✓ Host 已启动: ${host.localIp}:${host.port}\n');

  // 记录所有会话状态
  final Map<String, SessionStateSnapshot> sessionSnapshots = {};

  try {
    // 2. 创建三个设备
    print('【步骤2】创建三个设备...');

    final devices = <String, DeviceClientImpl>{};
    final agents = <String, AgentImpl>{};

    final deviceConfigs = [
      {
        'id': 'device-alpha',
        'name': 'Device Alpha',
        'employee': 'employee-alice',
      },
      {'id': 'device-beta', 'name': 'Device Beta', 'employee': 'employee-bob'},
      {
        'id': 'device-gamma',
        'name': 'Device Gamma',
        'employee': 'employee-carol',
      },
    ];

    for (final config in deviceConfigs) {
      final device = DeviceClientImpl(
        deviceId: config['id'] as String,
        deviceName: config['name'] as String,
        host: host.localIp!,
        port: host.port,
      );
      await device.connect();
      devices[config['id'] as String] = device;

      final agent = AgentImpl(
        employeeUuid: config['employee'] as String,
        chatAdapter: MockChatAdapter(config['employee'] as String),
      );
      await agent.initialize();
      device.registerLocalAgent(config['employee'] as String, agent);
      agents[config['employee'] as String] = agent;

      print('  ✓ ${config['name']} 已连接，Agent ${config['employee']} 已注册');
    }
    print('');

    // 等待连接稳定
    await Future.delayed(const Duration(milliseconds: 300));

    // 3. 场景一：设备A发送消息给设备B的Agent
    print('【步骤3】场景一：Device-Alpha -> Device-Beta Agent');
    final proxyAToB = devices['device-alpha']!.getAgent(
      deviceId: 'device-beta',
      employeeId: 'employee-bob',
    );

    await proxyAToB.sendMessage({'content': 'Hi Bob, this is Alice'});
    await Future.delayed(const Duration(milliseconds: 500));

    final sessionBob = agents['employee-bob']!.currentSessionUuid!;
    sessionSnapshots['session-bob'] = SessionStateSnapshot(
      sessionUuid: sessionBob,
      ownerDeviceId: 'device-beta',
      ownerEmployeeUuid: 'employee-bob',
      messages: await agents['employee-bob']!.getSessionMessages(sessionBob),
    );
    print(
      '  ✓ 消息已发送，Bob 会话消息数: ${sessionSnapshots['session-bob']!.messageCount}\n',
    );

    // 4. 场景二：设备B发送消息给设备C的Agent
    print('【步骤4】场景二：Device-Beta -> Device-Gamma Agent');
    final proxyBToC = devices['device-beta']!.getAgent(
      deviceId: 'device-gamma',
      employeeId: 'employee-carol',
    );

    await proxyBToC.sendMessage({'content': 'Hi Carol, this is Bob'});
    await Future.delayed(const Duration(milliseconds: 500));

    final sessionCarol = agents['employee-carol']!.currentSessionUuid!;
    sessionSnapshots['session-carol'] = SessionStateSnapshot(
      sessionUuid: sessionCarol,
      ownerDeviceId: 'device-gamma',
      ownerEmployeeUuid: 'employee-carol',
      messages: await agents['employee-carol']!.getSessionMessages(
        sessionCarol,
      ),
    );
    print(
      '  ✓ 消息已发送，Carol 会话消息数: ${sessionSnapshots['session-carol']!.messageCount}\n',
    );

    // 5. 场景三：设备C发送消息给设备A的Agent
    print('【步骤5】场景三：Device-Gamma -> Device-Alpha Agent');
    final proxyCToA = devices['device-gamma']!.getAgent(
      deviceId: 'device-alpha',
      employeeId: 'employee-alice',
    );

    await proxyCToA.sendMessage({'content': 'Hi Alice, this is Carol'});
    await Future.delayed(const Duration(milliseconds: 500));

    final sessionAlice = agents['employee-alice']!.currentSessionUuid!;
    sessionSnapshots['session-alice'] = SessionStateSnapshot(
      sessionUuid: sessionAlice,
      ownerDeviceId: 'device-alpha',
      ownerEmployeeUuid: 'employee-alice',
      messages: await agents['employee-alice']!.getSessionMessages(
        sessionAlice,
      ),
    );
    print(
      '  ✓ 消息已发送，Alice 会话消息数: ${sessionSnapshots['session-alice']!.messageCount}\n',
    );

    // 6. 场景四：设备A再发送消息给设备C的Agent（第二轮）
    print('【步骤6】场景四：Device-Alpha -> Device-Gamma Agent（第二轮）');
    await proxyAToC(devices).sendMessage({'content': 'Hello Carol again!'});
    await Future.delayed(const Duration(milliseconds: 500));

    // 更新 Carol 的会话快照
    sessionSnapshots['session-carol'] = SessionStateSnapshot(
      sessionUuid: sessionCarol,
      ownerDeviceId: 'device-gamma',
      ownerEmployeeUuid: 'employee-carol',
      messages: await agents['employee-carol']!.getSessionMessages(
        sessionCarol,
      ),
    );
    print(
      '  ✓ 消息已发送，Carol 会话消息数: ${sessionSnapshots['session-carol']!.messageCount}\n',
    );

    // 7. 场景五：设备B发送消息给设备A的Agent
    print('【步骤7】场景五：Device-Beta -> Device-Alpha Agent');
    final proxyBToA = devices['device-beta']!.getAgent(
      deviceId: 'device-alpha',
      employeeId: 'employee-alice',
    );

    await proxyBToA.sendMessage({'content': 'Hi Alice, this is Bob'});
    await Future.delayed(const Duration(milliseconds: 500));

    // 更新 Alice 的会话快照
    sessionSnapshots['session-alice'] = SessionStateSnapshot(
      sessionUuid: sessionAlice,
      ownerDeviceId: 'device-alpha',
      ownerEmployeeUuid: 'employee-alice',
      messages: await agents['employee-alice']!.getSessionMessages(
        sessionAlice,
      ),
    );
    print(
      '  ✓ 消息已发送，Alice 会话消息数: ${sessionSnapshots['session-alice']!.messageCount}\n',
    );

    // 8. 验证会话状态一致性
    print('【步骤8】验证会话状态一致性...\n');

    bool allConsistent = true;

    for (final entry in sessionSnapshots.entries) {
      final snapshot = entry.value;
      print('  会话: ${entry.key}');
      print(
        '    - 所有者: ${snapshot.ownerDeviceId} / ${snapshot.ownerEmployeeUuid}',
      );
      print('    - 消息数: ${snapshot.messageCount}');

      // 验证每条消息都有 id, role, content
      bool messagesValid = true;
      for (final msg in snapshot.messages) {
        if (msg['id'] == null ||
            msg['role'] == null ||
            msg['content'] == null) {
          messagesValid = false;
          break;
        }
      }

      if (messagesValid) {
        print('    ✓ 消息格式正确');
      } else {
        print('    ✗ 消息格式错误');
        allConsistent = false;
      }
      print('');
    }

    // 9. 跨设备验证消息一致性
    print('【步骤9】跨设备验证消息一致性...\n');

    // 设备B从远程获取Alice会话的消息
    final remoteSessionAlice = sessionAlice;
    final remoteMessagesForAlice = await proxyBToA.getSessionMessages(
      remoteSessionAlice,
    );
    final localMessagesForAlice = await agents['employee-alice']!
        .getSessionMessages(remoteSessionAlice);

    print('  Alice 会话（本地 vs 远程获取）:');
    print('    - 本地消息数: ${localMessagesForAlice.length}');
    print('    - 远程获取消息数: ${remoteMessagesForAlice.length}');

    if (localMessagesForAlice.length == remoteMessagesForAlice.length) {
      print('    ✓ 消息数量一致');
    } else {
      print('    ✗ 消息数量不一致');
      allConsistent = false;
    }

    // 验证消息内容
    bool contentMatch = true;
    for (int i = 0; i < localMessagesForAlice.length; i++) {
      final local = localMessagesForAlice[i]['content'];
      final remote = remoteMessagesForAlice[i]['content'];
      if (local != remote) {
        contentMatch = false;
        print('    ✗ 消息 $i 内容不一致');
      }
    }
    if (contentMatch) {
      print('    ✓ 消息内容一致');
    } else {
      allConsistent = false;
    }
    print('');

    // 10. 验证 Carol 会话（被两个设备访问过）
    print('【步骤10】验证 Carol 会话（被多个设备访问）...\n');

    final localCarol = await agents['employee-carol']!.getSessionMessages(
      sessionCarol,
    );
    final remoteCarol1 = await proxyAToC(
      devices,
    ).getSessionMessages(sessionCarol);
    final remoteCarol2 = await proxyBToC.getSessionMessages(sessionCarol);

    print('  Carol 会话消息数:');
    print('    - 本地: ${localCarol.length}');
    print('    - 远程(Device-Alpha): ${remoteCarol1.length}');
    print('    - 远程(Device-Beta): ${remoteCarol2.length}');

    if (localCarol.length == remoteCarol1.length &&
        localCarol.length == remoteCarol2.length) {
      print('    ✓ 三方消息数量一致');
    } else {
      print('    ✗ 消息数量不一致');
      allConsistent = false;
    }
    print('');

    // 11. 打印最终会话汇总
    print('【步骤11】最终会话汇总...\n');

    for (final entry in sessionSnapshots.entries) {
      final snapshot = entry.value;
      print('  ${entry.key}:');
      print('    所有者: ${snapshot.ownerEmployeeUuid}@${snapshot.ownerDeviceId}');
      print('    消息列表:');
      for (final msg in snapshot.messages) {
        final role = msg['role'];
        final content = msg['content'] as String;
        final preview = content.length > 40
            ? '${content.substring(0, 40)}...'
            : content;
        print('      [$role] $preview');
      }
      print('');
    }

    // 12. 最终结果
    print('================================================');
    if (allConsistent) {
      print('  ✓ 所有会话状态一致性测试通过！');
    } else {
      print('  ✗ 会话状态一致性测试失败！');
    }
    print('================================================\n');

    // 13. 清理
    print('【步骤13】清理资源...');
    for (final device in devices.values) {
      await device.dispose();
    }
    print('  ✓ 资源已清理\n');
  } finally {
    await host.stop();
    print('Host 已停止');
  }
}

/// 辅助函数：获取 A 到 C 的代理
AgentProxy proxyAToC(Map<String, DeviceClientImpl> devices) {
  return devices['device-alpha']!.getAgent(
    deviceId: 'device-gamma',
    employeeId: 'employee-carol',
  );
}
