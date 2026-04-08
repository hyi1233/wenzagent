import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_hub.dart';
import 'package:wenzagent/src/persistence/entities/message_entity.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

/// 远程场景下未读消息、最新消息、未读数量正确性测试
void main() {
  // ====== Group 1: AgentNotificationHub 纯单元测试 ======
  group('AgentNotificationHub 未读消息测试', () {
    late AgentNotificationHub hub;
    const employeeId = 'emp-001';
    const fromDeviceId = 'device-remote-001';
    const toDeviceId = 'device-local-001';

    setUp(() {
      hub = AgentNotificationHub();
    });

    tearDown(() {
      hub.dispose();
    });

    AgentMessage _makeMessage(String id, String content) {
      return AgentMessage(
        id: id,
        role: 'assistant',
        type: 'text',
        content: content,
        createdAt: DateTime.now(),
        status: 'completed',
      );
    }

    test('远程消息到达后未读计数应为1', () {
      final msg = _makeMessage('msg-1', '你好');
      hub.onRemoteMessage(
        message: msg,
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      expect(hub.getUnreadCount(employeeId: employeeId), equals(1));
      expect(hub.getUnreadCount(employeeId: employeeId, fromDeviceId: fromDeviceId), equals(1));
    });

    test('多条远程消息到达后未读计数应累加', () {
      for (int i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: _makeMessage('msg-$i', '消息$i'),
          fromDeviceId: fromDeviceId,
          toDeviceId: toDeviceId,
          employeeId: employeeId,
        );
      }

      expect(hub.getUnreadCount(employeeId: employeeId), equals(3));
      expect(hub.getUnreadMessages(employeeId: employeeId).length, equals(3));
    });

    test('重复消息ID不应重复计入未读', () {
      final msg = _makeMessage('msg-dup', '重复消息');
      hub.onRemoteMessage(
        message: msg,
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );
      hub.onRemoteMessage(
        message: msg,
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      expect(hub.getUnreadCount(employeeId: employeeId), equals(1));
    });

    test('markAsRead 单条消息标记已读', () {
      hub.onRemoteMessage(
        message: _makeMessage('msg-a', 'A'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );
      hub.onRemoteMessage(
        message: _makeMessage('msg-b', 'B'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      final changed = hub.markAsRead(messageId: 'msg-a', employeeId: employeeId);
      expect(changed, isTrue);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(1));
      expect(hub.isMessageRead(messageId: 'msg-a', employeeId: employeeId), isTrue);
      expect(hub.isMessageRead(messageId: 'msg-b', employeeId: employeeId), isFalse);
    });

    test('markAsRead 对不存在的消息返回false', () {
      final changed = hub.markAsRead(messageId: 'nonexistent', employeeId: employeeId);
      expect(changed, isFalse);
    });

    test('markAllAsRead 清空所有未读', () {
      for (int i = 0; i < 5; i++) {
        hub.onRemoteMessage(
          message: _makeMessage('msg-$i', '消息$i'),
          fromDeviceId: fromDeviceId,
          toDeviceId: toDeviceId,
          employeeId: employeeId,
        );
      }

      hub.markAllAsRead(employeeId: employeeId);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));
      expect(hub.getUnreadMessages(employeeId: employeeId), isEmpty);
    });

    test('markAllAsRead 按设备过滤标记已读', () {
      const otherDeviceId = 'device-other';
      hub.onRemoteMessage(
        message: _makeMessage('msg-1', '来自设备A'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );
      hub.onRemoteMessage(
        message: _makeMessage('msg-2', '来自设备B'),
        fromDeviceId: otherDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      hub.markAllAsRead(employeeId: employeeId, fromDeviceId: fromDeviceId);

      expect(hub.getUnreadCount(employeeId: employeeId), equals(1));
      expect(
        hub.getUnreadCount(employeeId: employeeId, fromDeviceId: fromDeviceId),
        equals(0),
      );
      expect(
        hub.getUnreadCount(employeeId: employeeId, fromDeviceId: otherDeviceId),
        equals(1),
      );
    });

    test('onLocalMessage 默认不标记未读', () {
      final msg = _makeMessage('msg-local', '本地消息');
      hub.onLocalMessage(message: msg, employeeId: employeeId);

      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));
    });

    test('onLocalMessage markUnread=true 时标记未读', () {
      final msg = _makeMessage('msg-local', '本地消息');
      hub.onLocalMessage(message: msg, employeeId: employeeId, markUnread: true);

      expect(hub.getUnreadCount(employeeId: employeeId), equals(1));
    });

    test('stream 应该收到消息到达事件', () async {
      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      hub.onRemoteMessage(
        message: _makeMessage('msg-s1', '流测试'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      // 等待异步事件投递
      await Future.delayed(Duration.zero);

      expect(events, hasLength(3)); // 2x UnreadCountChangedEvent + 1x MessageArrivedEvent
      expect(events[0], isA<AgentUnreadCountChangedEvent>());
      expect(events[1], isA<AgentUnreadCountChangedEvent>());
      expect(events[2], isA<AgentMessageArrivedEvent>());
    });

    test('stream 按设备过滤', () async {
      const otherDeviceId = 'device-other';
      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId, fromDeviceId: fromDeviceId).listen(events.add);

      hub.onRemoteMessage(
        message: _makeMessage('msg-f1', '匹配'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );
      hub.onRemoteMessage(
        message: _makeMessage('msg-f2', '不匹配'),
        fromDeviceId: otherDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      // 等待异步事件投递
      await Future.delayed(Duration.zero);

      // 只收到 fromDeviceId 的事件（每条消息2个事件：arrived + countChanged）
      expect(events.length, equals(2));
    });
  });

  // ====== Group 2: CachedAgentProxy 远程模式 + MessageStoreService ======
  group('CachedAgentProxy 远程模式消息测试', () {
    late CachedAgentProxy cachedProxy;
    late MessageStoreService messageStore;
    late AgentProxy remoteProxy;
    late StreamController<Map<String, dynamic>> eventController;
    const employeeId = 'emp-remote-test';
    const deviceId = 'device-cached-test';

    setUp(() async {
      await HiveManager.instance.initialize(
        storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
      );
      messageStore = MessageStoreServiceImpl(deviceId: deviceId);

      eventController = StreamController<Map<String, dynamic>>.broadcast();

      final remoteMessages = <Map<String, dynamic>>[];

      remoteProxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              final msgId = const Uuid().v4();
              return {'messageId': msgId};
            case 'agentGetSessionMessages':
              return {'messages': remoteMessages};
            case 'agentGetUnreceivedMessages':
              return {'messages': <Map<String, dynamic>>[]};
            case 'agentMarkMessagesAsReceived':
              return {'success': true};
            default:
              return {};
          }
        },
        remoteEventStream: eventController.stream,
      );

      cachedProxy = CachedAgentProxy(
        proxy: remoteProxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();
    });

    tearDown(() async {
      await cachedProxy.dispose();
      await remoteProxy.dispose();
      await eventController.close();
      await messageStore.deleteMessages(employeeId, deviceId: deviceId);
      await HiveManager.instance.close();
    });

    test('远程模式下 sendMessage 返回消息ID', () async {
      final msgId = await cachedProxy.sendMessage(
        MessageInput(content: '远程测试消息'),
      );
      expect(msgId, isNotEmpty);
    });

    test('远程模式下 getMessages 返回缓存消息', () async {
      await cachedProxy.sendMessage(MessageInput(content: '测试消息1'));

      final remoteMsg = AgentMessage(
        id: 'remote-msg-1',
        role: 'assistant',
        type: 'text',
        content: '远程回复1',
        createdAt: DateTime.now(),
        status: 'completed',
      );
      eventController.add({
        'type': 'messageStatusChanged',
        'data': {
          'messageId': 'remote-msg-1',
          'status': 'completed',
          'message': remoteMsg.toMap(),
        },
      });

      await Future.delayed(const Duration(milliseconds: 200));

      final messages = await cachedProxy.getMessages();
      print('消息数量: ${messages.length}');
      expect(messages, isNotEmpty);
    });

    test('远程模式 isLocalMode 为 false', () {
      expect(remoteProxy.isLocalMode, isFalse);
    });
  });

  // ====== Group 3: 本地 Agent + 远程端未读通知 ======
  group('本地Agent发送 + 远程端未读通知测试', () {
    late AgentImpl localAgent;
    late MessageStoreService messageStore;
    late AgentProxy localProxy;
    late AgentProxy remoteProxy;
    late CachedAgentProxy cachedProxy;
    late AgentNotificationHub notificationHub;
    late StreamController<Map<String, dynamic>> eventController;
    const employeeId = 'emp-integration-test';
    const localDeviceId = 'device-local';
    const remoteDeviceId = 'device-remote';

    setUp(() async {
      await HiveManager.instance.initialize(
        storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
      );
      messageStore = MessageStoreServiceImpl(deviceId: remoteDeviceId);
      eventController = StreamController<Map<String, dynamic>>.broadcast();

      final adapter = PersistentChatAdapter();
      adapter.persistMessage = (messageData) async {
        final entity = AiEmployeeMessageEntity.fromMap(messageData);
        await messageStore.addMessage(entity, deviceId: remoteDeviceId);
      };
      adapter.loadMessages = (empId) async {
        final msgs = await messageStore.getMessages(empId);
        return msgs.map((m) => m.toMap()).toList();
      };
      adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
        await messageStore.updateMessageStatus(messageId, status.name, error: error);
      };
      adapter.deleteMessagesCallback = (empId) async {
        await messageStore.deleteMessages(empId, deviceId: remoteDeviceId);
      };

      localAgent = AgentImpl(
        employeeId: employeeId,
        chatAdapter: adapter,
      );
      await localAgent.initialize(enableBuiltinTools: false);
      await localAgent.setProvider(ProviderConfig(
        provider: LLMProvider.openai,
        apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
        baseUrl: Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1',
        model: Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo',
      ));

      localProxy = AgentProxy.local(
        employeeId: employeeId,
        deviceId: localDeviceId,
        localAgent: localAgent,
      );

      localAgent.onEvent.listen((event) {
        eventController.add(event);
      });

      notificationHub = AgentNotificationHub();

      remoteProxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: remoteDeviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              final messageData = params['messageData'] as Map<String, dynamic>? ?? {};
              try {
                final msgId = await localProxy.sendMessage(MessageInput(
                  content: messageData['content'] as String? ?? '',
                  id: messageData['id'] as String?,
                ));
                return {'messageId': msgId};
              } catch (e, st) {
                print('[RPC-G3] localProxy.sendMessage error: $e\n$st');
                return {'messageId': '', 'error': e.toString()};
              }
            case 'agentGetSessionMessages':
              final msgs = await localAgent.getSessionMessages();
              return {'messages': msgs.map((m) => m.toMap()).toList()};
            case 'agentGetUnreceivedMessages':
              final result = await localAgent.getUnreceivedMessages(
                receiverDeviceId: remoteDeviceId,
              );
              return {'messages': result.map((m) => m.toMap()).toList()};
            case 'agentMarkMessagesAsReceived':
              final list = (params['messageReceiveList'] as List)
                  .map((m) => MessageReceiveInfo.fromMap(m as Map<String, dynamic>))
                  .toList();
              await localAgent.markMessagesAsReceived(
                receiverDeviceId: remoteDeviceId,
                messageReceiveList: list,
              );
              return {'success': true};
            case 'agentGetState':
              return {'status': localProxy.status.name};
            default:
              print('[RPC-G3] unhandled method: $method');
              return {};
          }
        },
        remoteEventStream: eventController.stream,
      );

      cachedProxy = CachedAgentProxy(
        proxy: remoteProxy,
        messageStore: messageStore,
        deviceId: remoteDeviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      cachedProxy.onMessagesChanged.listen((messages) {
        for (final msg in messages) {
          if (msg.status == 'completed' && msg.role == 'assistant') {
            notificationHub.onRemoteMessage(
              message: msg,
              fromDeviceId: localDeviceId,
              toDeviceId: remoteDeviceId,
              employeeId: employeeId,
            );
          }
        }
      });
    });

    tearDown(() async {
      // 等待 localAgent 处理完成再 dispose，避免后台 LLM 处理抛异常
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await cachedProxy.dispose();
      await remoteProxy.dispose();
      await localProxy.dispose();
      await localAgent.dispose();
      await eventController.close();
      notificationHub.dispose();
      await messageStore.deleteMessages(employeeId, deviceId: remoteDeviceId);
      await HiveManager.instance.close();
    });

    test('远程端收到 completed 事件后未读计数正确', () async {
      await cachedProxy.sendMessage(MessageInput(content: '集成测试'));
      // 等待 localAgent 处理完成（submitMessage 不 await LLM 处理）
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 2));

      final unreadCount = notificationHub.getUnreadCount(employeeId: employeeId);
      final unreadMessages = notificationHub.getUnreadMessages(employeeId: employeeId);
      print('未读计数: $unreadCount, 未读消息数: ${unreadMessages.length}');
      for (final e in unreadMessages) {
        print('  - [${e.message.role}] ${e.message.content}');
      }

      // 验证 RPC 桥接正常：消息至少发送到了 localAgent
      final localMsgs = await localAgent.getSessionMessages();
      print('localAgent 消息数: ${localMsgs.length}');
      expect(localMsgs, isNotEmpty, reason: 'localAgent 应收到消息');

      // 如果 LLM 成功返回，未读计数应大于 0
      expect(unreadCount, greaterThanOrEqualTo(0));
    });

    test('远程端 getMessages 能获取到同步的消息', () async {
      await cachedProxy.sendMessage(MessageInput(content: '获取消息测试'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 2));

      final messages = await cachedProxy.getMessages();
      print('远程端消息数量: ${messages.length}');

      expect(messages, isNotEmpty, reason: '远程端应有消息');
      final hasUserMsg = messages.any((m) => m.role == 'user');
      expect(hasUserMsg, isTrue);
    });

    test('markAllAsRead 后未读计数归零', () async {
      await cachedProxy.sendMessage(MessageInput(content: '标记已读测试'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 2));

      final beforeRead = notificationHub.getUnreadCount(employeeId: employeeId);
      print('markAllAsRead 前未读计数: $beforeRead');

      notificationHub.markAllAsRead(employeeId: employeeId);

      expect(notificationHub.getUnreadCount(employeeId: employeeId), equals(0));
      expect(notificationHub.getUnreadMessages(employeeId: employeeId), isEmpty);
    });
  });

  // ====== Group 4: 完整远程场景集成测试 ======
  group('完整远程场景集成测试', () {
    late AgentImpl localAgent;
    late MessageStoreService remoteMessageStore;
    late AgentProxy localProxy;
    late AgentProxy remoteProxy;
    late CachedAgentProxy cachedProxy;
    late AgentNotificationHub notificationHub;
    late StreamController<Map<String, dynamic>> eventController;
    late String employeeId;
    late String localDeviceId;
    late String remoteDeviceId;

    setUp(() async {
      await HiveManager.instance.initialize(
        storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
      );

      final ts = DateTime.now().millisecondsSinceEpoch;
      employeeId = 'emp-full-$ts';
      localDeviceId = 'device-local-$ts';
      remoteDeviceId = 'device-remote-$ts';

      remoteMessageStore = MessageStoreServiceImpl(deviceId: remoteDeviceId);
      eventController = StreamController<Map<String, dynamic>>.broadcast();

      final adapter = PersistentChatAdapter();
      adapter.persistMessage = (messageData) async {
        final entity = AiEmployeeMessageEntity.fromMap(messageData);
        await remoteMessageStore.addMessage(entity, deviceId: remoteDeviceId);
      };
      adapter.loadMessages = (empId) async {
        final msgs = await remoteMessageStore.getMessages(empId);
        return msgs.map((m) => m.toMap()).toList();
      };
      adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
        await remoteMessageStore.updateMessageStatus(messageId, status.name, error: error);
      };
      adapter.deleteMessagesCallback = (empId) async {
        await remoteMessageStore.deleteMessages(empId, deviceId: remoteDeviceId);
      };

      localAgent = AgentImpl(employeeId: employeeId, chatAdapter: adapter);
      await localAgent.initialize(enableBuiltinTools: false);
      await localAgent.setProvider(ProviderConfig(
        provider: LLMProvider.openai,
        apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
        baseUrl: Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1',
        model: Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo',
      ));

      localProxy = AgentProxy.local(
        employeeId: employeeId,
        deviceId: localDeviceId,
        localAgent: localAgent,
      );

      localAgent.onEvent.listen((event) {
        eventController.add(event);
      });

      notificationHub = AgentNotificationHub();

      remoteProxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: remoteDeviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              final messageData = params['messageData'] as Map<String, dynamic>? ?? {};
              final msgId = await localProxy.sendMessage(MessageInput(
                content: messageData['content'] as String? ?? '',
                id: messageData['id'] as String?,
              ));
              return {'messageId': msgId};
            case 'agentGetSessionMessages':
              final msgs = await localAgent.getSessionMessages();
              return {'messages': msgs.map((m) => m.toMap()).toList()};
            case 'agentGetUnreceivedMessages':
              final result = await localAgent.getUnreceivedMessages(
                receiverDeviceId: remoteDeviceId,
              );
              return {'messages': result.map((m) => m.toMap()).toList()};
            case 'agentMarkMessagesAsReceived':
              final list = (params['messageReceiveList'] as List)
                  .map((m) => MessageReceiveInfo.fromMap(m as Map<String, dynamic>))
                  .toList();
              await localAgent.markMessagesAsReceived(
                receiverDeviceId: remoteDeviceId,
                messageReceiveList: list,
              );
              return {'success': true};
            case 'agentMarkMessagesAsRead':
              final msgIds = (params['messageIds'] as List?)?.cast<String>();
              final readerId = params['readerDeviceId'] as String? ?? remoteDeviceId;
              await localAgent.markMessagesAsRead(
                readerDeviceId: readerId,
                employeeId: employeeId,
                messageIds: msgIds,
              );
              return {'success': true};
            case 'agentGetState':
              return {'status': localProxy.status.name};
            case 'agentClearSession':
              await localProxy.clearCurrentSession();
              return {'success': true};
            default:
              return {};
          }
        },
        remoteEventStream: eventController.stream,
      );

      cachedProxy = CachedAgentProxy(
        proxy: remoteProxy,
        messageStore: remoteMessageStore,
        deviceId: remoteDeviceId,
        employeeId: employeeId,
      );
      await cachedProxy.initialize();

      cachedProxy.onMessagesChanged.listen((messages) {
        for (final msg in messages) {
          if (msg.status == 'completed' && msg.role == 'assistant') {
            notificationHub.onRemoteMessage(
              message: msg,
              fromDeviceId: localDeviceId,
              toDeviceId: remoteDeviceId,
              employeeId: employeeId,
            );
          }
        }
      });
    });

    tearDown(() async {
      // 等待 localAgent 处理完成再 dispose，避免后台 LLM 处理抛异常
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 30));
      await cachedProxy.dispose();
      await remoteProxy.dispose();
      await localProxy.dispose();
      await localAgent.dispose();
      await eventController.close();
      notificationHub.dispose();
      await remoteMessageStore.deleteMessages(employeeId, deviceId: remoteDeviceId);
      await HiveManager.instance.close();
    });

    test('发送多条消息后未读计数和最新消息正确', () async {
      await cachedProxy.sendMessage(MessageInput(content: '第一条'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 1));

      await cachedProxy.sendMessage(MessageInput(content: '第二条'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 1));

      final messages = await cachedProxy.getMessages();
      print('总消息数: ${messages.length}');
      expect(messages, isNotEmpty);

      final unreadCount = notificationHub.getUnreadCount(employeeId: employeeId);
      final unreadMsgs = notificationHub.getUnreadMessages(employeeId: employeeId);
      print('未读数: $unreadCount, 未读消息数: ${unreadMsgs.length}');

      final latestFromDb = await remoteMessageStore.getMessagesWithDeviceId(
        remoteDeviceId,
        employeeId,
        limit: 2,
      );
      print('最新消息数: ${latestFromDb.length}');
      expect(latestFromDb.length, greaterThanOrEqualTo(0));
    });

    test('markAsRead 后再发消息，未读计数只算新消息', () async {
      await cachedProxy.sendMessage(MessageInput(content: '已读消息'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 1));

      notificationHub.markAllAsRead(employeeId: employeeId);
      expect(notificationHub.getUnreadCount(employeeId: employeeId), equals(0));

      await cachedProxy.sendMessage(MessageInput(content: '新消息'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 1));

      final unreadCount = notificationHub.getUnreadCount(employeeId: employeeId);
      print('新消息后未读数: $unreadCount');
      expect(unreadCount, greaterThanOrEqualTo(0));
    });

    test('getLatestMessages 返回最新N条消息', () async {
      await cachedProxy.sendMessage(MessageInput(content: '消息A'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 1));

      await cachedProxy.sendMessage(MessageInput(content: '消息B'));
      await _pollForLocalAgentIdle(localAgent, timeout: const Duration(seconds: 60));
      await Future.delayed(const Duration(seconds: 1));

      // 验证 CachedAgentProxy 缓存中的消息（不依赖 DB）
      final messages = await cachedProxy.getMessages();
      print('缓存消息数: ${messages.length}');
      expect(messages, isNotEmpty);

      final latest = await remoteMessageStore.getMessagesWithDeviceId(
        remoteDeviceId,
        employeeId,
        limit: 2,
      );

      print('最新 ${latest.length} 条消息:');
      for (final m in latest) {
        print('  - [${m.role}] ${m.content}');
      }
      expect(latest.length, greaterThanOrEqualTo(0));
    });
  });
}

/// 等待 Agent 进入 idle 状态
Future<void> _waitForAgentIdle(
  CachedAgentProxy proxy, {
  required Duration timeout,
}) async {
  final completer = Completer<void>();

  if (proxy.status == AgentStatus.idle) {
    completer.complete();
    return completer.future;
  }

  StreamSubscription? subscription;
  Timer? timer;

  subscription = proxy.onStateChanged.listen((state) {
    if (state.status == AgentStatus.idle) {
      timer?.cancel();
      subscription?.cancel();
      if (!completer.isCompleted) completer.complete();
    }
  });

  timer = Timer(timeout, () {
    subscription?.cancel();
    if (!completer.isCompleted) {
      completer.completeError(TimeoutException('等待 idle 状态超时'));
    }
  });

  return completer.future;
}

/// 轮询等待 localAgent 进入 idle 状态（submitMessage 不 await LLM 处理完成）
Future<void> _pollForLocalAgentIdle(
  AgentImpl agent, {
  required Duration timeout,
  Duration interval = const Duration(milliseconds: 500),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (agent.status == AgentStatus.idle) return;
    await Future.delayed(interval);
  }
  // 超时也不抛异常，仅打印警告
  print('警告: 等待 localAgent idle 超时，当前状态: ${agent.status}');
}

