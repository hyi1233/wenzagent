import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('Message ID Duplicate Tests', () {
    late MockMessageStoreService mockMessageStore;
    late AgentProxy remoteProxy;
    late CachedAgentProxy cachedProxy;
    late List<AgentMessage> remoteMessages;
    int _localMessageCounter = 0;
    int _remoteMessageCounter = 0;

    setUp(() async {
      // 初始化 Hive（提供测试路径）
      await HiveManager.instance.initialize(storagePath: 'test_hive');

      // 创建 Mock MessageStore
      mockMessageStore = MockMessageStoreService();

      // 准备远程消息列表（用于模拟 RPC 返回）
      remoteMessages = [];

      // 创建远程模式的 AgentProxy
      remoteProxy = AgentProxy.remote(
        employeeId: 'test-employee-001',
        deviceId: 'test-device-001',
        rpcCall: (method, params) async {
          // 模拟 sendMessage RPC 调用
          if (method == 'agentSendMessage') {
            // 返回一个本地的 messageId
            _localMessageCounter++;
            final localMessageId = 'local-msg-$_localMessageCounter';
            print('📤 sendMessage 返回本地ID: $localMessageId');
            return {'messageId': localMessageId};
          }
          // 模拟 getSessionMessages RPC 调用
          if (method == 'agentGetSessionMessages') {
            print('📥 getSessionMessages 返回 ${remoteMessages.length} 条消息');
            for (var msg in remoteMessages) {
              print('  - ID: ${msg.id}, Content: ${msg.content}');
            }
            return {
              'messages': remoteMessages.map((m) => m.toMap()).toList(),
            };
          }
          return {};
        },
      );

      // 创建 CachedAgentProxy
      cachedProxy = CachedAgentProxy(
        proxy: remoteProxy,
        messageStore: mockMessageStore,
        deviceId: 'test-device-001',
        employeeId: 'test-employee-001',
      );

      await cachedProxy.initialize();
    });

    tearDown(() async {
      await cachedProxy.dispose();
      await remoteProxy.dispose();
      await HiveManager.instance.close();
    });

    test('场景1: 用户发送消息后，远程返回不同ID的消息，导致重复', () async {
      final now = DateTime.now();

      // 步骤1: 用户发送消息
      print('\n=== 步骤1: 用户发送消息 ===');
      final localMessageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '用户消息内容',
          type: 'text',
          createdAt: now,
        ),
      );
      print('✅ 本地消息ID: $localMessageId');

      // 步骤2: 查看本地缓存
      print('\n=== 步骤2: 查看本地缓存 ===');
      var messages = await cachedProxy.getMessages(forceRefresh: false);
      print('本地缓存消息数: ${messages.length}');
      for (var msg in messages) {
        print('  - ID: ${msg.id}, Content: ${msg.content}');
      }
      expect(messages.length, equals(1));
      expect(messages[0].id, equals(localMessageId));

      // 步骤3: 远程返回消息，但使用了不同的ID（模拟ID变化的情况）
      print('\n=== 步骤3: 远程返回消息，使用不同的ID ===');
      _remoteMessageCounter++;
      final remoteMessageId = 'remote-msg-$_remoteMessageCounter';
      print('⚠️ 远程消息ID: $remoteMessageId (与本地ID不同!)');
      
      remoteMessages = [
        AgentMessage(
          id: remoteMessageId, // 使用不同的ID！
          role: 'user',
          type: 'text',
          content: '用户消息内容', // 相同的内容
          createdAt: now,
          status: 'completed',
        ),
      ];

      // 步骤4: 同步远程消息
      print('\n=== 步骤4: 同步远程消息 ===');
      await cachedProxy.syncWithRemote();

      // 步骤5: 查看合并后的消息列表
      print('\n=== 步骤5: 查看合并后的消息列表 ===');
      messages = await cachedProxy.getMessages(forceRefresh: false);
      print('合并后消息数: ${messages.length}');
      for (var msg in messages) {
        print('  - ID: ${msg.id}, Content: ${msg.content}');
      }

      // 问题验证：出现了2条消息！
      print('\n⚠️ 问题：消息ID不同，导致出现重复消息！');
      expect(messages.length, equals(2), reason: '因为ID不同，被识别为2条不同的消息');
      expect(messages[0].id, equals(localMessageId));
      expect(messages[1].id, equals(remoteMessageId));
    });

    test('场景2: 正确情况 - 远程返回相同ID的消息，正确去重', () async {
      final now = DateTime.now();

      // 步骤1: 用户发送消息
      print('\n=== 步骤1: 用户发送消息 ===');
      final localMessageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '用户消息内容',
          type: 'text',
          createdAt: now,
        ),
      );
      print('✅ 本地消息ID: $localMessageId');

      // 步骤2: 远程返回消息，使用相同的ID
      print('\n=== 步骤2: 远程返回消息，使用相同的ID ===');
      remoteMessages = [
        AgentMessage(
          id: localMessageId, // 使用相同的ID！
          role: 'user',
          type: 'text',
          content: '用户消息内容',
          createdAt: now,
          status: 'completed',
        ),
      ];
      print('✅ 远程消息ID: $localMessageId (与本地ID相同)');

      // 步骤3: 同步远程消息
      print('\n=== 步骤3: 同步远程消息 ===');
      await cachedProxy.syncWithRemote();

      // 步骤4: 查看合并后的消息列表
      print('\n=== 步骤4: 查看合并后的消息列表 ===');
      final messages = await cachedProxy.getMessages(forceRefresh: false);
      print('合并后消息数: ${messages.length}');
      for (var msg in messages) {
        print('  - ID: ${msg.id}, Content: ${msg.content}');
      }

      // 正确情况：只有1条消息
      print('\n✅ 正确：消息ID相同，正确去重');
      expect(messages.length, equals(1), reason: '因为ID相同，正确去重');
      expect(messages[0].id, equals(localMessageId));
      expect(messages[0].status, equals('completed'), reason: '使用远程消息的状态');
    });

    test('场景3: 多次查询导致的重复问题', () async {
      final now = DateTime.now();

      // 步骤1: 用户发送消息
      print('\n=== 步骤1: 用户发送消息 ===');
      final localMessageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '用户消息',
          type: 'text',
          createdAt: now,
        ),
      );
      print('✅ 本地消息ID: $localMessageId');

      // 步骤2: 第一次查询（使用本地ID）
      print('\n=== 步骤2: 第一次查询 ===');
      var messages = await cachedProxy.getMessages(forceRefresh: false);
      expect(messages.length, equals(1));
      print('第一次查询: ${messages.length} 条消息');

      // 步骤3: 远程第一次返回（使用本地ID）
      print('\n=== 步骤3: 远程第一次返回（使用本地ID） ===');
      remoteMessages = [
        AgentMessage(
          id: localMessageId,
          role: 'user',
          type: 'text',
          content: '用户消息',
          createdAt: now,
          status: 'completed',
        ),
      ];

      await cachedProxy.syncWithRemote();
      messages = await cachedProxy.getMessages(forceRefresh: false);
      expect(messages.length, equals(1));
      print('同步后: ${messages.length} 条消息 ✅');

      // 步骤4: 远程第二次返回（模拟ID变化的情况）
      print('\n=== 步骤4: 远程第二次返回（ID变了!） ===');
      _remoteMessageCounter++;
      final newRemoteId = 'remote-msg-changed-$_remoteMessageCounter';
      print('⚠️ 远程返回新的ID: $newRemoteId');
      
      remoteMessages = [
        AgentMessage(
          id: newRemoteId, // ID变了！
          role: 'user',
          type: 'text',
          content: '用户消息',
          createdAt: now,
          status: 'completed',
        ),
      ];

      await cachedProxy.syncWithRemote();
      messages = await cachedProxy.getMessages(forceRefresh: false);
      
      print('同步后: ${messages.length} 条消息');
      for (var msg in messages) {
        print('  - ID: ${msg.id}, Content: ${msg.content}');
      }

      // 问题：出现重复
      print('\n⚠️ 问题：远程返回了不同的ID，导致重复！');
      expect(messages.length, equals(2), reason: '因为ID变化，出现了重复');
    });

    test('场景4: 助手回复消息不会重复', () async {
      final now = DateTime.now();

      // 步骤1: 用户发送消息
      print('\n=== 步骤1: 用户发送消息 ===');
      final userMessageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '用户问题',
          type: 'text',
          createdAt: now,
        ),
      );
      print('用户消息ID: $userMessageId');

      // 步骤2: 远程返回用户消息 + 助手回复
      print('\n=== 步骤2: 远程返回用户消息 + 助手回复 ===');
      remoteMessages = [
        AgentMessage(
          id: userMessageId,
          role: 'user',
          type: 'text',
          content: '用户问题',
          createdAt: now,
          status: 'completed',
        ),
        AgentMessage(
          id: 'assistant-msg-001',
          role: 'assistant',
          type: 'text',
          content: '助手回复',
          createdAt: now.add(Duration(seconds: 1)),
          status: 'completed',
        ),
      ];

      await cachedProxy.syncWithRemote();
      final messages = await cachedProxy.getMessages(forceRefresh: false);

      print('消息数: ${messages.length}');
      for (var msg in messages) {
        print('  - [${msg.role}] ID: ${msg.id}, Content: ${msg.content}');
      }

      // 正确：2条消息（用户 + 助手）
      expect(messages.length, equals(2));
      expect(messages[0].role, equals('user'));
      expect(messages[1].role, equals('assistant'));
    });
  });
}

/// Mock MessageStoreService
class MockMessageStoreService implements MessageStoreService {
  final List<AiEmployeeMessageEntity> _localMessages = [];
  final _changeController = StreamController<MessageChangeEvent>.broadcast();

  @override
  Future<List<AiEmployeeMessageEntity>> getMessages(
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    return getMessagesWithDeviceId(null, employeeId, limit: limit, offset: offset);
  }

  @override
  Future<List<AiEmployeeMessageEntity>> getMessagesWithDeviceId(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    var messages = _localMessages.where((m) => m.employeeId == employeeId).toList();

    if (offset != null && offset > 0) {
      messages = messages.skip(offset).toList();
    }
    if (limit != null && limit > 0) {
      messages = messages.take(limit).toList();
    }

    return messages;
  }

  @override
  Future<AiEmployeeMessageEntity?> getMessage(String uuid, {String? deviceId}) async {
    try {
      return _localMessages.firstWhere((m) => m.uuid == uuid);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<AiEmployeeMessageEntity> addMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,
  }) async {
    _localMessages.add(message);
    _changeController.add(MessageChangeEvent(
      type: MessageChangeType.added,
      messageUuid: message.uuid,
      employeeId: message.employeeId,
      message: message,
    ));
    return message;
  }

  @override
  Future<void> addMessages(
    List<AiEmployeeMessageEntity> messages, {
    String? deviceId,
  }) async {
    for (final message in messages) {
      await addMessage(message, deviceId: deviceId);
    }
  }

  @override
  Future<void> updateMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,
  }) async {
    final index = _localMessages.indexWhere((m) => m.uuid == message.uuid);
    if (index >= 0) {
      _localMessages[index] = message;
      _changeController.add(MessageChangeEvent(
        type: MessageChangeType.updated,
        messageUuid: message.uuid,
        employeeId: message.employeeId,
        message: message,
      ));
    }
  }

  @override
  Future<void> updateMessageStatus(
    String uuid,
    String status, {
    String? error,
  }) async {
    final message = await getMessage(uuid);
    if (message != null) {
      final updated = message.copyWith(
        processingStatus: status,
        updateTime: DateTime.now(),
      );
      await updateMessage(updated);
    }
  }

  @override
  Future<void> deleteMessages(String employeeId) async {
    _localMessages.removeWhere((m) => m.employeeId == employeeId);
  }

  @override
  Future<AiEmployeeMessageEntity?> getLastMessage(String employeeId) async {
    final messages = _localMessages.where((m) => m.employeeId == employeeId).toList();
    if (messages.isEmpty) return null;
    messages.sort((a, b) => b.createTime.compareTo(a.createTime));
    return messages.first;
  }

  @override
  Stream<MessageChangeEvent> get onMessageChanged => _changeController.stream;

  void dispose() {
    _changeController.close();
  }
}
