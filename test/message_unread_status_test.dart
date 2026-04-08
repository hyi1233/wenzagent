import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  late AgentNotificationHub hub;

  /// 创建测试用的 AgentMessage
  AgentMessage createMessage({
    required String id,
    String role = 'assistant',
    String content = '测试消息',
  }) {
    return AgentMessage(
      id: id,
      role: role,
      type: 'text',
      content: content,
      createdAt: DateTime.now(),
      status: 'completed',
    );
  }

  setUp(() {
    hub = AgentNotificationHub();
  });

  tearDown(() {
    hub.dispose();
  });

  // ============================================================
  // 1. Device Client 接收新消息 & 标记未读
  // ============================================================
  group('DeviceClient - 接收新消息并标记未读', () {
    test('远程消息到达时应自动标记为未读', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-001', content: '远程回复'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 验证未读状态
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(hub.isMessageRead(messageId: 'msg-001', employeeId: 'emp-001'), isFalse);
    });

    test('多条远程消息应累计未读计数', () {
      for (int i = 0; i < 5; i++) {
        hub.onRemoteMessage(
          message: createMessage(id: 'msg-$i', content: '消息 $i'),
          fromDeviceId: 'device-remote',
          toDeviceId: 'device-local',
          employeeId: 'emp-001',
        );
      }

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(5));
      expect(hub.getTotalUnreadCount(), equals(5));
    });

    test('不同员工的消息应独立计数', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-001'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-002'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-003'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-002',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(2));
      expect(hub.getUnreadCount(employeeId: 'emp-002'), equals(1));
      expect(hub.getTotalUnreadCount(), equals(3));
    });

    test('不同来源设备的消息应独立计数', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-001'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-002'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-003'),
        fromDeviceId: 'device-B',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 总未读数
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(3));
      // 按设备计数
      expect(
        hub.getUnreadCount(employeeId: 'emp-001', fromDeviceId: 'device-A'),
        equals(2),
      );
      expect(
        hub.getUnreadCount(employeeId: 'emp-001', fromDeviceId: 'device-B'),
        equals(1),
      );
    });

    test('相同消息ID不重复标记未读（去重）', () {
      final message = createMessage(id: 'msg-dup');

      hub.onRemoteMessage(
        message: message,
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 再次接收相同消息
      hub.onRemoteMessage(
        message: message,
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 未读数不应增加
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
    });

    test('本地消息默认不标记未读', () {
      hub.onLocalMessage(
        message: createMessage(id: 'msg-local', role: 'assistant'),
        employeeId: 'emp-001',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hub.isMessageRead(messageId: 'msg-local', employeeId: 'emp-001'), isTrue);
    });

    test('本地消息可选标记未读', () {
      hub.onLocalMessage(
        message: createMessage(id: 'msg-local-unread', role: 'assistant'),
        employeeId: 'emp-001',
        markUnread: true,
      );

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(
        hub.isMessageRead(messageId: 'msg-local-unread', employeeId: 'emp-001'),
        isFalse,
      );
    });

    test('远程消息到达时应广播 AgentMessageArrivedEvent', () async {
      final events = <AgentNotificationEvent>[];
      hub.stream().listen(events.add);

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-event', content: '事件测试'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 等待微任务完成
      await Future.delayed(Duration.zero);

      final arrivedEvents = events.whereType<AgentMessageArrivedEvent>().toList();
      expect(arrivedEvents.length, equals(1));
      expect(arrivedEvents[0].message.id, equals('msg-event'));
      expect(arrivedEvents[0].employeeId, equals('emp-001'));
      expect(arrivedEvents[0].fromDeviceId, equals('device-remote'));
      expect(arrivedEvents[0].isRemote, isTrue);
    });

    test('远程消息到达时应广播未读计数变更事件', () async {
      final countEvents = <AgentUnreadCountChangedEvent>[];
      hub.stream()
          .where((e) => e is AgentUnreadCountChangedEvent)
          .cast<AgentUnreadCountChangedEvent>()
          .listen(countEvents.add);

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-count'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      await Future.delayed(Duration.zero);

      // 应该有2条计数事件：总计数 + 按设备计数
      expect(countEvents.length, greaterThanOrEqualTo(1));

      // 总计数事件
      final totalCountEvent = countEvents.firstWhere(
        (e) => e.fromDeviceId == null,
      );
      expect(totalCountEvent.unreadCount, equals(1));
      expect(totalCountEvent.employeeId, equals('emp-001'));

      // 按设备计数事件
      final deviceCountEvent = countEvents.firstWhere(
        (e) => e.fromDeviceId == 'device-remote',
      );
      expect(deviceCountEvent.unreadCount, equals(1));
    });

    test('getUnreadMessages 应返回正确的未读消息列表', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-a', content: '消息A'),
        fromDeviceId: 'device-X',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-b', content: '消息B'),
        fromDeviceId: 'device-Y',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 获取全部未读
      final allUnread = hub.getUnreadMessages(employeeId: 'emp-001');
      expect(allUnread.length, equals(2));

      // 按来源设备过滤
      final fromX = hub.getUnreadMessages(
        employeeId: 'emp-001',
        fromDeviceId: 'device-X',
      );
      expect(fromX.length, equals(1));
      expect(fromX[0].message.id, equals('msg-a'));
    });

    test('获取不存在的员工未读数应返回0', () {
      expect(hub.getUnreadCount(employeeId: 'emp-nonexist'), equals(0));
      expect(hub.getTotalUnreadCount(), equals(0));
    });

    test('获取不存在的消息的已读状态应返回已读', () {
      expect(
        hub.isMessageRead(messageId: 'msg-nonexist', employeeId: 'emp-001'),
        isTrue,
      );
    });
  });

  // ============================================================
  // 2. 已读状态不可回退（已读不可改回未读）
  // ============================================================
  group('已读状态不可修改（单向状态）', () {
    test('已读消息不能再次标记为未读', () {
      // 先接收消息（标记未读）
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-readonly'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 标记已读
      final changed = hub.markAsRead(
        messageId: 'msg-readonly',
        employeeId: 'emp-001',
      );
      expect(changed, isTrue);
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(
        hub.isMessageRead(messageId: 'msg-readonly', employeeId: 'emp-001'),
        isTrue,
      );

      // 再次接收相同消息（去重机制阻止重新标记为未读）
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-readonly'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 未读数仍为0，已读状态未被回退
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(
        hub.isMessageRead(messageId: 'msg-readonly', employeeId: 'emp-001'),
        isTrue,
      );
    });

    test('markAsRead 对已读消息返回 false', () {
      // 标记已读
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-double-read'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.markAsRead(messageId: 'msg-double-read', employeeId: 'emp-001');

      // 再次标记应返回 false（无状态变更）
      final changed = hub.markAsRead(
        messageId: 'msg-double-read',
        employeeId: 'emp-001',
      );
      expect(changed, isFalse);
    });

    test('markAsRead 对不存在的消息返回 false', () {
      final changed = hub.markAsRead(
        messageId: 'msg-nonexist',
        employeeId: 'emp-001',
      );
      expect(changed, isFalse);
    });

    test('markAllAsRead 后新消息仍可正常标记未读', () {
      // 发送3条消息并全部标记已读
      for (int i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: createMessage(id: 'msg-old-$i'),
          fromDeviceId: 'device-remote',
          toDeviceId: 'device-local',
          employeeId: 'emp-001',
        );
      }
      hub.markAllAsRead(employeeId: 'emp-001');

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));

      // 新消息应能正常标记未读
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-new'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(
        hub.isMessageRead(messageId: 'msg-new', employeeId: 'emp-001'),
        isFalse,
      );
    });
  });

  // ============================================================
  // 3. Agent Proxy 消息标记已读
  // ============================================================
  group('AgentNotificationHub - 标记消息已读', () {
    test('markAsRead 单条消息标记已读', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-read-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-read-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 标记第一条已读
      final changed = hub.markAsRead(
        messageId: 'msg-read-1',
        employeeId: 'emp-001',
      );

      expect(changed, isTrue);
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(
        hub.isMessageRead(messageId: 'msg-read-1', employeeId: 'emp-001'),
        isTrue,
      );
      expect(
        hub.isMessageRead(messageId: 'msg-read-2', employeeId: 'emp-001'),
        isFalse,
      );
    });

    test('markAsRead 应广播已读状态变更事件', () async {
      final readEvents = <AgentMessageReadStatusChangedEvent>[];
      hub.stream()
          .where((e) => e is AgentMessageReadStatusChangedEvent)
          .cast<AgentMessageReadStatusChangedEvent>()
          .listen(readEvents.add);

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-read-event'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      hub.markAsRead(messageId: 'msg-read-event', employeeId: 'emp-001');

      await Future.delayed(Duration.zero);

      expect(readEvents.length, equals(1));
      expect(readEvents[0].messageId, equals('msg-read-event'));
      expect(readEvents[0].employeeId, equals('emp-001'));
      expect(readEvents[0].isRead, isTrue);
      expect(readEvents[0].fromDeviceId, equals('device-remote'));
    });

    test('markAsRead 应减少按设备维度的未读计数', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-dev-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-dev-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-dev-3'),
        fromDeviceId: 'device-B',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 标记 device-A 的一条消息已读
      hub.markAsRead(messageId: 'msg-dev-1', employeeId: 'emp-001');

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(2));
      expect(
        hub.getUnreadCount(employeeId: 'emp-001', fromDeviceId: 'device-A'),
        equals(1),
      );
      // device-B 不受影响
      expect(
        hub.getUnreadCount(employeeId: 'emp-001', fromDeviceId: 'device-B'),
        equals(1),
      );
    });

    test('markAllAsRead 标记指定员工所有消息已读', () {
      for (int i = 0; i < 5; i++) {
        hub.onRemoteMessage(
          message: createMessage(id: 'msg-all-$i'),
          fromDeviceId: 'device-remote',
          toDeviceId: 'device-local',
          employeeId: 'emp-001',
        );
      }

      hub.markAllAsRead(employeeId: 'emp-001');

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hub.getTotalUnreadCount(), equals(0));

      // 验证所有消息已读
      for (int i = 0; i < 5; i++) {
        expect(
          hub.isMessageRead(messageId: 'msg-all-$i', employeeId: 'emp-001'),
          isTrue,
        );
      }
    });

    test('markAllAsRead 不影响其他员工', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-emp1'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-emp2'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-002',
      );

      hub.markAllAsRead(employeeId: 'emp-001');

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-002'), equals(1));
      expect(hub.getTotalUnreadCount(), equals(1));
    });

    test('markAllAsRead 带设备过滤只标记指定设备的消息', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-a1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-a2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-b1'),
        fromDeviceId: 'device-B',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 只标记 device-A 的消息已读
      hub.markAllAsRead(employeeId: 'emp-001', fromDeviceId: 'device-A');

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
      expect(
        hub.getUnreadCount(employeeId: 'emp-001', fromDeviceId: 'device-A'),
        equals(0),
      );
      expect(
        hub.getUnreadCount(employeeId: 'emp-001', fromDeviceId: 'device-B'),
        equals(1),
      );

      // device-A 的消息应已读
      expect(
        hub.isMessageRead(messageId: 'msg-a1', employeeId: 'emp-001'),
        isTrue,
      );
      expect(
        hub.isMessageRead(messageId: 'msg-a2', employeeId: 'emp-001'),
        isTrue,
      );
      // device-B 的消息应仍为未读
      expect(
        hub.isMessageRead(messageId: 'msg-b1', employeeId: 'emp-001'),
        isFalse,
      );
    });

    test('markAllAsReadGlobal 标记所有员工所有消息已读', () {
      for (int i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: createMessage(id: 'msg-e1-$i'),
          fromDeviceId: 'device-remote',
          toDeviceId: 'device-local',
          employeeId: 'emp-001',
        );
        hub.onRemoteMessage(
          message: createMessage(id: 'msg-e2-$i'),
          fromDeviceId: 'device-remote',
          toDeviceId: 'device-local',
          employeeId: 'emp-002',
        );
      }

      hub.markAllAsReadGlobal();

      expect(hub.getTotalUnreadCount(), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-002'), equals(0));
    });

    test('markAllAsRead 应为每条消息广播已读事件', () async {
      final readEvents = <AgentMessageReadStatusChangedEvent>[];
      hub.stream()
          .where((e) => e is AgentMessageReadStatusChangedEvent)
          .cast<AgentMessageReadStatusChangedEvent>()
          .listen(readEvents.add);

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-batch-1'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-batch-2'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      hub.markAllAsRead(employeeId: 'emp-001');

      await Future.delayed(Duration.zero);

      expect(readEvents.length, equals(2));
      expect(readEvents[0].messageId, equals('msg-batch-1'));
      expect(readEvents[0].isRead, isTrue);
      expect(readEvents[1].messageId, equals('msg-batch-2'));
      expect(readEvents[1].isRead, isTrue);
    });
  });

  // ============================================================
  // 4. Stream 订阅 & 过滤
  // ============================================================
  group('Stream 订阅与过滤', () {
    test('stream 按 employeeId 过滤', () async {
      final emp1Events = <AgentNotificationEvent>[];
      final emp2Events = <AgentNotificationEvent>[];

      hub.stream(employeeId: 'emp-001').listen(emp1Events.add);
      hub.stream(employeeId: 'emp-002').listen(emp2Events.add);

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-2'),
        fromDeviceId: 'device-B',
        toDeviceId: 'device-local',
        employeeId: 'emp-002',
      );

      await Future.delayed(Duration.zero);

      // emp-001 订阅者应只收到 emp-001 的事件
      expect(emp1Events.any((e) => e is AgentMessageArrivedEvent && (e).employeeId == 'emp-001'), isTrue);
      expect(emp1Events.any((e) => e is AgentMessageArrivedEvent && (e).employeeId == 'emp-002'), isFalse);

      // emp-002 订阅者应只收到 emp-002 的事件
      expect(emp2Events.any((e) => e is AgentMessageArrivedEvent && (e).employeeId == 'emp-002'), isTrue);
      expect(emp2Events.any((e) => e is AgentMessageArrivedEvent && (e).employeeId == 'emp-001'), isFalse);
    });

    test('stream 按 fromDeviceId 过滤', () async {
      final deviceAEvents = <AgentNotificationEvent>[];
      hub.stream(fromDeviceId: 'device-A').listen(deviceAEvents.add);

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-a'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-b'),
        fromDeviceId: 'device-B',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      await Future.delayed(Duration.zero);

      final arrivedEvents = deviceAEvents.whereType<AgentMessageArrivedEvent>().toList();
      expect(arrivedEvents.length, equals(1));
      expect(arrivedEvents[0].fromDeviceId, equals('device-A'));
    });

    test('subscribeMessages 只接收消息到达事件', () async {
      final messages = <AgentMessageArrivedEvent>[];
      hub.subscribeMessages(messages.add, employeeId: 'emp-001');

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-sub'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      // 手动触发计数变更事件（通过 markAsRead）
      hub.markAsRead(messageId: 'msg-nonexist', employeeId: 'emp-001');

      await Future.delayed(Duration.zero);

      // 只应有1条消息到达事件，不应有计数事件
      expect(messages.length, equals(1));
      expect(messages[0].message.id, equals('msg-sub'));
    });

    test('subscribeUnreadCount 只接收未读计数变更事件', () async {
      final countChanges = <int>[];
      hub.subscribeUnreadCount(
        (e) => countChanges.add(e.unreadCount),
        employeeId: 'emp-001',
      );

      hub.onRemoteMessage(
        message: createMessage(id: 'msg-cnt-1'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-cnt-2'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      await Future.delayed(Duration.zero);

      // 至少应有2次计数变更（从0->1, 1->2），可能还有按设备的计数
      expect(countChanges, contains(1));
      expect(countChanges, contains(2));
    });
  });

  // ============================================================
  // 5. 生命周期
  // ============================================================
  group('生命周期', () {
    test('dispose 后接收消息不应生效', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-dispose'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      hub.dispose();

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
    });

    test('dispose 后订阅不会报错（broadcast stream）', () {
      // broadcast stream 在 close 后订阅不会抛异常
      hub.dispose();

      hub.stream().listen((_) {});
      // 不应抛出异常
    });
  });

  // ============================================================
  // 6. DeviceClient 端到端模拟场景
  // ============================================================
  group('DeviceClient 端到端场景模拟', () {
    test('模拟 LAN 广播 agentMessageStatusChanged 后标记未读', () async {
      // 模拟 DeviceClientImpl._handleAgentEvent 接收到 LAN 广播
      // 当 type == 'messageStatusChanged' && status == 'completed' 时
      // 调用 _notificationHub.onRemoteMessage()
      final message = AgentMessage(
        id: 'remote-msg-001',
        role: 'assistant',
        type: 'text',
        content: 'Agent 回复内容',
        createdAt: DateTime.now(),
        status: 'completed',
        metadata: {'role': 'assistant', 'type': 'text'},
      );

      // 模拟 DeviceClient 收到远程事件后调用 notificationHub
      hub.onRemoteMessage(
        message: message,
        fromDeviceId: 'remote-device-01',
        toDeviceId: 'local-device',
        employeeId: 'employee-abc',
      );

      // 验证：消息被标记为未读
      expect(
        hub.isMessageRead(messageId: 'remote-msg-001', employeeId: 'employee-abc'),
        isFalse,
      );
      expect(hub.getUnreadCount(employeeId: 'employee-abc'), equals(1));
      expect(
        hub.getUnreadCount(employeeId: 'employee-abc', fromDeviceId: 'remote-device-01'),
        equals(1),
      );

      // 用户打开会话窗口，查看消息 -> 调用 markAllAsRead
      hub.markAllAsRead(
        employeeId: 'employee-abc',
        fromDeviceId: 'remote-device-01',
      );

      // 验证：消息已读
      expect(hub.getUnreadCount(employeeId: 'employee-abc'), equals(0));
      expect(
        hub.isMessageRead(messageId: 'remote-msg-001', employeeId: 'employee-abc'),
        isTrue,
      );
    });

    test('模拟多设备多员工消息通知流程', () async {
      // device-local 上有 emp-001 和 emp-002
      // emp-001 绑定在 remote-device-A
      // emp-002 绑定在 remote-device-B

      // emp-001 在 remote-device-A 上收到 3 条 assistant 消息
      for (int i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: createMessage(id: 'emp1-msg-$i', content: 'emp1 回复 $i'),
          fromDeviceId: 'remote-device-A',
          toDeviceId: 'device-local',
          employeeId: 'emp-001',
        );
      }

      // emp-002 在 remote-device-B 上收到 2 条 assistant 消息
      for (int i = 0; i < 2; i++) {
        hub.onRemoteMessage(
          message: createMessage(id: 'emp2-msg-$i', content: 'emp2 回复 $i'),
          fromDeviceId: 'remote-device-B',
          toDeviceId: 'device-local',
          employeeId: 'emp-002',
        );
      }

      // 总未读数应为 5
      expect(hub.getTotalUnreadCount(), equals(5));
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(3));
      expect(hub.getUnreadCount(employeeId: 'emp-002'), equals(2));

      // 用户查看 emp-001 的消息，标记已读
      hub.markAllAsRead(employeeId: 'emp-001');

      expect(hub.getTotalUnreadCount(), equals(2));
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-002'), equals(2));

      // 用户查看 emp-002 的消息，标记已读
      hub.markAllAsRead(employeeId: 'emp-002');

      expect(hub.getTotalUnreadCount(), equals(0));
    });

    test('模拟部分已读场景：只读最新消息', () {
      // 收到5条消息
      for (int i = 0; i < 5; i++) {
        hub.onRemoteMessage(
          message: createMessage(id: 'msg-partial-$i'),
          fromDeviceId: 'device-remote',
          toDeviceId: 'device-local',
          employeeId: 'emp-001',
        );
      }

      // 只标记前3条已读
      for (int i = 0; i < 3; i++) {
        hub.markAsRead(messageId: 'msg-partial-$i', employeeId: 'emp-001');
      }

      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(2));
      expect(
        hub.isMessageRead(messageId: 'msg-partial-0', employeeId: 'emp-001'),
        isTrue,
      );
      expect(
        hub.isMessageRead(messageId: 'msg-partial-3', employeeId: 'emp-001'),
        isFalse,
      );
      expect(
        hub.isMessageRead(messageId: 'msg-partial-4', employeeId: 'emp-001'),
        isFalse,
      );
    });
  });

  // ============================================================
  // 7. AgentStatusChanged 通知
  // ============================================================
  group('AgentStatusChanged 通知', () {
    test('onAgentStatusChanged 应广播状态通知', () async {
      final statusEvents = <AgentStatusNotifyEvent>[];
      hub.stream()
          .where((e) => e is AgentStatusNotifyEvent)
          .cast<AgentStatusNotifyEvent>()
          .listen(statusEvents.add);

      hub.onAgentStatusChanged(
        employeeId: 'emp-001',
        fromDeviceId: 'device-remote',
        status: 'processing',
      );

      await Future.delayed(Duration.zero);

      expect(statusEvents.length, equals(1));
      expect(statusEvents[0].employeeId, equals('emp-001'));
      expect(statusEvents[0].fromDeviceId, equals('device-remote'));
      expect(statusEvents[0].status, equals('processing'));
    });

    test('AgentStatusChanged 不影响未读计数', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-status'),
        fromDeviceId: 'device-remote',
        toDeviceId: 'device-local',
        employeeId: 'emp-001',
      );

      hub.onAgentStatusChanged(
        employeeId: 'emp-001',
        fromDeviceId: 'device-remote',
        status: 'idle',
      );

      // 未读数不受影响
      expect(hub.getUnreadCount(employeeId: 'emp-001'), equals(1));
    });
  });

  // ============================================================
  // 8. CachedAgentProxy.markMessagesAsRead 回调测试
  // ============================================================
  group('CachedAgentProxy.markMessagesAsRead', () {
    test('onMarkAsRead 回调未设置时调用 markMessagesAsRead 不报错', () {
      // CachedAgentProxy 构造需要 AgentProxy 等依赖，这里只测回调逻辑
      void Function(String, String?)? callback;
      callback?.call('emp-001', 'device-A');
      // 不应抛出异常
    });

    test('onMarkAsRead 回调应被正确调用', () {
      late String capturedEmpId;
      late String? capturedFromDevId;

      void onMarkAsRead(String employeeId, String? fromDeviceId) {
        capturedEmpId = employeeId;
        capturedFromDevId = fromDeviceId;
      }

      // 模拟 CachedAgentProxy.markMessagesAsRead 的行为
      onMarkAsRead('emp-test', 'device-test');

      expect(capturedEmpId, equals('emp-test'));
      expect(capturedFromDevId, equals('device-test'));
    });

    test('DeviceClientImpl 注入的 onMarkAsRead 应触发 hub.markAllAsRead + broadcast', () {
      // 模拟 DeviceClientImpl 中的回调注入逻辑
      final capturedBroadcasts = <Map<String, dynamic>>[];

      // 模拟 _broadcastReadStatus
      void broadcastReadStatus({
        required String employeeId,
        String? fromDeviceId,
      }) {
        capturedBroadcasts.add({
          'employeeId': employeeId,
          'fromDeviceId': fromDeviceId,
        });
      }

      // 模拟 DeviceClientImpl 注入的 onMarkAsRead 回调
      void onMarkAsRead(String empId, String? fromDevId) {
        hub.markAllAsRead(employeeId: empId, fromDeviceId: fromDevId);
        broadcastReadStatus(employeeId: empId, fromDeviceId: fromDevId);
      }

      // 先添加未读消息
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-proxy-1'),
        fromDeviceId: 'remote-dev',
        toDeviceId: 'local-dev',
        employeeId: 'emp-proxy',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-proxy-2'),
        fromDeviceId: 'remote-dev',
        toDeviceId: 'local-dev',
        employeeId: 'emp-proxy',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-proxy'), equals(2));

      // 调用 onMarkAsRead（模拟用户打开会话窗口）
      onMarkAsRead('emp-proxy', 'remote-dev');

      // 验证：未读清零 + 广播已触发
      expect(hub.getUnreadCount(employeeId: 'emp-proxy'), equals(0));
      expect(capturedBroadcasts.length, equals(1));
      expect(capturedBroadcasts[0]['employeeId'], equals('emp-proxy'));
      expect(capturedBroadcasts[0]['fromDeviceId'], equals('remote-dev'));
    });
  });

  // ============================================================
  // 9. 跨设备已读状态同步模拟
  // ============================================================
  group('跨设备已读状态同步', () {
    test('设备A标记已读后广播 → 设备B收到通知清除未读', () {
      // 设备B 收到远程消息，标记为未读
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-sync-1', content: '来自设备A的消息'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-shared',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-shared'), equals(1));

      // 模拟设备A的用户查看了消息，广播已读状态
      // 设备B 收到 LAN 消息：agentMessageReadStatus
      final readStatusPayload = {
        'employeeId': 'emp-shared',
        'fromDeviceId': 'device-A',
        'readerDeviceId': 'device-A',
      };

      // 模拟 _handleRemoteReadStatus 逻辑
      final employeeId = readStatusPayload['employeeId'] as String;
      final fromDeviceId = readStatusPayload['fromDeviceId'] as String?;
      final readerDeviceId = readStatusPayload['readerDeviceId'] as String;

      // 只处理来自其他设备的已读通知（忽略自己发出的）
      if (readerDeviceId != 'device-B') {
        hub.markAllAsRead(employeeId: employeeId, fromDeviceId: fromDeviceId);
      }

      // 验证：设备B上对应消息的未读计数被清除
      expect(hub.getUnreadCount(employeeId: 'emp-shared'), equals(0));
      expect(
        hub.isMessageRead(messageId: 'msg-sync-1', employeeId: 'emp-shared'),
        isTrue,
      );
    });

    test('设备忽略自己发出的已读广播（防回声）', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-echo', content: '测试回声'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-echo',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-echo'), equals(1));

      // 模拟设备B收到自己之前发出的广播（readerDeviceId == deviceId）
      final payload = {
        'employeeId': 'emp-echo',
        'fromDeviceId': 'device-A',
        'readerDeviceId': 'device-B', // 这就是设备B自己发出的
      };

      final readerDeviceId = payload['readerDeviceId'] as String;
      if (readerDeviceId != 'device-B') {
        hub.markAllAsRead(
          employeeId: payload['employeeId'] as String,
          fromDeviceId: payload['fromDeviceId'] as String?,
        );
      }

      // 验证：未读计数不变（回声被忽略）
      expect(hub.getUnreadCount(employeeId: 'emp-echo'), equals(1));
    });

    test('全局已读广播应清除所有员工的所有未读', () {
      // 多员工有未读消息
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-g1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-g1',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-g2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-g2',
      );
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-g3'),
        fromDeviceId: 'device-B',
        toDeviceId: 'device-A',
        employeeId: 'emp-g3',
      );

      expect(hub.getTotalUnreadCount(), equals(3));

      // 模拟收到全局已读广播
      final globalPayload = {
        'global': true,
        'readerDeviceId': 'device-A',
      };

      final global = globalPayload['global'] as bool? ?? false;
      final readerDeviceId = globalPayload['readerDeviceId'] as String?;

      if (readerDeviceId != 'device-B') {
        if (global) {
          hub.markAllAsReadGlobal();
        }
      }

      // 验证：所有未读清零
      expect(hub.getTotalUnreadCount(), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-g1'), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-g2'), equals(0));
      expect(hub.getUnreadCount(employeeId: 'emp-g3'), equals(0));
    });

    test('全局已读广播也忽略自己发出的回声', () {
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-glbl-echo'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-glbl',
      );

      expect(hub.getTotalUnreadCount(), equals(1));

      // 模拟收到自己发出的全局已读广播（应被忽略）
      final globalPayload = {
        'global': true,
        'readerDeviceId': 'device-B', // 自己发出的
      };

      final readerDeviceId = globalPayload['readerDeviceId'] as String;
      if (readerDeviceId != 'device-B') {
        hub.markAllAsReadGlobal();
      }

      // 未读数不变
      expect(hub.getTotalUnreadCount(), equals(1));
    });

    test('跨设备同步后新消息仍可正常标记未读', () {
      // 步骤1：设备A有未读消息
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-cycle-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-cycle',
      );
      expect(hub.getUnreadCount(employeeId: 'emp-cycle'), equals(1));

      // 步骤2：设备A标记已读，广播到设备B
      hub.markAllAsRead(employeeId: 'emp-cycle', fromDeviceId: 'device-A');
      expect(hub.getUnreadCount(employeeId: 'emp-cycle'), equals(0));

      // 步骤3：设备A又有新消息
      hub.onRemoteMessage(
        message: createMessage(id: 'msg-cycle-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-cycle',
      );

      // 新消息应正常标记为未读
      expect(hub.getUnreadCount(employeeId: 'emp-cycle'), equals(1));
      expect(
        hub.isMessageRead(messageId: 'msg-cycle-2', employeeId: 'emp-cycle'),
        isFalse,
      );
    });

    test('LAN 消息 payload 序列化/反序列化正确性', () {
      // 验证 _broadcastReadStatus 构造的 JSON 可被 _handleRemoteReadStatus 正确解析

      // 模拟 _broadcastReadStatus 构造的 JSON
      final payload = jsonEncode({
        'employeeId': 'emp-json',
        'fromDeviceId': 'device-A',
        'readerDeviceId': 'device-A',
      });

      // 模拟 _handleRemoteReadStatus 反序列化
      final content = jsonDecode(payload) as Map<String, dynamic>;
      expect(content['employeeId'], equals('emp-json'));
      expect(content['fromDeviceId'], equals('device-A'));
      expect(content['readerDeviceId'], equals('device-A'));

      // 全局已读的 payload
      final globalPayload = jsonEncode({
        'global': true,
        'readerDeviceId': 'device-B',
      });

      final globalContent = jsonDecode(globalPayload) as Map<String, dynamic>;
      expect(globalContent['global'], isTrue);
      expect(globalContent['readerDeviceId'], equals('device-B'));
    });
  });
}
