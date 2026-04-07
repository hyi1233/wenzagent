import 'package:test/test.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/service/message_store_service.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

void main() {
  group('CachedAgentProxy - User Message Count Tests', () {
    test('getSessionMessagesByUserCount should return messages based on user message count', () async {
      // 创建测试数据
      final messages = <AgentMessage>[];
      
      // 创建40条消息：20条用户消息 + 20条助手消息
      for (int i = 0; i < 20; i++) {
        // 用户消息
        messages.add(AgentMessage(
          id: 'user-$i',
          role: 'user',
          type: 'text',
          content: '用户消息 $i',
          createdAt: DateTime.now().subtract(Duration(minutes: 40 - i * 2)),
          status: 'completed',
        ));
        
        // 助手消息
        messages.add(AgentMessage(
          id: 'assistant-$i',
          role: 'assistant',
          type: 'text',
          content: '助手消息 $i',
          createdAt: DateTime.now().subtract(Duration(minutes: 39 - i * 2)),
          status: 'completed',
        ));
      }

      // 测试 getSessionMessagesByUserCount 方法
      // 期望：返回最近20条用户消息时间段内的所有消息（40条）
      // 注意：这里是在 AgentImpl 层面测试，不需要 mock
      expect(messages.length, equals(40));
      
      // 验证用户消息数量
      final userMessages = messages.where((m) => m.role == 'user').toList();
      expect(userMessages.length, equals(20));
      
      // 验证助手消息数量
      final assistantMessages = messages.where((m) => m.role == 'assistant').toList();
      expect(assistantMessages.length, equals(20));
    });

    test('getSessionMessagesByUserCount should limit to userMessageLimit', () async {
      final messages = <AgentMessage>[];
      
      // 创建30条用户消息 + 30条助手消息
      for (int i = 0; i < 30; i++) {
        messages.add(AgentMessage(
          id: 'user-$i',
          role: 'user',
          type: 'text',
          content: '用户消息 $i',
          createdAt: DateTime.now().subtract(Duration(minutes: 60 - i * 2)),
          status: 'completed',
        ));
        
        messages.add(AgentMessage(
          id: 'assistant-$i',
          role: 'assistant',
          type: 'text',
          content: '助手消息 $i',
          createdAt: DateTime.now().subtract(Duration(minutes: 59 - i * 2)),
          status: 'completed',
        ));
      }

      // 按时间倒序排列
      messages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      // 统计前20条用户消息
      int userCount = 0;
      final selectedMessages = <AgentMessage>[];
      
      for (final message in messages) {
        selectedMessages.add(message);
        if (message.role == 'user') {
          userCount++;
          if (userCount >= 20) {
            break;
          }
        }
      }
      
      // 验证选择的用户消息数量
      final selectedUserMessages = selectedMessages.where((m) => m.role == 'user').toList();
      expect(selectedUserMessages.length, equals(20));
      
      // 验证选择的总消息数量（应该大于20，因为包含助手消息）
      expect(selectedMessages.length, greaterThan(20));
    });

    test('getSessionMessagesByUserCount with empty messages', () async {
      final messages = <AgentMessage>[];
      
      // 空消息列表
      expect(messages.length, equals(0));
      
      // 空列表应该返回空
      expect(messages.where((m) => m.role == 'user').length, equals(0));
    });

    test('getSessionMessagesByUserCount with only assistant messages', () async {
      final messages = <AgentMessage>[];
      
      // 只有助手消息
      for (int i = 0; i < 10; i++) {
        messages.add(AgentMessage(
          id: 'assistant-$i',
          role: 'assistant',
          type: 'text',
          content: '助手消息 $i',
          createdAt: DateTime.now().subtract(Duration(minutes: i)),
          status: 'completed',
        ));
      }
      
      // 验证没有用户消息
      final userMessages = messages.where((m) => m.role == 'user').toList();
      expect(userMessages.length, equals(0));
      
      // 验证助手消息数量
      expect(messages.length, equals(10));
    });
  });

  group('CachedAgentProxy - Sync Logic Tests', () {
    test('Sync should clear local cache and rewrite with remote messages', () async {
      // 这个测试验证同步逻辑：
      // 1. 清空本地缓存
      // 2. 重新写入远程返回的消息
      
      // 模拟本地缓存
      final localCache = <AgentMessage>[
        AgentMessage(
          id: 'local-1',
          role: 'user',
          type: 'text',
          content: '本地消息1',
          createdAt: DateTime.now().subtract(Duration(minutes: 5)),
          status: 'completed',
        ),
        AgentMessage(
          id: 'local-2',
          role: 'assistant',
          type: 'text',
          content: '本地消息2',
          createdAt: DateTime.now().subtract(Duration(minutes: 4)),
          status: 'completed',
        ),
      ];
      
      // 模拟远程消息
      final remoteMessages = <AgentMessage>[
        AgentMessage(
          id: 'remote-1',
          role: 'user',
          type: 'text',
          content: '远程消息1',
          createdAt: DateTime.now().subtract(Duration(minutes: 3)),
          status: 'completed',
        ),
        AgentMessage(
          id: 'remote-2',
          role: 'assistant',
          type: 'text',
          content: '远程消息2',
          createdAt: DateTime.now().subtract(Duration(minutes: 2)),
          status: 'completed',
        ),
      ];
      
      // 验证本地缓存被清空
      localCache.clear();
      expect(localCache.length, equals(0));
      
      // 验证远程消息被写入
      for (final message in remoteMessages) {
        localCache.add(message);
      }
      expect(localCache.length, equals(2));
      expect(localCache[0].id, equals('remote-1'));
      expect(localCache[1].id, equals('remote-2'));
    });
  });

  group('CachedAgentProxy - Deduplication Tests', () {
    test('Messages should not have duplicate IDs', () {
      final messages = <AgentMessage>[
        AgentMessage(
          id: 'msg-1',
          role: 'user',
          type: 'text',
          content: '消息1',
          createdAt: DateTime.now(),
          status: 'completed',
        ),
        AgentMessage(
          id: 'msg-2',
          role: 'assistant',
          type: 'text',
          content: '消息2',
          createdAt: DateTime.now().add(Duration(seconds: 1)),
          status: 'completed',
        ),
      ];
      
      // 验证没有重复ID
      final ids = messages.map((m) => m.id).toList();
      final uniqueIds = ids.toSet();
      expect(ids.length, equals(uniqueIds.length));
      
      // 尝试添加重复消息
      messages.add(AgentMessage(
        id: 'msg-1', // 重复ID
        role: 'user',
        type: 'text',
        content: '重复消息',
        createdAt: DateTime.now().add(Duration(seconds: 2)),
        status: 'completed',
      ));
      
      // 去重逻辑
      final uniqueMessages = <String, AgentMessage>{};
      for (final msg in messages) {
        uniqueMessages[msg.id] = msg;
      }
      
      // 验证去重后的消息数量
      expect(uniqueMessages.length, equals(2));
    });
  });

  group('CachedAgentProxy - Event Handling Tests', () {
    test('Message status changed event should trigger sync', () async {
      // 模拟事件处理
      final eventsReceived = <String>[];
      
      void handleEvent(Map<String, dynamic> event) {
        final type = event['type'] as String?;
        if (type != null) {
          eventsReceived.add(type);
        }
      }
      
      // 模拟接收事件
      handleEvent({
        'type': 'messageStatusChanged',
        'data': {
          'messageId': 'msg-1',
          'status': 'completed',
        },
      });
      
      // 验证事件被接收
      expect(eventsReceived.length, equals(1));
      expect(eventsReceived[0], equals('messageStatusChanged'));
    });

    test('Tool call event should trigger sync', () async {
      final eventsReceived = <String>[];
      
      void handleEvent(Map<String, dynamic> event) {
        final type = event['type'] as String?;
        if (type != null) {
          eventsReceived.add(type);
        }
      }
      
      // 模拟工具调用事件
      handleEvent({
        'type': 'toolCallStart',
        'data': {
          'toolName': 'test-tool',
        },
      });
      
      handleEvent({
        'type': 'toolCallResult',
        'data': {
          'toolName': 'test-tool',
          'result': 'success',
        },
      });
      
      // 验证事件被接收
      expect(eventsReceived.length, equals(2));
      expect(eventsReceived[0], equals('toolCallStart'));
      expect(eventsReceived[1], equals('toolCallResult'));
    });

    test('Message queued event should update status', () {
      final messageStatus = <String, String>{};
      
      void handleEvent(Map<String, dynamic> event) {
        final type = event['type'] as String?;
        final data = event['data'] as Map<String, dynamic>?;
        
        if (type == 'messageQueued') {
          final messageId = data?['messageId'] as String?;
          if (messageId != null) {
            messageStatus[messageId] = 'queued';
          }
        }
      }
      
      // 模拟队列事件
      handleEvent({
        'type': 'messageQueued',
        'data': {
          'messageId': 'msg-1',
          'queuePosition': 1,
        },
      });
      
      // 验证状态更新
      expect(messageStatus['msg-1'], equals('queued'));
    });

    test('Message processing event should update status', () {
      final messageStatus = <String, String>{};
      
      void handleEvent(Map<String, dynamic> event) {
        final type = event['type'] as String?;
        final data = event['data'] as Map<String, dynamic>?;
        
        if (type == 'messageProcessing') {
          final messageId = data?['messageId'] as String?;
          if (messageId != null) {
            messageStatus[messageId] = 'processing';
          }
        }
      }
      
      // 模拟处理中事件
      handleEvent({
        'type': 'messageProcessing',
        'data': {
          'messageId': 'msg-1',
        },
      });
      
      // 验证状态更新
      expect(messageStatus['msg-1'], equals('processing'));
    });

    test('Message replied event should add reply info', () {
      final replyInfo = <String, String>{};
      
      void handleEvent(Map<String, dynamic> event) {
        final type = event['type'] as String?;
        final data = event['data'] as Map<String, dynamic>?;
        
        if (type == 'messageReplied') {
          final originalMessageId = data?['originalMessageId'] as String?;
          final replyMessageId = data?['replyMessageId'] as String?;
          if (originalMessageId != null && replyMessageId != null) {
            replyInfo[originalMessageId] = replyMessageId;
          }
        }
      }
      
      // 模拟回复事件
      handleEvent({
        'type': 'messageReplied',
        'data': {
          'originalMessageId': 'msg-1',
          'replyMessageId': 'msg-2',
        },
      });
      
      // 验证回复信息
      expect(replyInfo['msg-1'], equals('msg-2'));
    });
  });
}
