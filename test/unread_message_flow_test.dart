import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

/// 等待微任务队列清空
Future<void> pumpEventQueue() => Future.delayed(Duration.zero);

AgentMessage assistantMsg({required String id, String content = '回复内容'}) {
  return AgentMessage(
    id: id, role: 'assistant', type: 'text',
    content: content, createdAt: DateTime.now(), status: 'completed',
  );
}

AgentMessage userMsg({required String id, String content = '用户输入'}) {
  return AgentMessage(
    id: id, role: 'user', type: 'text',
    content: content, createdAt: DateTime.now(),
  );
}

/// 内存 Mock ChatAdapter，支持注入消息
class _MockChatAdapter extends IChatAdapter {
  final List<AgentMessage> _messages = [];

  @override
  List<Map<String, dynamic>> get currentMessages => _messages.map((m) => m.toMap()).toList();
  @override
  Map<String, dynamic>? get currentContext => null;
  @override
  bool get isStreaming => false;
  @override
  Future<void> initSession({required String employeeId}) async {}
  @override
  Stream<StreamResponse> streamMessage(Map<String, dynamic> messageData,
      {CancellationToken? cancellationToken}) async* {}
  @override
  Future<void> stopStreaming() async {}
  @override
  Future<List<AgentMessage>> getSessionMessages(String employeeId) async =>
      List.unmodifiable(_messages);
  @override
  Future<void> clearCurrentSession() async => _messages.clear();
  @override
  bool removeMessageFromMemory(String messageId) {
    final len = _messages.length;
    _messages.removeWhere((m) => m.id == messageId);
    return _messages.length < len;
  }
  @override
  void setContext(Map<String, dynamic> contextData) {}
  @override
  void clearContext() {}
  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {}
  @override
  Map<String, dynamic>? getProviderConfig() => null;
  @override
  Map<String, dynamic>? getCurrentProvider() => null;
  @override
  Future<void> updateProjectContext(Map<String, dynamic>? projectContext) async {}
  @override
  void setToolRegistry(covariant ToolRegistry? registry) {}
  @override
  void setPermissionManager(covariant ToolPermissionManager? manager) {}
  @override
  void setToolEventCallback(void Function(Map<String, dynamic> event)? callback) {}
  @override
  void updateMessageStatus(String messageId, AgentMessageStatus status, {String? error}) {}
  @override
  Future<String> invokeOnce(String prompt) async => '';
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setProjectData(Map<String, dynamic>? projectData) async {}
  @override
  Map<String, dynamic>? getCurrentProjectData() => null;

  void addMessage(AgentMessage msg) => _messages.add(msg);
}

void main() {
  // ============================================================
  // Step 1: Agent收到回复 → 消息标记未读 → 广播到所有设备
  // ============================================================
  group('Step 1: Agent收到回复 → 消息标记未读', () {
    late AgentNotificationHub hub;
    setUp(() => hub = AgentNotificationHub());
    tearDown(() => hub.dispose());

    test('助手回复到达时自动标记为未读', () {
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(hub.isMessageRead(messageId: 'a-1', employeeId: 'emp-001'), isFalse);
    });

    test('多条助手回复累计未读', () {
      for (var i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: assistantMsg(id: 'a-$i'),
          fromDeviceId: 'device-agent', toDeviceId: 'device-client',
          employeeId: 'emp-001',
        );
      }
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(3));
      expect(hub.getTotalUnreadCount(), equals(3));
    });

    test('不同员工的消息独立计数', () {
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-e1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-e2'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-002',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(hub.getUnreadCount(employeeId: 'emp-002'), equals(1));
      expect(hub.getTotalUnreadCount(), equals(2));
    });

    test('相同消息ID不重复标记未读', () {
      final msg = assistantMsg(id: 'dup-1');
      hub.onRemoteMessage(
        message: msg, fromDeviceId: 'device-agent',
        toDeviceId: 'device-client', employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: msg, fromDeviceId: 'device-agent',
        toDeviceId: 'device-client', employeeId: 'emp-001',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
    });

    test('用户消息（本地发送）不标记未读', () {
      hub.onLocalMessage(message: userMsg(id: 'u-1'), employeeId: 'emp-001');
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
    });
  });

  // ============================================================
  // Step 2: 所有设备收到消息 → 会话列表更新未读数 + 最新消息卡片
  // ============================================================
  group('Step 2: 设备收到消息 → UI更新未读数和消息卡片', () {
    late AgentNotificationHub hub;
    setUp(() => hub = AgentNotificationHub());
    tearDown(() => hub.dispose());

    test('subscribeMessages 接收消息到达事件', () async {
      final events = <AgentMessageArrivedEvent>[];
      hub.subscribeMessages(events.add);
      hub.onRemoteMessage(
        message: assistantMsg(id: 'card-1', content: '最新回复'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );
      await pumpEventQueue();
      expect(events.length, equals(1));
      expect(events[0].message.id, equals('card-1'));
      expect(events[0].isRemote, isTrue);
    });

    test('subscribeUnreadCount 接收计数变更事件', () async {
      final countEvents = <AgentUnreadCountChangedEvent>[];
      hub.subscribeUnreadCount(countEvents.add, employeeId: 'emp-001');
      hub.onRemoteMessage(
        message: assistantMsg(id: 'cnt-1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );
      await pumpEventQueue();
      final total = countEvents.where((e) => e.fromDeviceId == null).toList();
      expect(total.last.unreadCount, equals(1));
    });

    test('多条消息到达时 UI 事件有序', () async {
      final messages = <AgentMessageArrivedEvent>[];
      hub.subscribeMessages(messages.add);
      for (var i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: assistantMsg(id: 'seq-$i'),
          fromDeviceId: 'device-agent', toDeviceId: 'device-client',
          employeeId: 'emp-001',
        );
      }
      await pumpEventQueue();
      expect(messages.length, equals(3));
      expect(messages[0].message.id, equals('seq-0'));
      expect(messages[2].message.id, equals('seq-2'));
    });

    test('按员工过滤只收到对应员工的事件', () async {
      final emp1 = <AgentMessageArrivedEvent>[];
      hub.subscribeMessages(emp1.add, employeeId: 'emp-001');
      hub.onRemoteMessage(
        message: assistantMsg(id: 'e1'), fromDeviceId: 'd',
        toDeviceId: 'd', employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'e2'), fromDeviceId: 'd',
        toDeviceId: 'd', employeeId: 'emp-002',
      );
      await pumpEventQueue();
      expect(emp1.length, equals(1));
      expect(emp1[0].employeeId, equals('emp-001'));
    });
  });

  // ============================================================
  // Step 3: 会话打开 → 自动标记已读 → 通过proxy发送已读状态到Agent
  // ============================================================
  group('Step 3: 打开会话 → 自动标记已读 → 通知Agent', () {
    late AgentNotificationHub hub;
    setUp(() => hub = AgentNotificationHub());
    tearDown(() => hub.dispose());

    test('markAllAsRead 将未读消息全部标记已读', () {
      for (var i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: assistantMsg(id: 'read-$i'),
          fromDeviceId: 'device-agent', toDeviceId: 'device-client',
          employeeId: 'emp-001',
        );
      }
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(3));

      hub.markAllAsRead(employeeId: 'emp-001');

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hub.getTotalUnreadCount(), equals(0));
      for (var i = 0; i < 3; i++) {
        expect(hub.isMessageRead(messageId: 'read-$i', employeeId: 'emp-001'), isTrue);
      }
    });

    test('onMarkAsRead 回调模拟 CachedAgentProxy → DeviceClient → 广播', () {
      final broadcasts = <Map<String, dynamic>>[];

      void onMarkAsRead(String empId, String? fromDevId) {
        hub.markAllAsRead(employeeId: empId, fromDeviceId: fromDevId);
        broadcasts.add({
          'employeeId': empId,
          'fromDeviceId': fromDevId,
          'readerDeviceId': 'device-client',
        });
      }

      hub.onRemoteMessage(
        message: assistantMsg(id: 'p-1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'p-2'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );

      onMarkAsRead('emp-001', 'device-agent');

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(broadcasts.length, equals(1));
      expect(broadcasts[0]['employeeId'], equals('emp-001'));
      expect(broadcasts[0]['readerDeviceId'], equals('device-client'));
    });

    test('markAsRead 单条标记减少未读', () {
      hub.onRemoteMessage(
        message: assistantMsg(id: 's-1'),
        fromDeviceId: 'd', toDeviceId: 'd', employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 's-2'),
        fromDeviceId: 'd', toDeviceId: 'd', employeeId: 'emp-001',
      );
      hub.markAsRead(messageId: 's-1', employeeId: 'emp-001');
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(hub.isMessageRead(messageId: 's-1', employeeId: 'emp-001'), isTrue);
      expect(hub.isMessageRead(messageId: 's-2', employeeId: 'emp-001'), isFalse);
    });

    test('markAllAsRead 不影响其他员工', () {
      hub.onRemoteMessage(
        message: assistantMsg(id: 'iso-1'),
        fromDeviceId: 'd', toDeviceId: 'd', employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'iso-2'),
        fromDeviceId: 'd', toDeviceId: 'd', employeeId: 'emp-002',
      );
      hub.markAllAsRead(employeeId: 'emp-001');
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-002'), equals(1));
    });
  });

  // ============================================================
  // Step 4: Agent收到已读状态 → 更新缓存 → 广播
  // ============================================================
  group('Step 4: Agent收到已读状态 → 更新缓存 → 广播', () {
    late AgentImpl agent;
    late _MockChatAdapter chatAdapter;

    setUp(() async {
      chatAdapter = _MockChatAdapter();
      agent = AgentImpl(employeeId: 'emp-001', chatAdapter: chatAdapter);
      await agent.initialize(employeeId: 'emp-001');
    });
    tearDown(() async => agent.dispose());

    test('markMessagesAsRead 指定消息ID标记已读', () async {
      chatAdapter.addMessage(assistantMsg(id: 'm1'));
      chatAdapter.addMessage(assistantMsg(id: 'm2'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
        messageIds: ['m1', 'm2'],
      );
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(s['readStatus']['m1'], isTrue);
      expect(s['readStatus']['m2'], isTrue);
    });

    test('markMessagesAsRead 不指定ID则标记全部已读', () async {
      chatAdapter.addMessage(assistantMsg(id: 'all-1'));
      chatAdapter.addMessage(assistantMsg(id: 'all-2'));
      chatAdapter.addMessage(assistantMsg(id: 'all-3'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-B', employeeId: 'emp-001',
      );
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-B', employeeId: 'emp-001',
      );
      expect(s['readStatus']['all-1'], isTrue);
      expect(s['readStatus']['all-2'], isTrue);
      expect(s['readStatus']['all-3'], isTrue);
    });

    test('不同设备的已读状态独立记录', () async {
      chatAdapter.addMessage(assistantMsg(id: 'shared-1'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
        messageIds: ['shared-1'],
      );
      final sA = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      final sB = await agent.getMessagesReadStatus(
        deviceId: 'device-B', employeeId: 'emp-001',
      );
      expect(sA['readStatus']['shared-1'], isTrue);
      expect(sB['readStatus']['shared-1'], isFalse);
    });

    test('markMessagesAsRead 广播 messageReadStatusChanged 事件', () async {
      chatAdapter.addMessage(assistantMsg(id: 'ev-1'));
      final events = <Map<String, dynamic>>[];
      agent.onEvent.listen(events.add);
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
        messageIds: ['ev-1'],
      );
      await pumpEventQueue();
      final readEvts = events
          .where((e) => e['type'] == 'messageReadStatusChanged')
          .toList();
      expect(readEvts.length, equals(1));
      expect(readEvts[0]['data']['readerDeviceId'], equals('device-A'));
    });

    test('未标记已读的消息查询返回 false', () async {
      chatAdapter.addMessage(assistantMsg(id: 'ur-1'));
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(s['readStatus']['ur-1'], isFalse);
    });

    test('重复标记已读无副作用', () async {
      chatAdapter.addMessage(assistantMsg(id: 'dr'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
        messageIds: ['dr'],
      );
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
        messageIds: ['dr'],
      );
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(s['readStatus']['dr'], isTrue);
    });
  });

  // ============================================================
  // Step 5: 所有设备收到消息状态更新 → 更新已读状态
  // ============================================================
  group('Step 5: Agent广播已读状态 → 其他设备更新', () {
    late AgentNotificationHub hubB;
    late AgentNotificationHub hubC;

    setUp(() {
      hubB = AgentNotificationHub();
      hubC = AgentNotificationHub();
    });
    tearDown(() {
      hubB.dispose();
      hubC.dispose();
    });

    test('设备A标记已读 → Agent广播 → 设备B收到清除未读', () {
      hubB.onRemoteMessage(
        message: assistantMsg(id: 'bc-1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-B',
        employeeId: 'emp-001',
      );
      expect(hubB.getUnreadCount(employeeId: 'emp-001'), equals(1));

      // 模拟 _handleAgentEvent: messageReadStatusChanged
      final readerDeviceId = 'device-A';
      final fromDeviceId = 'device-agent';
      if (readerDeviceId != 'device-B') {
        hubB.markAllAsRead(employeeId: 'emp-001', fromDeviceId: fromDeviceId);
      }

      expect(hubB.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(
        hubB.isMessageRead(messageId: 'bc-1', employeeId: 'emp-001'),
        isTrue,
      );
    });

    test('设备忽略自己发出的已读广播（防回声）', () {
      hubB.onRemoteMessage(
        message: assistantMsg(id: 'echo-1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-B',
        employeeId: 'emp-001',
      );
      expect(hubB.getUnreadCount(employeeId: 'emp-001'), equals(1));

      // readerDeviceId == deviceId → 忽略
      final readerDeviceId = 'device-B';
      if (readerDeviceId != 'device-B') {
        hubB.markAllAsRead(employeeId: 'emp-001');
      }
      expect(hubB.getUnreadCount(employeeId: 'emp-001'), equals(1));
    });

    test('多设备同步：A标记已读 → B和C都清除', () {
      hubB.onRemoteMessage(
        message: assistantMsg(id: 'mc-1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-B',
        employeeId: 'emp-001',
      );
      hubC.onRemoteMessage(
        message: assistantMsg(id: 'mc-1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-C',
        employeeId: 'emp-001',
      );
      expect(hubB.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(hubC.getUnreadCount(employeeId: 'emp-001'), equals(1));

      // 收到广播
      hubB.markAllAsRead(employeeId: 'emp-001');
      hubC.markAllAsRead(employeeId: 'emp-001');

      expect(hubB.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hubC.getUnreadCount(employeeId: 'emp-001'), equals(0));
    });

    test('Agent广播事件 JSON 序列化/反序列化正确', () {
      final event = {
        'employeeId': 'emp-001',
        'type': 'messageReadStatusChanged',
        'data': {'readerDeviceId': 'device-A', 'messageIds': null},
      };
      final json = jsonEncode(event);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['type'], equals('messageReadStatusChanged'));
      expect(
        (decoded['data'] as Map)['readerDeviceId'],
        equals('device-A'),
      );
    });
  });

  // ============================================================
  // Step 6: 设备重新打开app → 从Agent查询已读状态
  // ============================================================
  group('Step 6: 设备重开app → 从Agent查询已读状态', () {
    late AgentImpl agent;
    late _MockChatAdapter chatAdapter;

    setUp(() async {
      chatAdapter = _MockChatAdapter();
      agent = AgentImpl(employeeId: 'emp-001', chatAdapter: chatAdapter);
      await agent.initialize(employeeId: 'emp-001');
    });
    tearDown(() async => agent.dispose());

    test('之前已读 → 重开后查询仍为已读', () async {
      chatAdapter.addMessage(assistantMsg(id: 'p-1'));
      chatAdapter.addMessage(assistantMsg(id: 'p-2'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
      );
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(s['readStatus']['p-1'], isTrue);
      expect(s['readStatus']['p-2'], isTrue);
    });

    test('从未已读 → 查询返回未读', () async {
      chatAdapter.addMessage(assistantMsg(id: 'n-1'));
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-B', employeeId: 'emp-001',
      );
      expect(s['readStatus']['n-1'], isFalse);
    });

    test('部分已读', () async {
      chatAdapter.addMessage(assistantMsg(id: 'pa-1'));
      chatAdapter.addMessage(assistantMsg(id: 'pa-2'));
      chatAdapter.addMessage(assistantMsg(id: 'pa-3'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
        messageIds: ['pa-1', 'pa-2'],
      );
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(s['readStatus']['pa-1'], isTrue);
      expect(s['readStatus']['pa-2'], isTrue);
      expect(s['readStatus']['pa-3'], isFalse);
    });

    test('多设备独立查询', () async {
      chatAdapter.addMessage(assistantMsg(id: 'mq-1'));
      chatAdapter.addMessage(assistantMsg(id: 'mq-2'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
      );
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-B', employeeId: 'emp-001',
        messageIds: ['mq-1'],
      );
      final sA = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      final sB = await agent.getMessagesReadStatus(
        deviceId: 'device-B', employeeId: 'emp-001',
      );
      expect(sA['readStatus']['mq-1'], isTrue);
      expect(sA['readStatus']['mq-2'], isTrue);
      expect(sB['readStatus']['mq-1'], isTrue);
      expect(sB['readStatus']['mq-2'], isFalse);
    });

    test('无消息时返回空 readStatus', () async {
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(s['readStatus'], isA<Map>());
      expect((s['readStatus'] as Map).isEmpty, isTrue);
    });

    test('返回值结构正确', () async {
      chatAdapter.addMessage(assistantMsg(id: 'st-1'));
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
        messageIds: ['st-1'],
      );
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(s, containsPair('employeeId', 'emp-001'));
      expect(s, containsPair('deviceId', 'device-A'));
      expect(s['readStatus'], isA<Map<String, dynamic>>());
    });
  });

  // ============================================================
  // 端到端：完整 6 步串联
  // ============================================================
  group('端到端完整流程：6步串联', () {
    test('完整未读消息流程模拟', () async {
      final hub = AgentNotificationHub();
      final chatAdapter = _MockChatAdapter();
      final agent = AgentImpl(
        employeeId: 'emp-001', chatAdapter: chatAdapter,
      );
      await agent.initialize(employeeId: 'emp-001');

      // 预置消息
      chatAdapter.addMessage(assistantMsg(id: 'e2e-1', content: '回复1'));
      chatAdapter.addMessage(assistantMsg(id: 'e2e-2', content: '回复2'));

      // Step 2: UI先订阅（在消息到达前注册）
      final arrived = <AgentMessageArrivedEvent>[];
      hub.subscribeMessages(arrived.add);

      // Step 1: Agent收到回复 → 广播 → 设备标记未读
      hub.onRemoteMessage(
        message: assistantMsg(id: 'e2e-1', content: '回复1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'e2e-2', content: '回复2'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-client',
        employeeId: 'emp-001',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(2));
      await pumpEventQueue();
      expect(arrived.length, equals(2));

      // Step 3: 用户打开会话 → 标记已读 → 通知Agent
      hub.markAllAsRead(employeeId: 'emp-001');
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));

      // Step 4: Agent收到已读 → 更新缓存 → 广播事件
      final agentEvents = <Map<String, dynamic>>[];
      agent.onEvent.listen(agentEvents.add);
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-client', employeeId: 'emp-001',
      );
      await pumpEventQueue();
      expect(
        agentEvents.any((e) => e['type'] == 'messageReadStatusChanged'),
        isTrue,
      );

      // Step 5: 其他设备收到广播 → 清除未读
      final hubOther = AgentNotificationHub();
      hubOther.onRemoteMessage(
        message: assistantMsg(id: 'e2e-1', content: '回复1'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-other',
        employeeId: 'emp-001',
      );
      expect(hubOther.getUnreadCount(employeeId: 'emp-001'), equals(1));
      hubOther.markAllAsRead(employeeId: 'emp-001');
      expect(hubOther.getUnreadCount(employeeId: 'emp-001'), equals(0));

      // Step 6: 设备重开 → 从Agent查询已读
      final s = await agent.getMessagesReadStatus(
        deviceId: 'device-client', employeeId: 'emp-001',
      );
      expect(s['readStatus']['e2e-1'], isTrue);
      expect(s['readStatus']['e2e-2'], isTrue);

      // 新设备查到未读
      final sNew = await agent.getMessagesReadStatus(
        deviceId: 'device-new', employeeId: 'emp-001',
      );
      expect(sNew['readStatus']['e2e-1'], isFalse);
      expect(sNew['readStatus']['e2e-2'], isFalse);

      hub.dispose();
      hubOther.dispose();
      await agent.dispose();
    });

    test('多轮对话：已读后新消息仍标记未读', () async {
      final hub = AgentNotificationHub();
      final chatAdapter = _MockChatAdapter();
      final agent = AgentImpl(
        employeeId: 'emp-001', chatAdapter: chatAdapter,
      );
      await agent.initialize(employeeId: 'emp-001');

      // 第一轮
      for (var i = 1; i <= 3; i++) {
        chatAdapter.addMessage(assistantMsg(id: 'r1-$i'));
        hub.onRemoteMessage(
          message: assistantMsg(id: 'r1-$i'),
          fromDeviceId: 'd', toDeviceId: 'd', employeeId: 'emp-001',
        );
      }
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(3));

      hub.markAllAsRead(employeeId: 'emp-001');
      await agent.markMessagesAsRead(
        readerDeviceId: 'device-A', employeeId: 'emp-001',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));

      // 第二轮：新消息
      chatAdapter.addMessage(assistantMsg(id: 'r2-1'));
      hub.onRemoteMessage(
        message: assistantMsg(id: 'r2-1'),
        fromDeviceId: 'd', toDeviceId: 'd', employeeId: 'emp-001',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(hub.isMessageRead(messageId: 'r2-1', employeeId: 'emp-001'), isFalse);

      hub.dispose();
      await agent.dispose();
    });

    test('Device-to-Device 广播 payload 防回声校验', () {
      final hub = AgentNotificationHub();

      hub.onRemoteMessage(
        message: assistantMsg(id: 'echo-test'),
        fromDeviceId: 'device-agent', toDeviceId: 'device-B',
        employeeId: 'emp-001',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));

      // 模拟 Device-to-Device LAN 广播 payload
      final payload = {
        'readerDeviceId': 'device-B', // 与当前设备相同 → 应忽略
        'employeeId': 'emp-001',
      };

      if ((payload['readerDeviceId'] as String) != 'device-B') {
        hub.markAllAsRead(employeeId: 'emp-001');
      }
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));

      // 其他设备的广播 → 应清除
      payload['readerDeviceId'] = 'device-A';
      if ((payload['readerDeviceId'] as String) != 'device-B') {
        hub.markAllAsRead(employeeId: 'emp-001');
      }
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));

      hub.dispose();
    });
  });
}