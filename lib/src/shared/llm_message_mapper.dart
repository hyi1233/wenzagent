/// ChatMessage ↔ llm_dart 转换器
///
/// 将统一消息模型转换为 llm_dart 库所需的格式，
/// 同时保留合并连续 tool result 的逻辑。
library;

import 'dart:convert';

import 'package:llm_dart/llm_dart.dart' as llm;

import 'chat_message.dart';

/// ChatMessage 与 llm_dart ChatMessage 的双向映射器
///
/// 职责：
/// 1. ChatMessage → llm.ChatMessage（发送给 LLM 前）
/// 2. llm.ChatMessage → ChatMessage（收到 LLM 响应后）
/// 3. 合并连续 tool result 消息（OpenAI 兼容性）
class LlmMessageMapper {
  // ── ChatMessage → llm_dart ──

  /// 将 ChatMessage 转换为 llm_dart 的 ChatMessage
  static llm.ChatMessage toLlmDart(ChatMessage msg) {
    switch (msg.role) {
      case MessageRole.user:
        return llm.ChatMessage.user(msg.content ?? '');

      case MessageRole.assistant:
        // 包含多工具调用
        if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
          return llm.ChatMessage.toolUse(
            toolCalls: msg.toolCalls!.map((tc) => llm.ToolCall(
                  id: tc.id,
                  callType: 'function',
                  function: llm.FunctionCall(
                    name: tc.name,
                    arguments: tc.argumentsJson,
                  ),
                )).toList(),
            content: msg.content ?? '',
          );
        }
        // 包含单工具调用（向后兼容）
        if (msg.toolCallId != null && msg.toolName != null) {
          final argsJson = msg.toolArguments != null
              ? jsonEncode(msg.toolArguments)
              : '{}';
          return llm.ChatMessage.toolUse(
            toolCalls: [
              llm.ToolCall(
                id: msg.toolCallId!,
                callType: 'function',
                function: llm.FunctionCall(
                  name: msg.toolName!,
                  arguments: argsJson,
                ),
              ),
            ],
            content: msg.content ?? '',
          );
        }
        return llm.ChatMessage.assistant(msg.content ?? '');

      case MessageRole.system:
        return llm.ChatMessage.system(msg.content ?? '');

      case MessageRole.tool:
        if (msg.isToolResultGroup) {
          // 分组 tool result：将多个 ToolResult 合并为一条 llm.ChatMessage.toolResult
          final results = msg.toolResults!.map((r) {
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
            content: msg.toolResults!.map((r) => r.content).join('\n'),
          );
        }
        // 单条 tool result
        final resultArguments = msg.isError
            ? jsonEncode({'error': msg.content ?? ''})
            : jsonEncode({'result': msg.content ?? ''});
        return llm.ChatMessage.toolResult(
          results: [
            llm.ToolCall(
              id: msg.toolCallId ?? '',
              callType: 'function',
              function: llm.FunctionCall(
                name: msg.toolName ?? '',
                arguments: resultArguments,
              ),
            ),
          ],
          content: msg.content ?? '',
        );
    }
  }

  /// 批量转换 ChatMessage → llm_dart
  static List<llm.ChatMessage> toLlmDartList(List<ChatMessage> messages) {
    return messages.map(toLlmDart).toList();
  }

  // ── llm_dart → ChatMessage ──

  /// 从 llm_dart ChatMessage 创建 ChatMessage
  ///
  /// [employeeId] 必须由调用方提供。
  /// [id] 如果为 null 则自动生成。
  static ChatMessage fromLlmDart(
    llm.ChatMessage msg, {
    required String employeeId,
    String? id,
  }) {
    switch (msg.role) {
      case llm.ChatRole.user:
        return ChatMessage.user(
          id: id ?? '',
          employeeId: employeeId,
          content: msg.content,
        );

      case llm.ChatRole.assistant:
        // 检查是否是 tool_use 类型
        if (msg.messageType is llm.ToolUseMessage) {
          final toolUse = msg.messageType as llm.ToolUseMessage;
          return ChatMessage.assistant(
            id: id ?? '',
            employeeId: employeeId,
            content: msg.content,
            toolCalls: toolUse.toolCalls.map((tc) => ToolCall(
                  id: tc.id,
                  name: tc.function.name,
                  arguments: _parseArguments(tc.function.arguments),
                )).toList(),
          );
        }
        return ChatMessage.assistant(
          id: id ?? '',
          employeeId: employeeId,
          content: msg.content,
        );

      case llm.ChatRole.system:
        return ChatMessage.system(
          id: id ?? '',
          employeeId: employeeId,
          content: msg.content,
          createdAt: DateTime.now(),
        );
    }
  }

  /// 从 llm_dart ChatResponse 创建 assistant ChatMessage（流式完成时）
  static ChatMessage fromLlmDartResponse(
    llm.ChatResponse response, {
    required String employeeId,
    String? id,
  }) {
    return ChatMessage.assistant(
      id: id ?? '',
      employeeId: employeeId,
      content: response.text ?? '',
      toolCalls: response.toolCalls?.map((tc) => ToolCall(
            id: tc.id,
            name: tc.function.name,
            arguments: _parseArguments(tc.function.arguments),
          )).toList(),
    );
  }

  // ── 连续 tool result 合并 ──

  /// 将连续的 tool 角色消息合并为分组消息
  ///
  /// 在 OpenAI 协议中，一轮 assistant tool_calls 后跟的多个 tool result
  /// 应作为一组传递，确保 tool_call_id 对应关系正确。
  /// 与原 SessionMemoryManager._mergeConsecutiveToolMessages 逻辑一致。
  static List<ChatMessage> mergeConsecutiveToolResults(
      List<ChatMessage> messages) {
    if (messages.isEmpty) return messages;

    final result = <ChatMessage>[];
    List<ToolResult>? pendingResults;

    for (final msg in messages) {
      if (msg.role == MessageRole.tool && !msg.isToolResultGroup) {
        // 单条 tool result → 加入待合并缓冲区
        pendingResults ??= [];
        pendingResults.add(ToolResult(
          toolCallId: msg.toolCallId ?? '',
          content: msg.content ?? '',
          isError: msg.isError,
          name: msg.toolName,
        ));
      } else {
        // 非 tool 消息 → 先刷新缓冲区
        if (pendingResults != null) {
          result.add(ChatMessage.toolResultGroup(
            id: result.isEmpty ? '' : '', // ID 由调用方按需赋值
            employeeId: '',
            results: pendingResults,
            createdAt: msg.createdAt,
          ));
          pendingResults = null;
        }
        result.add(msg);
      }
    }

    // 刷新末尾剩余的 tool results
    if (pendingResults != null) {
      result.add(ChatMessage.toolResultGroup(
        id: '',
        employeeId: '',
        results: pendingResults,
      ));
    }

    return result;
  }

  // ── 内部工具 ──

  /// 解析工具参数 JSON 字符串为 Map
  static Map<String, dynamic> _parseArguments(String argumentsJson) {
    if (argumentsJson.isEmpty) return {};
    try {
      return jsonDecode(argumentsJson) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
