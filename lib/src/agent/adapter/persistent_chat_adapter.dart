import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import '../processor/persistence_queue.dart';
import 'chat_msg.dart';
import 'llm_chat_adapter.dart';
import 'session_memory_manager.dart';

/// 持久化回调函数类型
typedef PersistMessageFunc =
    Future<void> Function(Map<String, dynamic> message);
typedef PersistSessionFunc =
    Future<void> Function(Map<String, dynamic> session);
typedef LoadSessionFunc =
    Future<Map<String, dynamic>?> Function(String employeeId);
typedef LoadMessagesFunc = Future<List<Map<String, dynamic>>> Function(
    String employeeId);
typedef UpdateMessageStatusFunc = Future<void> Function(
    String messageId, String status, {String? error});
typedef DeleteMessagesFunc = Future<void> Function(String employeeId);
typedef DeleteMessageFunc = Future<void> Function(String messageId);

/// 持久化聊天适配器
///
/// 在 LlmChatAdapter 的基础上，增加了消息和会话的持久化能力。
/// 所有消息变更都会通过回调函数持久化到外部存储。
class PersistentChatAdapter extends LlmChatAdapter {
  /// 持久化会话回调
  PersistSessionFunc? persistSession;

  /// 持久化消息回调
  PersistMessageFunc? persistMessage;

  /// 加载会话回调
  LoadSessionFunc? loadSession;

  /// 加载消息回调
  LoadMessagesFunc? loadMessages;

  /// 更新消息状态回调
  UpdateMessageStatusFunc? updateMessageStatusCallback;

  /// 删除消息回调
  DeleteMessagesFunc? deleteMessagesCallback;

  /// 删除单条消息回调
  DeleteMessageFunc? deleteMessageCallback;

  /// 已持久化的消息 ID 集合（避免重复持久化）
  final Set<String> _persistedMessageIds = {};

  /// 持久化队列（用于异步处理持久化任务，避免阻塞）
  final PersistenceQueue _persistenceQueue = PersistenceQueue();

  /// 缓存的 Provider 配置 JSON（用于持久化恢复）
  String? _cachedProviderConfigJson;

  /// 缓存的项目 UUID（用于持久化恢复）
  String? _cachedProjectUuid;

  PersistentChatAdapter() {
    // 持久化最终失败时，通知上层（仅消息类型任务）
    _persistenceQueue.onTaskFailed = (task, error) {
      if (task.type == PersistenceTaskType.message && task.messageData != null) {
        final msgId = task.messageData!['id'] ?? 'unknown';
        print(
          '[PersistentChatAdapter] 消息 $msgId 持久化最终失败（重试耗尽）: $error',
        );
      }
    };
  }

  /// 获取持久化队列（外部可用于等待特定消息持久化完成）
  PersistenceQueue get persistenceQueue => _persistenceQueue;

  @override
  Future<void> initSession({required String employeeId, int? recentLimit}) async {
    await super.initSession(employeeId: employeeId, recentLimit: recentLimit);

    // 加载持久化的消息
    if (loadMessages != null) {
      try {
        final messages = await loadMessages!(employeeId);
        print(
          '[PersistentChatAdapter] 从数据库加载了 ${messages.length} 条消息',
        );

        final session = memoryManager.getSession(currentEmployeeUuid!);
        if (session != null) {
          for (final msgMap in messages) {
            try {
              final wrapper = _mapToMessageWrapper(msgMap);
              if (wrapper != null) {
                session.addMessageWrapper('persistence', wrapper);
                _persistedMessageIds.add(wrapper.uuid);
              }
            } catch (e) {
              print(
                '[PersistentChatAdapter] 加载消息失败: ${msgMap['id']}, $e',
              );
            }
          }
        }
      } catch (e) {
        print('[PersistentChatAdapter] 加载消息失败: $e');
      }
    }

    // 加载持久化的会话数据（context）
    if (loadSession != null) {
      try {
        final sessionData = await loadSession!(employeeId);
        if (sessionData != null) {
          final contextJson = sessionData['context'] as String?;
          if (contextJson != null && contextJson.isNotEmpty) {
            try {
              final contextData = jsonDecode(contextJson) as Map<String, dynamic>;
              setContext(contextData);
              print('[PersistentChatAdapter] 恢复了会话上下文');
            } catch (e) {
              print('[PersistentChatAdapter] 恢复会话上下文失败: $e');
            }
          }

          // 恢复 provider 配置
          final providerJson = sessionData['providerConfig'] as String?;
          if (providerJson != null && providerJson.isNotEmpty) {
            try {
              _cachedProviderConfigJson = providerJson;
              print('[PersistentChatAdapter] 恢复了 Provider 配置');
            } catch (e) {
              print('[PersistentChatAdapter] 恢复 Provider 配置失败: $e');
            }
          }

          // 恢复项目 UUID
          final projectUuid = sessionData['projectUuid'] as String?;
          if (projectUuid != null && projectUuid.isNotEmpty) {
            _cachedProjectUuid = projectUuid;
            print('[PersistentChatAdapter] 恢复了项目 UUID: $projectUuid');
          }
        }
      } catch (e) {
        print('[PersistentChatAdapter] 加载会话数据失败: $e');
      }
    }

    _notifyPersistSession();
  }

  /// 加载剩余的历史消息
  @override
  Future<void> loadRemainingMessages() async {
    if (loadMessages != null) {
      try {
        final messages = await loadMessages!(currentEmployeeUuid!);
        print(
          '[PersistentChatAdapter] loadRemainingMessages: 从数据库加载了 ${messages.length} 条消息',
        );

        final session = memoryManager.getSession(currentEmployeeUuid!);
        if (session != null) {
          session.clear();

          for (final msgMap in messages) {
            try {
              final wrapper = _mapToMessageWrapper(msgMap);
              if (wrapper != null) {
                session.addMessageWrapper('persistence', wrapper);
                _persistedMessageIds.add(wrapper.uuid);
              }
            } catch (e) {
              print(
                '[PersistentChatAdapter] loadRemainingMessages: 加载消息失败: ${msgMap['id']}, $e',
              );
            }
          }
        }
      } catch (e) {
        print('[PersistentChatAdapter] loadRemainingMessages: 加载消息失败: $e');
      }
    }
  }

  @override
  Stream<StreamResponse> streamMessage(
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  }) async* {
    final session = memoryManager.getSession(currentEmployeeUuid!);
    final messagesBefore = session?.messageCount ?? 0;

    try {
      await for (final response in super.streamMessage(
        messageData,
        cancellationToken: cancellationToken,
      )) {
        yield response;

        final messagesNow = session?.messageCount ?? 0;
        if (messagesNow > messagesBefore) {
          _persistNewMessages(session, messagesBefore);
        }
      }
    } catch (e) {
      print('[PersistentChatAdapter] streamMessage error: $e');
      rethrow;
    } finally {
      final messagesAfter = session?.messageCount ?? 0;
      if (messagesAfter > messagesBefore) {
        _persistNewMessages(session, messagesBefore);
      }
    }
  }

  @override
  Future<List<AgentMessage>> getSessionMessages(
    String employeeId,
  ) async {
    return await super.getSessionMessages(employeeId);
  }

  /// 注入一条 assistant 消息到当前会话
  Future<void> injectAssistantMessage(String messageId, String content, String deviceIdentifier) async {
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return;

    final now = DateTime.now();
    final wrapper = MessageWrapper(
      uuid: messageId,
      message: ChatMsg.assistant(content),
      createdAt: now,
      metadata: {'status': 'completed'},
    );
    session.addMessageWrapper(deviceIdentifier, wrapper);

    final messageMap = _messageWrapperToMap(wrapper);
    _persistedMessageIds.add(messageId);
    await _persistMessageAndWait(messageMap);
  }

  /// 注入一条 system 消息到当前会话
  void injectSystemMessage(String messageId, String content, String deviceIdentifier) {
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return;

    final now = DateTime.now();
    final wrapper = MessageWrapper(
      uuid: messageId,
      message: ChatMsg.system(content),
      createdAt: now,
      metadata: {'status': 'completed', 'trigger': 'scheduled_task'},
    );
    session.addMessageWrapper(deviceIdentifier, wrapper);

    final messageMap = _messageWrapperToMap(wrapper);
    _persistedMessageIds.add(messageId);
    _persistMessage(messageMap);
  }

  /// 持久化新添加的消息（fire-and-forget，不等待完成）
  Future<void> _persistNewMessages(
    SessionHistory? session,
    int messagesBefore,
  ) async {
    if (session == null) {
      print(
        '[PersistentChatAdapter] _persistNewMessages: session is null, skipping',
      );
      return;
    }

    final allMessages = session.allMessages;
    final messagesNow = allMessages.length;

    if (messagesNow <= messagesBefore) {
      return;
    }

    for (var i = messagesBefore; i < messagesNow; i++) {
      final wrapper = allMessages[i];
      final messageId = wrapper.uuid;

      if (_persistedMessageIds.contains(messageId)) {
        continue;
      }

      final messageMap = _messageWrapperToMap(wrapper);
      _persistMessage(messageMap);
      _persistedMessageIds.add(messageId);
      print(
        '[PersistentChatAdapter] _persistNewMessages: persisted $messageId',
      );
    }
  }

  /// 持久化单条消息（fire-and-forget）
  void _persistMessage(Map<String, dynamic> message) {
    if (persistMessage == null) return;

    final messageWithSession = {...message, 'employeeId': currentSessionUuid};

    _persistenceQueue.addMessageTask(messageWithSession, (data) async {
      try {
        await persistMessage!(data);
      } catch (e) {
        print('[PersistentChatAdapter] _persistMessage: 持久化失败: $e');
        rethrow;
      }
    });
  }

  /// 持久化单条消息（等待完成）
  Future<void> _persistMessageAndWait(Map<String, dynamic> message) async {
    if (persistMessage == null) return;

    final messageWithSession = {...message, 'employeeId': currentSessionUuid};

    await _persistenceQueue.addMessageTaskAndWait(messageWithSession, (data) async {
      try {
        await persistMessage!(data);
      } catch (e) {
        print('[PersistentChatAdapter] _persistMessageAndWait: 持久化失败: $e');
        rethrow;
      }
    });
  }

  /// 通知持久化会话
  void _notifyPersistSession() {
    if (persistSession == null) return;

    final sessionData = {
      'uuid': currentSessionUuid,
      'employeeId': currentEmployeeUuid,
      'context': jsonEncode(currentContext ?? {}),
      'providerConfig': _cachedProviderConfigJson,
      'projectUuid': _cachedProjectUuid,
      'updatedAt': DateTime.now().toIso8601String(),
    };

    _persistenceQueue.addSessionTask(sessionData, (data) async {
      try {
        await persistSession!(data);
      } catch (e) {
        print('[PersistentChatAdapter] 持久化会话失败: $e');
        rethrow;
      }
    });
  }

  @override
  void setContext(Map<String, dynamic> contextData) {
    super.setContext(contextData);
    _notifyPersistSession();
  }

  @override
  void updateMessageStatus(
    String messageId,
    AgentMessageStatus status, {
    String? error,
  }) {
    super.updateMessageStatus(messageId, status, error: error);
    if (updateMessageStatusCallback != null) {
      updateMessageStatusCallback!(messageId, status.name, error: error);
    }
  }

  /// 删除单条消息（从内存和数据库中删除）
  Future<void> deleteMessage(String messageId) async {
    final success = removeMessageFromMemory(messageId);
    if (success && deleteMessageCallback != null) {
      await deleteMessageCallback!(messageId);
    }
  }

  @override
  Future<void> clearCurrentSession() async {
    await super.clearCurrentSession();

    if (deleteMessagesCallback != null && currentSessionUuid != null) {
      try {
        await deleteMessagesCallback!(currentSessionUuid!);
        print('[PersistentChatAdapter] clearCurrentSession: 已删除数据库中的消息');
      } catch (e) {
        print('[PersistentChatAdapter] clearCurrentSession: 删除数据库消息失败: $e');
      }
    }

    _persistedMessageIds.clear();
  }

  /// 保存 Provider 配置并持久化到数据库
  Future<void> saveProviderConfig(ProviderConfig config) async {
    await updateProvider(config.toMap());
    _cachedProviderConfigJson = jsonEncode(config.toMap());
    _notifyPersistSession();
  }

  /// 设置当前项目 UUID 并持久化到数据库
  Future<void> setCurrentProjectUuid(String uuid) async {
    _cachedProjectUuid = uuid;
    _notifyPersistSession();
  }

  /// 从消息 Map 创建 MessageWrapper
  MessageWrapper? _mapToMessageWrapper(Map<String, dynamic> map) {
    try {
      final uuid = map['id'] as String? ?? const Uuid().v4();
      final role = map['role'] as String? ?? 'user';
      final content = map['content'] as String? ?? '';
      final createdAtStr = map['createdAt'] as String?;
      final createdAt = createdAtStr != null
          ? DateTime.parse(createdAtStr)
          : DateTime.now();
      final metadata = map['metadata'] as Map<String, dynamic>? ?? {};
      final toolCallId = map['toolCallId'] as String?;
      final toolCallsJson = map['toolCalls'] as String?;
      final isError = map['isError'] as bool? ?? false;

      // 创建对应的 ChatMsg
      late ChatMsg message;
      switch (role) {
        case 'user':
          message = ChatMsg.user(content);
        case 'assistant':
          if (toolCallsJson != null && toolCallsJson.isNotEmpty) {
            final toolCalls = (jsonDecode(toolCallsJson) as List)
                .map((tc) => ToolCallInfo.fromMap(tc as Map<String, dynamic>))
                .toList();
            message = ChatMsg.assistant(content, toolCalls: toolCalls);
          } else {
            message = ChatMsg.assistant(content);
          }
        case 'tool':
          // 检查是否为分组格式
          final toolResultsJson = map['toolResults'] as String?;
          if (toolResultsJson != null && toolResultsJson.isNotEmpty) {
            final results = (jsonDecode(toolResultsJson) as List)
                .map((r) => ToolResultInfo.fromMap(r as Map<String, dynamic>))
                .toList();
            message = ChatMsg.toolResultGroup(results);
          } else {
            // 单条格式（向后兼容）
            message = ChatMsg.toolResult(
              toolCallId: toolCallId ?? '',
              content: content,
              isError: isError,
              name: metadata['toolName'] as String?,
            );
          }
        case 'system':
          return MessageWrapper(
            uuid: uuid,
            message: ChatMsg.system(content),
            createdAt: createdAt,
            metadata: metadata,
          );
        default:
          return null;
      }

      return MessageWrapper(
        uuid: uuid,
        message: message,
        createdAt: createdAt,
        metadata: metadata,
      );
    } catch (e) {
      print('[PersistentChatAdapter] _mapToMessageWrapper failed: $e');
      return null;
    }
  }

  /// 将 MessageWrapper 转为 Map
  Map<String, dynamic> _messageWrapperToMap(MessageWrapper wrapper) {
    final map = <String, dynamic>{
      'id': wrapper.uuid,
      'role': _chatMsgToRole(wrapper.message),
      'content': wrapper.message.content,
      'type': 'text',
      'createdAt': wrapper.createdAt.toIso8601String(),
      'metadata': wrapper.metadata ?? {},
    };

    // 如果是 assistant 消息且包含 toolCalls，序列化
    if (wrapper.message.role == ChatMsgRole.assistant && wrapper.message.toolCalls != null && wrapper.message.toolCalls!.isNotEmpty) {
      map['toolCalls'] = jsonEncode(
        wrapper.message.toolCalls!.map((tc) => {
          'id': tc.id,
          'name': tc.name,
          'arguments': tc.arguments,
        }).toList(),
      );
    }

    // 如果是 tool 消息，序列化为分组格式或单条格式
    if (wrapper.message.role == ChatMsgRole.tool) {
      if (wrapper.message.isToolResultGroup) {
        map['toolResults'] = jsonEncode(
          wrapper.message.toolResults!.map((r) => r.toMap()).toList(),
        );
      } else {
        map['toolCallId'] = wrapper.message.toolCallId;
        if (wrapper.message.isError) {
          map['isError'] = true;
        }
      }
    }

    return map;
  }

  /// 从 ChatMsg 获取角色
  String _chatMsgToRole(ChatMsg message) {
    return switch (message.role) {
      ChatMsgRole.user => 'user',
      ChatMsgRole.assistant => 'assistant',
      ChatMsgRole.tool => 'tool',
      ChatMsgRole.system => 'system',
    };
  }

  @override
  Future<void> dispose() async {
    await _persistenceQueue.dispose();
    await super.dispose();
  }
}
