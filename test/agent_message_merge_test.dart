import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('Agent Message Merge Tests', () {
    late MockMessageStoreService mockMessageStore;
    late AgentProxy remoteProxy;
    late CachedAgentProxy cachedProxy;
    late List<AgentMessage> remoteMessages;
    int _messageCounter = 0;

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
            // 返回一个唯一的 messageId
            _messageCounter++;
            return {'messageId': 'local-msg-$_messageCounter'};
          }
          // 模拟 getSessionMessages RPC 调用
          if (method == 'agentGetSessionMessages') {
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

    test('测试1: 根据 ID 去重 - 远程消息覆盖本地消息', () async {
      final now = DateTime.now();

      // 添加本地消息到缓存
      final localMessageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '本地消息内容',
          type: 'text',
          createdAt: now,
        ),
      );

      // 准备远程消息（相同 ID，不同内容）
      remoteMessages = [
        AgentMessage(
          id: localMessageId,
          role: 'user',
          type: 'text',
          content: '远程消息内容',
          createdAt: now.add(Duration(seconds: 1)),
          status: 'completed',
        ),
      ];

      // 同步
      await cachedProxy.syncWithRemote();

      // 验证：应该只有一条消息，且使用远程版本
      final messages = await cachedProxy.getMessages();
      expect(messages.length, equals(1));
      expect(messages[0].id, equals(localMessageId));
      expect(messages[0].content, equals('远程消息内容'));
      expect(messages[0].status, equals('completed'));
    });

    test('测试2: 根据 ID 去重 - 保留待同步的本地消息', () async {
      final now = DateTime.now();

      // 添加本地待同步消息
      final localMessageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '待同步的本地消息',
          type: 'text',
          createdAt: now,
          metadata: {'localOnly': true},
        ),
      );

      // 准备远程消息（相同 ID，但本地标记为 localOnly）
      remoteMessages = [
        AgentMessage(
          id: localMessageId,
          role: 'user',
          type: 'text',
          content: '远程消息',
          createdAt: now.add(Duration(seconds: 1)),
          status: 'completed',
        ),
      ];

      await cachedProxy.syncWithRemote();

      // 验证：应该保留本地待同步消息
      final messages = await cachedProxy.getMessages();
      expect(messages.length, equals(1));
      expect(messages[0].id, equals(localMessageId));
      expect(messages[0].content, equals('待同步的本地消息'));
      expect(messages[0].metadata?['localOnly'], isTrue);
    });

    test('测试3: 合并不同 ID 的消息', () async {
      final now = DateTime.now();

      // 添加本地消息
      final localMessageId = await cachedProxy.sendMessage(
        MessageInput(
          content: '本地消息',
          type: 'text',
          createdAt: now,
        ),
      );

      // 准备远程消息（不同 ID）
      remoteMessages = [
        AgentMessage(
          id: 'msg-remote-001',
          role: 'assistant',
          type: 'text',
          content: '远程消息1',
          createdAt: now.add(Duration(seconds: 1)),
        ),
        AgentMessage(
          id: 'msg-remote-002',
          role: 'assistant',
          type: 'text',
          content: '远程消息2',
          createdAt: now.add(Duration(seconds: 2)),
        ),
      ];

      await cachedProxy.syncWithRemote();

      // 验证：应该有3条消息
      final messages = await cachedProxy.getMessages();
      expect(messages.length, equals(3));

      // 验证排序（按时间）
      expect(messages[0].id, equals(localMessageId));
      expect(messages[1].id, equals('msg-remote-001'));
      expect(messages[2].id, equals('msg-remote-002'));
    });

    test('测试4: 按时间排序 - 时间戳乱序', () async {
      final now = DateTime.now();

      // 准备远程返回乱序消息
      remoteMessages = [
        AgentMessage(
          id: 'msg-003',
          role: 'user',
          type: 'text',
          content: '消息3（时间最新）',
          createdAt: now.add(Duration(seconds: 2)),
        ),
        AgentMessage(
          id: 'msg-001',
          role: 'user',
          type: 'text',
          content: '消息1（时间最早）',
          createdAt: now,
        ),
        AgentMessage(
          id: 'msg-002',
          role: 'user',
          type: 'text',
          content: '消息2（时间中间）',
          createdAt: now.add(Duration(seconds: 1)),
        ),
      ];

      await cachedProxy.syncWithRemote();

      // 验证：应该按时间正确排序
      final messages = await cachedProxy.getMessages();
      expect(messages.length, equals(3));
      expect(messages[0].id, equals('msg-001'));
      expect(messages[1].id, equals('msg-002'));
      expect(messages[2].id, equals('msg-003'));
    });

    test('测试5: 完整场景 - 混合去重和排序', () async {
      final now = DateTime.now();

      // 步骤1: 添加本地消息
      final localId1 = await cachedProxy.sendMessage(
        MessageInput(
          content: '本地消息1（会被远程覆盖）',
          type: 'text',
          createdAt: now,
        ),
      );

      final localId2 = await cachedProxy.sendMessage(
        MessageInput(
          content: '本地消息2（待同步）',
          type: 'text',
          createdAt: now.add(Duration(seconds: 1)),
          metadata: {'localOnly': true},
        ),
      );

      final localId3 = await cachedProxy.sendMessage(
        MessageInput(
          content: '本地消息3（会被远程覆盖）',
          type: 'text',
          createdAt: now.add(Duration(seconds: 2)),
        ),
      );

      final localMessages = await cachedProxy.getMessages();
      expect(localMessages.length, equals(3));

      // 步骤2: 准备远程消息（部分与本地重复）
      remoteMessages = [
        AgentMessage(
          id: localId1,
          role: 'user',
          type: 'text',
          content: '远程版本消息1',
          createdAt: now,
          status: 'completed',
        ),
        AgentMessage(
          id: localId3,
          role: 'user',
          type: 'text',
          content: '远程版本消息3',
          createdAt: now.add(Duration(seconds: 2)),
          status: 'completed',
        ),
        AgentMessage(
          id: 'remote-only-1',
          role: 'assistant',
          type: 'text',
          content: '远程独有消息',
          createdAt: now.add(Duration(seconds: 3)),
        ),
        AgentMessage(
          id: 'remote-only-2',
          role: 'assistant',
          type: 'text',
          content: '远程独有消息2',
          createdAt: now.add(Duration(seconds: 4)),
        ),
      ];

      // 步骤3: 同步
      await cachedProxy.syncWithRemote();

      // 步骤4: 验证结果
      final result = await cachedProxy.getMessages();

      // 应该有5条消息：
      // - 远程版本消息1（覆盖本地消息1）
      // - 本地消息2（待同步，保留）
      // - 远程版本消息3（覆盖本地消息3）
      // - 远程独有消息1
      // - 远程独有消息2
      expect(result.length, equals(5));

      // 验证排序
      expect(result[0].id, equals(localId1));
      expect(result[0].content, equals('远程版本消息1'));

      expect(result[1].id, equals(localId2));
      expect(result[1].content, equals('本地消息2（待同步）'));

      expect(result[2].id, equals(localId3));
      expect(result[2].content, equals('远程版本消息3'));

      expect(result[3].id, equals('remote-only-1'));
      expect(result[3].content, equals('远程独有消息'));

      expect(result[4].id, equals('remote-only-2'));
      expect(result[4].content, equals('远程独有消息2'));
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
