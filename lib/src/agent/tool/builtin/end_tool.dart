import '../agent_tool.dart';

/// 结束对话工具
///
/// 允许 AI 主动结束工具调用循环，避免无意义的重复调用。
/// 当 AI 认为当前任务已完成、无需继续操作时，应调用此工具。
class EndTool extends AgentTool {
  @override
  String get name => 'end';

  @override
  String get description => '''
End the current conversation loop.

Call this tool when:
- The task is fully completed and no further actions are needed.
- You have gathered enough information and want to provide a final response to the user.
- You determine that continuing the tool-calling loop would be unproductive.

This tool signals the system to stop processing and show the current results to the user.
You can provide a brief reason via the 'reason' parameter.
''';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'reason': {
        'type': 'string',
        'description': 'Optional brief reason for ending the conversation (e.g., "task completed", "user question answered")',
      },
    },
    'required': [],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final reason = arguments['reason'] as String? ?? '';
    final message = reason.isNotEmpty
        ? '对话已结束: $reason'
        : '对话已结束';
    return ToolResult.success(message);
  }
}
