import 'dart:convert';

import 'package:llm_dart/llm_dart.dart' as llm;

/// 消息角色
enum ChatMsgRole { user, assistant, system, tool }

/// 工具调用信息
class ToolCallInfo {
  final String id;
  final String name;
  final String argumentsJson;

  const ToolCallInfo({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  Map<String, dynamic> get arguments {
    if (argumentsJson.isEmpty) return {};
    try {
      return jsonDecode(argumentsJson) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };

  factory ToolCallInfo.fromMap(Map<String, dynamic> map) {
    return ToolCallInfo(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      argumentsJson: jsonEncode(map['arguments'] ?? {}),
    );
  }

  factory ToolCallInfo.fromLlmDart(llm.ToolCall tc) {
    return ToolCallInfo(
      id: tc.id,
      name: tc.function.name,
      argumentsJson: tc.function.arguments,
    );
  }
}

/// 工具执行结果（分组存储中的单个 result 条目）
class ToolResultInfo {
  final String toolCallId;
  final String content;
  final bool isError;
  final String? name;

  const ToolResultInfo({
    required this.toolCallId,
    required this.content,
    this.isError = false,
    this.name,
  });

  Map<String, dynamic> toMap() => {
    'toolCallId': toolCallId,
    'content': content,
    if (isError) 'isError': true,
    if (name != null) 'name': name,
  };

  factory ToolResultInfo.fromMap(Map<String, dynamic> map) {
    return ToolResultInfo(
      toolCallId: map['toolCallId'] as String? ?? '',
      content: map['content'] as String? ?? '',
      isError: map['isError'] as bool? ?? false,
      name: map['name'] as String?,
    );
  }
}

/// 项目内部统一消息类型
///
/// 解耦 langchain 和 llm_dart 的消息类型，
/// 在 session_memory_manager、context_compressor、token_estimator 中使用。
class ChatMsg {
  final ChatMsgRole role;
  final String content;
  final List<ToolCallInfo>? toolCalls;
  final String? toolCallId;
  final bool isError;
  final String? name;

  /// 分组存储的多个工具执行结果（用于 llm_dart 的 toolResult）
  final List<ToolResultInfo>? toolResults;

  const ChatMsg({
    required this.role,
    this.content = '',
    this.toolCalls,
    this.toolCallId,
    this.isError = false,
    this.name,
    this.toolResults,
  });

  /// 是否为分组 tool result 消息
  bool get isToolResultGroup =>
      role == ChatMsgRole.tool &&
      toolResults != null &&
      toolResults!.isNotEmpty;

  // ===== 工厂构造函数 =====

  factory ChatMsg.user(String content) =>
      ChatMsg(role: ChatMsgRole.user, content: content);

  factory ChatMsg.assistant(String content, {List<ToolCallInfo>? toolCalls}) =>
      ChatMsg(role: ChatMsgRole.assistant, content: content, toolCalls: toolCalls);

  factory ChatMsg.system(String content, {String? name}) =>
      ChatMsg(role: ChatMsgRole.system, content: content, name: name);

  /// 单条 tool result（向后兼容）
  factory ChatMsg.toolResult({
    required String toolCallId,
    required String content,
    bool isError = false,
    String? name,
  }) =>
      ChatMsg(
        role: ChatMsgRole.tool,
        content: content,
        toolCallId: toolCallId,
        isError: isError,
        name: name,
      );

  /// 分组 tool result（一轮工具调用的多个结果合并为一条消息）
  factory ChatMsg.toolResultGroup(List<ToolResultInfo> results) => ChatMsg(
        role: ChatMsgRole.tool,
        toolResults: results,
      );

  // ===== 序列化 =====

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'role': role.name,
      'content': content,
      if (name != null) 'name': name,
    };

    if (role == ChatMsgRole.assistant && toolCalls != null && toolCalls!.isNotEmpty) {
      map['toolCalls'] = toolCalls!.map((tc) => tc.toMap()).toList();
    }

    if (role == ChatMsgRole.tool) {
      if (isToolResultGroup) {
        // 分组格式：toolResults 字段
        map['toolResults'] = toolResults!.map((r) => r.toMap()).toList();
      } else {
        // 单条格式：向后兼容
        map['toolCallId'] = toolCallId;
        if (isError) map['isError'] = true;
        if (name != null) map['name'] = name;
      }
    }

    return map;
  }

  factory ChatMsg.fromMap(Map<String, dynamic> map) {
    final roleStr = map['role'] as String? ?? 'user';
    final role = ChatMsgRole.values.firstWhere(
      (e) => e.name == roleStr,
      orElse: () => ChatMsgRole.user,
    );

    List<ToolCallInfo>? toolCalls;
    if (map['toolCalls'] != null) {
      final list = map['toolCalls'];
      if (list is String && list.isNotEmpty) {
        toolCalls = (jsonDecode(list) as List)
            .map((tc) => ToolCallInfo.fromMap(tc as Map<String, dynamic>))
            .toList();
      } else if (list is List) {
        toolCalls = list
            .map((tc) => ToolCallInfo.fromMap(tc as Map<String, dynamic>))
            .toList();
      }
    }

    // 分组 tool result 格式
    List<ToolResultInfo>? toolResults;
    if (role == ChatMsgRole.tool && map['toolResults'] != null) {
      final list = map['toolResults'];
      if (list is String && list.isNotEmpty) {
        toolResults = (jsonDecode(list) as List)
            .map((r) => ToolResultInfo.fromMap(r as Map<String, dynamic>))
            .toList();
      } else if (list is List) {
        toolResults = list
            .map((r) => ToolResultInfo.fromMap(r as Map<String, dynamic>))
            .toList();
      }
    }

    return ChatMsg(
      role: role,
      content: map['content'] as String? ?? '',
      toolCalls: toolCalls,
      toolCallId: map['toolCallId'] as String?,
      isError: map['isError'] as bool? ?? false,
      name: map['name'] as String?,
      toolResults: toolResults,
    );
  }

  // ===== 与 llm_dart 互转 =====

  /// 转换为 llm_dart ChatMessage
  llm.ChatMessage toLlmDart() {
    switch (role) {
      case ChatMsgRole.user:
        return llm.ChatMessage.user(content);
      case ChatMsgRole.assistant:
        if (toolCalls != null && toolCalls!.isNotEmpty) {
          return llm.ChatMessage.toolUse(
            toolCalls: toolCalls!.map((tc) => llm.ToolCall(
              id: tc.id,
              callType: 'function',
              function: llm.FunctionCall(
                name: tc.name,
                arguments: tc.argumentsJson,
              ),
            )).toList(),
            content: content,
          );
        }
        return llm.ChatMessage.assistant(content);
      case ChatMsgRole.system:
        return llm.ChatMessage.system(content, name: name);
      case ChatMsgRole.tool:
        if (isToolResultGroup) {
          // 分组格式：将多个 toolResult 合并为一条 llm.ChatMessage.toolResult
          final results = toolResults!.map((r) {
            final resultArguments = r.isError
                ? jsonEncode({'error': r.content})
                : jsonEncode({'result': r.content});
            return llm.ToolCall(
              id: r.toolCallId,
              callType: 'function',
              function: llm.FunctionCall(
                name: r.name ?? '',
                arguments: resultArguments,
              ),
            );
          }).toList();
          return llm.ChatMessage.toolResult(
            results: results,
            content: toolResults!.map((r) => r.content).join('\n'),
          );
        }
        // 单条格式（向后兼容）
        final resultArguments = isError
            ? jsonEncode({'error': content})
            : jsonEncode({'result': content});
        return llm.ChatMessage.toolResult(
          results: [
            llm.ToolCall(
              id: toolCallId ?? '',
              callType: 'function',
              function: llm.FunctionCall(
                name: name ?? '',
                arguments: resultArguments,
              ),
            ),
          ],
          content: content,
        );
    }
  }

  /// 从 llm_dart ChatMessage 创建
  factory ChatMsg.fromLlmDart(llm.ChatMessage msg) {
    switch (msg.role) {
      case llm.ChatRole.user:
        return ChatMsg.user(msg.content);
      case llm.ChatRole.assistant:
        // 检查是否是 tool_use 类型消息
        if (msg.messageType is llm.ToolUseMessage) {
          final toolUse = msg.messageType as llm.ToolUseMessage;
          return ChatMsg.assistant(
            msg.content,
            toolCalls: toolUse.toolCalls
                .map((tc) => ToolCallInfo.fromLlmDart(tc))
                .toList(),
          );
        }
        return ChatMsg.assistant(msg.content);
      case llm.ChatRole.system:
        return ChatMsg.system(msg.content, name: msg.name);
    }
  }

  /// 从 llm_dart ChatResponse 创建 assistant 消息（流式完成时）
  factory ChatMsg.fromLlmDartResponse(llm.ChatResponse response) {
    return ChatMsg.assistant(
      response.text ?? '',
      toolCalls: response.toolCalls
          ?.map((tc) => ToolCallInfo.fromLlmDart(tc))
          .toList(),
    );
  }
}
