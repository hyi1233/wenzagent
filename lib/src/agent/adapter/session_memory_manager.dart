import 'package:uuid/uuid.dart';

import 'chat_msg.dart';

/// 带有UUID的消息包装器
class MessageWrapper {
  final String uuid;
  final ChatMsg message;
  final DateTime createdAt;
  final Map<String, dynamic>? metadata;

  MessageWrapper({
    required this.uuid,
    required this.message,
    required this.createdAt,
    this.metadata,
  });

  /// 创建新的MessageWrapper（自动生成UUID）
  factory MessageWrapper.create(ChatMsg message) {
    return MessageWrapper(
      uuid: const Uuid().v4(),
      message: message,
      createdAt: DateTime.now(),
    );
  }

  /// 从Map创建
  factory MessageWrapper.fromMap(Map<String, dynamic> map) {
    return MessageWrapper(
      uuid: map['uuid'] as String,
      message: ChatMsg.fromMap(map['message'] as Map<String, dynamic>),
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'] as String)
          : DateTime.now(),
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() => {
    'uuid': uuid,
    'message': message.toMap(),
    'createdAt': createdAt.toIso8601String(),
  };
}

/// 会话消息历史
class SessionHistory {
  final String employeeId;
  final String? title;
  final DateTime createdAt;

  /// 消息映射：按设备ID区分不同设备的消息记录
  /// key: deviceId, value: 该设备上的消息列表（使用MessageWrapper保持稳定ID）
  final Map<String, List<MessageWrapper>> messagesMap;

  /// 缓存的 LLM 生成的对话摘要
  String? conversationSummary;

  /// 摘要覆盖的消息范围: messages[0..summarizedUpToIndex-1]
  int summarizedUpToIndex;

  SessionHistory({
    required this.employeeId,
    this.title,
    DateTime? createdAt,
    Map<String, List<MessageWrapper>>? messagesMap,
    this.conversationSummary,
    this.summarizedUpToIndex = 0,
  }) : createdAt = createdAt ?? DateTime.now(),
       messagesMap = messagesMap ?? {};

  /// 获取所有设备的所有消息（合并），按 createdAt 升序排列
  List<MessageWrapper> get allMessages {
    final all = <MessageWrapper>[];
    for (final messages in messagesMap.values) {
      all.addAll(messages);
    }
    all.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all;
  }

  /// 获取指定设备的消息列表
  List<MessageWrapper> getMessagesForDevice(String deviceId) {
    return messagesMap[deviceId] ?? [];
  }

  /// 添加消息到指定设备
  ///
  /// [messageId] 可选的消息ID，如果不提供则自动生成
  /// [metadata] 可选的元数据，用于携带额外信息（如 toolName）
  void addMessage(String deviceId, ChatMsg message, {String? messageId, Map<String, dynamic>? metadata}) {
    if (messageId != null) {
      // 使用提供的消息ID
      messagesMap.putIfAbsent(deviceId, () => []).add(
        MessageWrapper(
          uuid: messageId,
          message: message,
          createdAt: DateTime.now(),
          metadata: metadata,
        ),
      );
    } else {
      // 自动生成新的UUID
      final wrapper = MessageWrapper.create(message);
      if (metadata != null) {
        messagesMap.putIfAbsent(deviceId, () => []).add(
          MessageWrapper(
            uuid: wrapper.uuid,
            message: wrapper.message,
            createdAt: wrapper.createdAt,
            metadata: metadata,
          ),
        );
      } else {
        messagesMap.putIfAbsent(deviceId, () => []).add(wrapper);
      }
    }
  }

  /// 添加MessageWrapper到指定设备（用于从数据库恢复）
  void addMessageWrapper(String deviceId, MessageWrapper wrapper) {
    messagesMap.putIfAbsent(deviceId, () => []).add(wrapper);
  }

  /// 清空所有设备的消息
  void clear() {
    messagesMap.clear();
    conversationSummary = null;
    summarizedUpToIndex = 0;
  }

  /// 清空指定设备的消息
  void clearDevice(String deviceId) {
    messagesMap.remove(deviceId);
  }

  /// 删除指定消息
  ///
  /// 从所有设备中删除指定 UUID 的消息
  /// 返回是否成功删除
  bool removeMessage(String messageId) {
    bool removed = false;
    for (final deviceId in messagesMap.keys) {
      final messages = messagesMap[deviceId]!;
      final index = messages.indexWhere((m) => m.uuid == messageId);
      if (index >= 0) {
        messages.removeAt(index);
        removed = true;
        print('[SessionHistory] 已删除消息: $messageId (设备: $deviceId)');
      }
    }
    return removed;
  }

  /// 获取所有设备ID列表
  List<String> get deviceIds => messagesMap.keys.toList()..sort();

  /// 获取消息总数（所有设备）
  int get messageCount => messagesMap.values.fold(0, (sum, list) => sum + list.length);

  /// 转换为 Map（用于持久化）
  Map<String, dynamic> toMap() => {
    'employeeId': employeeId,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'messagesMap': messagesMap.map(
      (deviceId, messages) => MapEntry(
        deviceId,
        messages.map((m) => m.toMap()).toList(),
      ),
    ),
    if (conversationSummary != null) 'conversationSummary': conversationSummary,
    if (summarizedUpToIndex > 0) 'summarizedUpToIndex': summarizedUpToIndex,
  };

  /// 从 Map 创建
  static SessionHistory fromMap(Map<String, dynamic> map) {
    final messagesMapData = map['messagesMap'] as Map? ?? {};
    final messagesMap = <String, List<MessageWrapper>>{};

    for (final entry in messagesMapData.entries) {
      final deviceId = entry.key as String;
      final messagesList = entry.value as List? ?? [];
      messagesMap[deviceId] = messagesList
          .map((m) => MessageWrapper.fromMap(m as Map<String, dynamic>))
          .toList();
    }

    return SessionHistory(
      employeeId: map['employeeId'] as String,
      title: map['title'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'] as String)
          : null,
      messagesMap: messagesMap,
      conversationSummary: map['conversationSummary'] as String?,
      summarizedUpToIndex: map['summarizedUpToIndex'] as int? ?? 0,
    );
  }
}

/// 会话记忆管理器
class SessionMemoryManager {
  /// 会话历史映射（key: employeeId）
  final Map<String, SessionHistory> _sessions = {};

  /// 获取或创建会话历史
  SessionHistory getOrCreateSession(
    String employeeId, {
    String? title,
  }) {
    return _sessions.putIfAbsent(
      employeeId,
      () => SessionHistory(
        employeeId: employeeId,
        title: title,
      ),
    );
  }

  /// 获取会话历史
  SessionHistory? getSession(String employeeId) {
    return _sessions[employeeId];
  }

  /// 获取员工的所有会话
  List<SessionHistory> getSessionsByEmployee(String employeeId) {
    final session = _sessions[employeeId];
    return session != null ? [session] : [];
  }

  /// 获取会话在指定设备上的消息
  List<ChatMsg> getMessagesForDevice(
    String employeeId,
    String deviceId,
  ) {
    final session = _sessions[employeeId];
    if (session == null) return [];
    // 从 MessageWrapper 列表中提取 ChatMsg
    return session.getMessagesForDevice(deviceId)
        .map((wrapper) => wrapper.message)
        .toList();
  }

  /// 清空会话在指定设备上的消息
  void clearDeviceSession(String employeeId, String deviceId) {
    final session = _sessions[employeeId];
    if (session != null) {
      session.clearDevice(deviceId);
    }
  }

  /// 添加消息到会话
  ///
  /// [employeeId] 员工ID（作为会话ID）
  /// [deviceId] 设备ID，用于区分不同设备上的消息
  void addMessage(String employeeId, String deviceId, ChatMsg message, {String? messageId, Map<String, dynamic>? metadata}) {
    final session = _sessions[employeeId];
    if (session != null) {
      session.addMessage(deviceId, message, messageId: messageId, metadata: metadata);
    }
  }

  /// 清空会话消息
  void clearSession(String employeeId) {
    _sessions[employeeId]?.clear();
  }

  /// 删除会话
  void deleteSession(String employeeId) {
    _sessions.remove(employeeId);
  }

  /// 构建发送给 LLM 的消息列表
  ///
  /// 返回 [systemPrompt?, ...session.allMessages]。
  /// 包含所有设备上的消息，按设备ID排序后合并。
  /// 调用方需要在调用此方法前将用户消息加入 session history。
  ///
  /// 连续的 tool 角色消息会被合并为一条分组消息（ChatMsg.toolResultGroup），
  /// 以确保 OpenAI 兼容性。
  List<ChatMsg> buildMessages({
    required String employeeId,
    String? systemPrompt,
  }) {
    final messages = <ChatMsg>[];

    // 添加系统提示
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add(ChatMsg.system(systemPrompt));
    }

    // 添加历史消息（已包含最新的用户消息）
    final session = _sessions[employeeId];
    if (session != null) {
      // 从 MessageWrapper 列表中提取 ChatMsg，并合并连续的 tool 消息
      final rawMessages = session.allMessages
          .map((wrapper) => wrapper.message)
          .toList();
      messages.addAll(_mergeConsecutiveToolMessages(rawMessages));
    }

    return messages;
  }

  /// 将连续的 tool 角色消息合并为一条分组消息
  ///
  /// 在 OpenAI 协议中，一轮 assistant tool_calls 后跟的多个 tool result
  /// 应该作为一组传递，确保 tool_call_id 的对应关系正确。
  /// 分组消息使用 ChatMsg.toolResultGroup 存储。
  static List<ChatMsg> _mergeConsecutiveToolMessages(List<ChatMsg> messages) {
    if (messages.isEmpty) return messages;

    final result = <ChatMsg>[];
    List<ToolResultInfo>? pendingToolResults;

    for (final msg in messages) {
      if (msg.role == ChatMsgRole.tool && !msg.isToolResultGroup) {
        // 单条 tool result，加入待合并缓冲区
        pendingToolResults ??= [];
        pendingToolResults.add(ToolResultInfo(
          toolCallId: msg.toolCallId ?? '',
          content: msg.content,
          isError: msg.isError,
          name: msg.name,
        ));
      } else {
        // 非 tool 消息（或已经是分组消息），先刷新缓冲区
        if (pendingToolResults != null) {
          result.add(ChatMsg.toolResultGroup(pendingToolResults));
          pendingToolResults = null;
        }
        result.add(msg);
      }
    }

    // 刷新末尾剩余的 tool results
    if (pendingToolResults != null) {
      result.add(ChatMsg.toolResultGroup(pendingToolResults));
    }

    return result;
  }

  /// 清理所有会话
  void dispose() {
    _sessions.clear();
  }
}
