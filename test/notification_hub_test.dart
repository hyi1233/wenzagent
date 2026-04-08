import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

/// 等待微任务队列清空（让 Stream 异步事件投递完成）
Future<void> pumpEventQueue() => Future.delayed(Duration.zero);

void main() {
  late AgentNotificationHub hub;

  /// 创建助手消息
  AgentMessage assistantMsg({required String id, String content = '回复内容'}) {
    return AgentMessage(
      id: id,
      role: 'assistant',
      type: 'text',
      content: content,
      createdAt: DateTime.now(),
      status: 'completed',
    );
  }

  /// 创建用户消息
  AgentMessage userMsg({required String id, String content = '用户输入'}) {
    return AgentMessage(
      id: id,
      role: 'user',
      type: 'text',
      content: content,
      createdAt: DateTime.now(),
    );
  }

  /// 创建权限请求消息（模拟 waitingPermission）
  AgentMessage permissionMsg({required String id, String content = '请求权限'}) {
    return AgentMessage(
      id: id,
      role: 'assistant',
      type: 'permission',
      content: content,
      createdAt: DateTime.now(),
      status: 'waitingPermission',
    );
  }

  setUp(() {
    hub = AgentNotificationHub();
  });

  tearDown(() {
    hub.dispose();
  });

  // ============================================================
  // 远程消息到达
  // ============================================================
  group('远程消息到达', () {
    test('收到助手消息后 subscribeMessages 能收到事件', () async {
      final completer = Completer<AgentMessageArrivedEvent>();
      hub.subscribeMessages((event) {
        if (!completer.isCompleted) completer.complete(event);
      });

      final msg = assistantMsg(id: 'msg-1', content: '你好');
      hub.onRemoteMessage(
        message: msg,
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      final event = await completer.future;
      expect(event.message.id, 'msg-1');
      expect(event.message.role, 'assistant');
      expect(event.message.content, '你好');
      expect(event.isRemote, isTrue);
      expect(event.fromDeviceId, 'device-A');
      expect(event.employeeId, 'emp-1');
    });

    test('收到助手消息后未读数量为1', () async {
      final msg = assistantMsg(id: 'msg-2');
      hub.onRemoteMessage(
        message: msg,
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 1);
      expect(hub.getTotalUnreadCount(), 1);
    });

    test('收到多条助手消息后未读数量正确累加', () {
      for (var i = 0; i < 5; i++) {
        hub.onRemoteMessage(
          message: assistantMsg(id: 'msg-$i'),
          fromDeviceId: 'device-A',
          toDeviceId: 'device-B',
          employeeId: 'emp-1',
        );
      }

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 5);
      expect(hub.getTotalUnreadCount(), 5);
    });
  });

  // ============================================================
  // 本地消息
  // ============================================================
  group('本地消息', () {
    test('本地消息默认不标记未读', () {
      hub.onLocalMessage(
        message: userMsg(id: 'local-1'),
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 0);
    });

    test('本地消息 subscribeMessages 能收到事件', () async {
      final completer = Completer<AgentMessageArrivedEvent>();
      hub.subscribeMessages((event) {
        if (!completer.isCompleted) completer.complete(event);
      });

      hub.onLocalMessage(
        message: userMsg(id: 'local-2'),
        employeeId: 'emp-1',
      );

      final event = await completer.future;
      expect(event.message.id, 'local-2');
      expect(event.isRemote, isFalse);
    });

    test('本地消息设置 markUnread=true 时未读数量增加', () {
      hub.onLocalMessage(
        message: userMsg(id: 'local-3'),
        employeeId: 'emp-1',
        markUnread: true,
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 1);
    });
  });

  // ============================================================
  // 权限请求消息
  // ============================================================
  group('权限请求消息', () {
    test('远程权限请求标记为未读', () {
      hub.onRemoteMessage(
        message: permissionMsg(id: 'perm-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 1);

      final unread = hub.getUnreadMessages(employeeId: 'emp-1');
      expect(unread.length, 1);
      expect(unread.first.message.type, 'permission');
    });

    test('subscribeMessages 能收到权限请求事件', () async {
      final completer = Completer<AgentMessageArrivedEvent>();
      hub.subscribeMessages((event) {
        if (!completer.isCompleted) completer.complete(event);
      });

      hub.onRemoteMessage(
        message: permissionMsg(id: 'perm-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      final event = await completer.future;
      expect(event.message.type, 'permission');
      expect(event.message.status, 'waitingPermission');
    });
  });

  // ============================================================
  // 混合场景：用户发送 + 助手回复 + 权限请求
  // ============================================================
  group('完整会话场景', () {
    test('用户发送消息（本地）+ 助手回复（远程）+ 权限请求（远程）未读数量正确',
        () async {
      final receivedMessages = <AgentMessageArrivedEvent>[];
      final receivedCounts = <AgentUnreadCountChangedEvent>[];
      hub.subscribeMessages(receivedMessages.add);
      hub.subscribeUnreadCount(receivedCounts.add);

      // 1. 用户发送消息（本地，不标记未读）
      hub.onLocalMessage(
        message: userMsg(id: 'u-1', content: '帮我查一下天气'),
        employeeId: 'emp-1',
      );

      // 2. 助手回复（远程，标记未读）
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1', content: '今天天气晴朗'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      // 3. 助手请求权限（远程，标记未读）
      hub.onRemoteMessage(
        message: permissionMsg(id: 'p-1', content: '需要访问日历'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      // 等待微任务队列，让 Stream 事件投递完成
      await pumpEventQueue();

      // 验证消息接收
      expect(receivedMessages.length, 3);
      expect(receivedMessages[0].message.role, 'user');
      expect(receivedMessages[1].message.role, 'assistant');
      expect(receivedMessages[2].message.type, 'permission');

      // 验证未读数量：本地用户消息不计未读，远程助手回复+权限请求各计1
      expect(hub.getUnreadCount(employeeId: 'emp-1'), 2);
      expect(hub.getTotalUnreadCount(), 2);

      // 验证未读计数事件
      final countEvents =
          receivedCounts.where((e) => e.fromDeviceId == null).toList();
      expect(countEvents.last.unreadCount, 2);
    });

    test('用户和助手来回多轮对话后未读数量正确', () {
      // 用户第1条（本地）
      hub.onLocalMessage(
        message: userMsg(id: 'u-1'),
        employeeId: 'emp-1',
      );
      // 助手回复1（远程）
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      // 用户第2条（本地）
      hub.onLocalMessage(
        message: userMsg(id: 'u-2'),
        employeeId: 'emp-1',
      );
      // 助手回复2（远程）
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      // 助手回复3 + 权限请求（远程）
      hub.onRemoteMessage(
        message: permissionMsg(id: 'p-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      // 用户消息不计未读，3条远程消息各计1
      expect(hub.getUnreadCount(employeeId: 'emp-1'), 3);
    });
  });

  // ============================================================
  // 多设备场景
  // ============================================================
  group('多设备未读计数', () {
    test('来自不同设备的消息按设备分别计数', () {
      // device-A 发来2条
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      // device-C 发来1条
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-3'),
        fromDeviceId: 'device-C',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 3);
      expect(
          hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-A'), 2);
      expect(
          hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-C'), 1);
    });

    test('按设备标记已读后，其他设备未读不受影响', () {
      // device-A: 2条, device-C: 1条
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-3'),
        fromDeviceId: 'device-C',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      // 标记 device-A 的消息已读
      hub.markAllAsRead(employeeId: 'emp-1', fromDeviceId: 'device-A');

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 1);
      expect(
          hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-A'), 0);
      expect(
          hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-C'), 1);
    });
  });

  // ============================================================
  // 标记已读
  // ============================================================
  group('标记已读', () {
    test('markAsRead 单条消息后未读数量减1', () {
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 2);

      final changed = hub.markAsRead(messageId: 'a-1', employeeId: 'emp-1');
      expect(changed, isTrue);
      expect(hub.getUnreadCount(employeeId: 'emp-1'), 1);
      expect(hub.isMessageRead(messageId: 'a-1', employeeId: 'emp-1'), isTrue);
      expect(hub.isMessageRead(messageId: 'a-2', employeeId: 'emp-1'), isFalse);
    });

    test('markAllAsRead 后未读数量归零', () async {
      final countEvents = <AgentUnreadCountChangedEvent>[];
      hub.subscribeUnreadCount(countEvents.add, employeeId: 'emp-1');

      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: permissionMsg(id: 'p-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 2);

      hub.markAllAsRead(employeeId: 'emp-1');

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 0);
      expect(hub.getTotalUnreadCount(), 0);

      // 等待微任务队列
      await pumpEventQueue();

      // 验证最终未读计数事件为0
      final lastCount = countEvents
          .where((e) => e.fromDeviceId == null)
          .last
          .unreadCount;
      expect(lastCount, 0);
    });

    test('markAllAsReadGlobal 标记所有员工已读', () {
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-2',
      );

      expect(hub.getTotalUnreadCount(), 2);

      hub.markAllAsReadGlobal();

      expect(hub.getTotalUnreadCount(), 0);
      expect(hub.getUnreadCount(employeeId: 'emp-1'), 0);
      expect(hub.getUnreadCount(employeeId: 'emp-2'), 0);
    });
  });

  // ============================================================
  // 订阅过滤
  // ============================================================
  group('订阅过滤', () {
    test('按 employeeId 过滤消息', () async {
      final emp1Messages = <AgentMessageArrivedEvent>[];
      final emp2Messages = <AgentMessageArrivedEvent>[];

      hub.subscribeMessages(emp1Messages.add, employeeId: 'emp-1');
      hub.subscribeMessages(emp2Messages.add, employeeId: 'emp-2');

      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-2',
      );

      await pumpEventQueue();

      expect(emp1Messages.length, 1);
      expect(emp1Messages.first.message.id, 'a-1');
      expect(emp2Messages.length, 1);
      expect(emp2Messages.first.message.id, 'a-2');
    });

    test('按 fromDeviceId 过滤消息', () async {
      final deviceAMessages = <AgentMessageArrivedEvent>[];

      hub.subscribeMessages(deviceAMessages.add, fromDeviceId: 'device-A');

      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-C',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      await pumpEventQueue();

      expect(deviceAMessages.length, 1);
      expect(deviceAMessages.first.fromDeviceId, 'device-A');
    });
  });

  // ============================================================
  // 消息去重
  // ============================================================
  group('消息去重', () {
    test('相同消息ID不重复计数', () {
      final msg = assistantMsg(id: 'dup-1');

      hub.onRemoteMessage(
        message: msg,
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: msg,
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 1);
    });

    test('本地和远程同一消息ID只处理一次', () {
      final msg = userMsg(id: 'dup-2');

      hub.onLocalMessage(message: msg, employeeId: 'emp-1');
      hub.onRemoteMessage(
        message: msg.copyWith(role: 'assistant'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), 0);
    });
  });

  // ============================================================
  // 未读计数事件流
  // ============================================================
  group('未读计数事件流', () {
    test('subscribeUnreadCount 收到计数变化事件', () async {
      final countEvents = <AgentUnreadCountChangedEvent>[];
      hub.subscribeUnreadCount(countEvents.add, employeeId: 'emp-1');

      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      // 等待微任务队列
      await pumpEventQueue();

      // 每条远程消息触发2个计数事件（总计数 + 按设备计数）
      final totalEvents =
          countEvents.where((e) => e.fromDeviceId == null).toList();
      expect(totalEvents.length, 2);
      expect(totalEvents[0].unreadCount, 1);
      expect(totalEvents[1].unreadCount, 2);

      final deviceEvents =
          countEvents.where((e) => e.fromDeviceId == 'device-A').toList();
      expect(deviceEvents.length, 2);
      expect(deviceEvents[0].unreadCount, 1);
      expect(deviceEvents[1].unreadCount, 2);
    });
  });

  // ============================================================
  // Agent 状态通知
  // ============================================================
  group('Agent 状态通知', () {
    test('onAgentStatusChanged 广播状态事件', () async {
      final events = <AgentNotificationEvent>[];
      hub.subscribe(events.add);

      hub.onAgentStatusChanged(
        employeeId: 'emp-1',
        fromDeviceId: 'device-A',
        status: 'processing',
      );

      await pumpEventQueue();

      expect(events.length, 1);
      final event = events.first as AgentStatusNotifyEvent;
      expect(event.status, 'processing');
      expect(event.employeeId, 'emp-1');
      expect(event.fromDeviceId, 'device-A');
    });
  });

  // ============================================================
  // dispose 后不再接收事件
  // ============================================================
  group('生命周期', () {
    test('dispose 后 onRemoteMessage 不再产生事件', () async {
      final events = <AgentMessageArrivedEvent>[];
      hub.subscribeMessages(events.add);

      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      hub.dispose();

      // 重新创建 hub 以便 tearDown 不报错
      hub = AgentNotificationHub();

      // 等待微任务队列
      await pumpEventQueue();

      expect(events.length, 1);
    });

    test('subscribe 返回的 subscription 可以 cancel', () async {
      final events = <AgentMessageArrivedEvent>[];
      final sub = hub.subscribeMessages(events.add);

      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      await pumpEventQueue();
      expect(events.length, 1);

      sub.cancel();

      hub.onRemoteMessage(
        message: assistantMsg(id: 'a-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      await pumpEventQueue();
      // cancel 后不再接收新事件
      expect(events.length, 1);
    });
  });
}
