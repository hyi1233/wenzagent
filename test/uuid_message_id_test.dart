import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('UUID Message ID Tests', () {
    late MockMessageStoreService mockMessageStore;
    late AgentProxy remoteProxy;
    late CachedAgentProxy cachedProxy;
    late List<AgentMessage> remoteMessages;
    List<String> sentMessageIds = []; // 记录发送的消息ID

    setUp(() async {
      // 初始化 Hive（提供测试路径）
      await HiveManager.instance.initialize(storagePath: 'test_hive');

      // 创建 Mock MessageStore
      mockMessageStore = MockMessageStoreService();

      // 准备远程消息列表（用于模拟 RPC 返回）
      remoteMessages = [];
      sentMessageIds.clear();

      // 创建远程模式的 AgentProxy
      remoteProxy = AgentProxy.remote(
        employeeId: 'test-employee-001',
        deviceId: 'test-device-001',
        rpcCall: (method, params) async {
          // 模拟 sendMessage RPC 调用
          if (method == 'agentSendMessage') {
            // ✅ 关键：获取客户端发送的消息ID
            final messageData = params['messageData'] as Map<String, dynamic>?;
            final clientMessageId = messageData?['id'] as String?;
            
            if (clientMessageId != null) {
              sentMessageIds.add(clientMessageId);
              print('📤 sendMessage 收到客户端ID: $clientMessageId');
              
              // ✅ 远程服务器应该使用客户端提供的ID
              // 这里我们正确地返回客户端的ID
              return {'messageId': clientMessageId};
            } else {
              // 如果客户端没有提供ID（不应该发生）
              print('⚠️ sendMessage 没有收到客户端ID');
              return {'messageId': 'fallback-id-${DateTime.now().millisecondsSinceEpoch}'};
            }
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

    test('测试1: 客户端生成UUID，远程使用相同ID - 无重复消息', () async {
      final now = DateTime.now();

      // 步骤1: 用户发送消息（客户端自动生成UUID）
      print('\n=== 步骤1: 用户发送消息（客户端生成UUID）===');
      final messageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '用户消息内容',
          type: 'text',
          createdAt: now,
        ),
      );
      print('✅ 客户端生成的消息ID: $messageId');
      expect(messageId, isNotEmpty);
      expect(sentMessageIds, contains(messageId));

      // 步骤2: 查看本地缓存
      print('\n=== 步骤2: 查看本地缓存 ===');
      var messages = await cachedProxy.getMessages(forceRefresh: false);
      print('本地缓存消息数: ${messages.length}');
      for (var msg in messages) {
        print('  - ID: ${msg.id}, Content: ${msg.content}');
      }
      expect(messages.length, equals(1));
      expect(messages[0].id, equals(messageId));

      // 步骤3: 远程返回消息（使用相同的UUID）
      print('\n=== 步骤3: 远程返回消息（使用相同的UUID）===');
      remoteMessages = [
        AgentMessage(
          id: messageId, // ✅ 使用客户端生成的UUID
          role: 'user',
          type: 'text',
          content: '用户消息内容',
          createdAt: now,
          status: 'completed',
        ),
      ];
      print('✅ 远程使用相同的ID: $messageId');

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

      // ✅ 验证：应该只有1条消息（正确去重）
      expect(messages.length, equals(1), reason: 'ID相同，正确去重');
      expect(messages[0].id, equals(messageId));
      expect(messages[0].status, equals('completed'));
    });

    test('测试2: 多条消息，每条都有唯一的UUID', () async {
      final now = DateTime.now();

      // 发送3条消息
      print('\n=== 发送3条消息 ===');
      final id1 = await cachedProxy.sendMessage(
        MessageInput(content: '消息1', type: 'text', createdAt: now),
      );
      print('消息1 ID: $id1');

      final id2 = await cachedProxy.sendMessage(
        MessageInput(content: '消息2', type: 'text', createdAt: now.add(Duration(seconds: 1))),
      );
      print('消息2 ID: $id2');

      final id3 = await cachedProxy.sendMessage(
        MessageInput(content: '消息3', type: 'text', createdAt: now.add(Duration(seconds: 2))),
      );
      print('消息3 ID: $id3');

      // 验证每个ID都是唯一的
      expect(id1, isNot(equals(id2)));
      expect(id2, isNot(equals(id3)));
      expect(id1, isNot(equals(id3)));

      // 远程返回这3条消息
      remoteMessages = [
        AgentMessage(id: id1, role: 'user', type: 'text', content: '消息1', createdAt: now, status: 'completed'),
        AgentMessage(id: id2, role: 'user', type: 'text', content: '消息2', createdAt: now.add(Duration(seconds: 1)), status: 'completed'),
        AgentMessage(id: id3, role: 'user', type: 'text', content: '消息3', createdAt: now.add(Duration(seconds: 2)), status: 'completed'),
      ];

      await cachedProxy.syncWithRemote();
      final messages = await cachedProxy.getMessages(forceRefresh: false);

      // 验证：应该有3条消息
      expect(messages.length, equals(3));
      expect(messages[0].id, equals(id1));
      expect(messages[1].id, equals(id2));
      expect(messages[2].id, equals(id3));
    });

    test('测试3: 提供自定义ID，使用提供的ID', () async {
      final now = DateTime.now();
      final customId = 'custom-message-id-12345';

      // 发送消息时提供自定义ID
      print('\n=== 发送消息时提供自定义ID ===');
      final messageId = await cachedProxy.sendMessage(
        MessageInput(
          id: customId,
          content: '自定义ID的消息',
          type: 'text',
          createdAt: now,
        ),
      );

      print('返回的消息ID: $messageId');
      expect(messageId, equals(customId), reason: '应该使用提供的自定义ID');

      // 远程返回消息
      remoteMessages = [
        AgentMessage(
          id: customId,
          role: 'user',
          type: 'text',
          content: '自定义ID的消息',
          createdAt: now,
          status: 'completed',
        ),
      ];

      await cachedProxy.syncWithRemote();
      final messages = await cachedProxy.getMessages(forceRefresh: false);

      expect(messages.length, equals(1));
      expect(messages[0].id, equals(customId));
    });

    test('测试4: 模拟远程返回不同ID的情况（应该忽略远程ID）', () async {
      final now = DateTime.now();

      // 创建一个特殊的proxy，远程会返回不同的ID
      late AgentProxy badRemoteProxy;
      badRemoteProxy = AgentProxy.remote(
        employeeId: 'test-employee-002',
        deviceId: 'test-device-002',
        rpcCall: (method, params) async {
          if (method == 'agentSendMessage') {
            final messageData = params['messageData'] as Map<String, dynamic>?;
            final clientMessageId = messageData?['id'] as String?;
            print('📤 客户端ID: $clientMessageId');
            
            // ⚠️ 模拟远程返回不同的ID（错误行为）
            final wrongId = 'wrong-remote-id-${DateTime.now().millisecondsSinceEpoch}';
            print('⚠️ 远程错误地返回: $wrongId (应该返回: $clientMessageId)');
            return {'messageId': wrongId};
          }
          if (method == 'agentGetSessionMessages') {
            return {'messages': remoteMessages.map((m) => m.toMap()).toList()};
          }
          return {};
        },
      );

      final badCachedProxy = CachedAgentProxy(
        proxy: badRemoteProxy,
        messageStore: mockMessageStore,
        deviceId: 'test-device-002',
        employeeId: 'test-employee-002',
      );

      await badCachedProxy.initialize();

      // 发送消息
      final messageId = await badCachedProxy.sendMessage(
        MessageInput(content: '测试消息', type: 'text', createdAt: now),
      );
      print('✅ 客户端使用的ID: $messageId');

      // 远程返回正确的ID
      remoteMessages = [
        AgentMessage(
          id: messageId,
          role: 'user',
          type: 'text',
          content: '测试消息',
          createdAt: now,
          status: 'completed',
        ),
      ];

      await badCachedProxy.syncWithRemote();
      final messages = await badCachedProxy.getMessages(forceRefresh: false);

      // ✅ 即使远程返回了错误的ID，客户端仍然使用正确的UUID
      expect(messages.length, equals(1));
      expect(messages[0].id, equals(messageId));

      await badCachedProxy.dispose();
      await badRemoteProxy.dispose();
    });

    test('测试5: 完整流程 - 用户消息 + 助手回复', () async {
      final now = DateTime.now();

      // 用户发送消息
      final userMessageId = await cachedProxy.sendMessage(
        MessageInput(content: '你好', type: 'text', createdAt: now),
      );
      print('用户消息ID: $userMessageId');

      // 远程返回用户消息 + 助手回复
      remoteMessages = [
        AgentMessage(
          id: userMessageId,
          role: 'user',
          type: 'text',
          content: '你好',
          createdAt: now,
          status: 'completed',
        ),
        AgentMessage(
          id: 'assistant-reply-001',
          role: 'assistant',
          type: 'text',
          content: '你好！有什么我可以帮助你的吗？',
          createdAt: now.add(Duration(seconds: 1)),
          status: 'completed',
        ),
      ];

      await cachedProxy.syncWithRemote();
      final messages = await cachedProxy.getMessages(forceRefresh: false);

      print('\n消息列表:');
      for (var msg in messages) {
        print('  [${msg.role}] ID: ${msg.id}, Content: ${msg.content}');
      }

      // 验证：2条消息，无重复
      expect(messages.length, equals(2));
      expect(messages[0].id, equals(userMessageId));
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
