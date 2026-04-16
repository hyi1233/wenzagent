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
结束当前对话循环。

在以下情况调用此工具：
- 任务已完成，无需进一步操作。
- 已收集足够信息，准备向用户提供最终回复。
- 判断继续工具调用循环不会有更多产出。

此工具通知系统停止处理并向用户展示当前结果。
可通过 'reason' 参数提供简短说明。
''';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'reason': {
        'type': 'string',
        'description': '可选的结束原因说明（例如："任务完成"、"用户问题已回答"）',
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
