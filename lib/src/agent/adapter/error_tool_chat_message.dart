/// 支持错误状态标记的工具消息（已废弃）
///
/// 此类保留仅为向后兼容，新代码应使用 [ChatMessage.toolResult] 代替。
/// [ChatMessage] 通过 [isError] getter 和 metadata['isError'] 原生支持错误状态标记。
@Deprecated('Use ChatMessage.toolResult() instead')
class ErrorToolChatMessage {
  final String toolCallId;
  final String content;
  final bool isError;

  ErrorToolChatMessage({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });
}
