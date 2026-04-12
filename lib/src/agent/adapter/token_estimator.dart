import 'chat_msg.dart';

/// Token 估算器抽象基类
///
/// 由于 Dart 没有 tiktoken 实现，使用基于字符数的启发式方法估算 token 数量。
abstract class TokenEstimator {
  /// 估算文本的 token 数量
  int estimateTokens(String text);

  /// 估算单条 ChatMsg 的 token 数量
  ///
  /// 包含消息角色 overhead（约 4 tokens）和内容。
  /// 对于 assistant 消息会额外计算 toolCalls 元数据。
  /// 对于 tool 消息会额外计算 toolCallId。
  int estimateMessageTokens(ChatMsg message);

  /// 估算消息列表的总 token 数量
  int estimateMessagesTotal(List<ChatMsg> messages) {
    var total = 0;
    for (final message in messages) {
      total += estimateMessageTokens(message);
    }
    // 每次请求约有 3 tokens 的额外 overhead
    total += 3;
    return total;
  }
}

/// 基于字符数的 Token 估算器
///
/// 使用可配置的 chars-per-token 比率进行估算。
/// 默认值 3.5 是一个偏保守的值（略微高估 token 数），
/// 适用于英文/中文/代码混合场景。
///
/// 参考:
/// - 英文文本约 4 chars/token
/// - 中文文本约 1.5-2 chars/token
/// - 代码约 3-4 chars/token
/// - 3.5 作为混合场景的保守默认值
class CharBasedTokenEstimator extends TokenEstimator {
  /// 每个 token 对应的平均字符数
  final double charsPerToken;

  /// 每条消息的固定 overhead（角色标记、格式等）
  static const int _messageOverhead = 4;

  CharBasedTokenEstimator({this.charsPerToken = 3.5});

  @override
  int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    return (text.length / charsPerToken).ceil();
  }

  @override
  int estimateMessageTokens(ChatMsg message) {
    var tokens = _messageOverhead;

    // 内容文本
    tokens += estimateTokens(message.content);

    // assistant 消息额外计算 toolCalls 元数据
    if (message.role == ChatMsgRole.assistant && message.toolCalls != null && message.toolCalls!.isNotEmpty) {
      for (final tc in message.toolCalls!) {
        // tool call ID
        tokens += estimateTokens(tc.id);
        // tool name
        tokens += estimateTokens(tc.name);
        // arguments JSON
        try {
          final argsJson = tc.argumentsJson;
          tokens += estimateTokens(argsJson);
        } catch (_) {
          tokens += 20; // fallback
        }
      }
    }

    // tool 消息额外计算 toolCallId
    if (message.role == ChatMsgRole.tool) {
      if (message.isToolResultGroup) {
        // 分组格式：估算每个 result 的 token
        for (final r in message.toolResults!) {
          tokens += estimateTokens(r.toolCallId);
          if (r.name != null) tokens += estimateTokens(r.name!);
          tokens += estimateTokens(r.content);
        }
      } else {
        tokens += estimateTokens(message.toolCallId ?? '');
      }
    }

    return tokens;
  }
}
