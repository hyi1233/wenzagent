import 'package:langchain_core/chat_models.dart';

/// 会话消息历史
class SessionHistory {
  final String sessionUuid;
  final String employeeUuid;
  final String? title;
  final DateTime createdAt;
  final List<ChatMessage> messages;

  /// 缓存的 LLM 生成的对话摘要
  String? conversationSummary;

  /// 摘要覆盖的消息范围: messages[0..summarizedUpToIndex-1]
  int summarizedUpToIndex;

  SessionHistory({
    required this.sessionUuid,
    required this.employeeUuid,
    this.title,
    DateTime? createdAt,
    List<ChatMessage>? messages,
    this.conversationSummary,
    this.summarizedUpToIndex = 0,
  }) : createdAt = createdAt ?? DateTime.now(),
       messages = messages ?? [];

  /// 添加消息
  void addMessage(ChatMessage message) {
    messages.add(message);
  }

  /// 清空消息
  void clear() {
    messages.clear();
    conversationSummary = null;
    summarizedUpToIndex = 0;
  }

  /// 转换为 Map（用于持久化）
  Map<String, dynamic> toMap() => {
    'sessionUuid': sessionUuid,
    'employeeUuid': employeeUuid,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'messages': messages.map((m) => m.toMap()).toList(),
    if (conversationSummary != null) 'conversationSummary': conversationSummary,
    if (summarizedUpToIndex > 0) 'summarizedUpToIndex': summarizedUpToIndex,
  };

  /// 从 Map 创建
  static SessionHistory fromMap(Map<String, dynamic> map) {
    final messagesList = map['messages'] as List? ?? [];
    final messages = messagesList
        .map((m) => ChatMessage.fromMap(m as Map<String, dynamic>))
        .toList();

    return SessionHistory(
      sessionUuid: map['sessionUuid'] as String,
      employeeUuid: map['employeeUuid'] as String,
      title: map['title'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'] as String)
          : null,
      messages: messages,
      conversationSummary: map['conversationSummary'] as String?,
      summarizedUpToIndex: map['summarizedUpToIndex'] as int? ?? 0,
    );
  }
}

/// 会话记忆管理器
class SessionMemoryManager {
  /// 会话历史映射
  final Map<String, SessionHistory> _sessions = {};

  /// 员工与会话的映射
  final Map<String, Set<String>> _employeeSessions = {};

  /// 获取或创建会话历史
  SessionHistory getOrCreateSession(
    String sessionUuid,
    String employeeUuid, {
    String? title,
  }) {
    final session = _sessions.putIfAbsent(
      sessionUuid,
      () => SessionHistory(
        sessionUuid: sessionUuid,
        employeeUuid: employeeUuid,
        title: title,
      ),
    );
    _registerEmployeeSession(employeeUuid, sessionUuid);
    return session;
  }

  /// 获取会话历史
  SessionHistory? getSession(String sessionUuid) {
    return _sessions[sessionUuid];
  }

  /// 获取员工的所有会话
  List<SessionHistory> getSessionsByEmployee(String employeeUuid) {
    final sessionUuids = _employeeSessions[employeeUuid];
    if (sessionUuids == null) return [];

    return sessionUuids
        .map((uuid) => _sessions[uuid])
        .whereType<SessionHistory>()
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// 添加消息到会话
  void addMessage(String sessionUuid, ChatMessage message) {
    final session = _sessions[sessionUuid];
    if (session != null) {
      session.addMessage(message);
    }
  }

  /// 清空会话消息
  void clearSession(String sessionUuid) {
    _sessions[sessionUuid]?.clear();
  }

  /// 删除会话
  void deleteSession(String sessionUuid) {
    final session = _sessions.remove(sessionUuid);
    if (session != null) {
      _employeeSessions[session.employeeUuid]?.remove(sessionUuid);
    }
  }

  /// 构建发送给 LLM 的消息列表
  ///
  /// 返回 [systemPrompt?, ...session.messages]。
  /// 调用方需要在调用此方法前将用户消息加入 session history。
  List<ChatMessage> buildMessages({
    required String sessionUuid,
    String? systemPrompt,
  }) {
    final messages = <ChatMessage>[];

    // 添加系统提示
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add(ChatMessage.system(systemPrompt));
    }

    // 添加历史消息（已包含最新的用户消息）
    final session = _sessions[sessionUuid];
    if (session != null) {
      messages.addAll(session.messages);
    }

    return messages;
  }

  /// 注册员工与会话的关联
  void _registerEmployeeSession(String employeeUuid, String sessionUuid) {
    _employeeSessions.putIfAbsent(employeeUuid, () => {});
    _employeeSessions[employeeUuid]!.add(sessionUuid);
  }

  /// 清理所有会话
  void dispose() {
    _sessions.clear();
    _employeeSessions.clear();
  }
}
