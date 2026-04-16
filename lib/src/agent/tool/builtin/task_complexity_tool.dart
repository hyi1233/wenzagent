import '../../../utils/logger.dart';
import '../agent_tool.dart';

/// 开发任务复杂度识别工具
///
/// 使用 invokeOnce 调用 LLM 对用户任务进行复杂度分析，
/// 返回任务等级（小型/中型/复杂）及建议执行策略。
///
/// 注入流程：
/// 1. BuiltinTools.all() 创建实例
/// 2. AgentImpl._injectTaskComplexityCallbacks() 注入 invokeLlm 回调
class TaskComplexityTool extends AgentTool {
  static final _log = Logger('TaskComplexityTool');

  /// 单次 LLM 调用回调（由 AgentImpl 通过 _chatAdapter.invokeOnce 注入）
  Future<String> Function(String prompt)? invokeLlm;

  @override
  String get name => 'task_complexity';

  @override
  String get description =>
      'Analyze the complexity of a development task and recommend an execution strategy. '
      'Uses AI to assess whether the task is small (direct execution), '
      'medium (todo-driven + sub-agent execution), or complex (spec-driven + phased execution).\n\n'
      'Call this tool when you receive a new user task to determine the appropriate execution approach. '
      'The analysis helps decide whether to proceed directly, create a todo list, or start with a spec.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'task': {
            'type': 'string',
            'description':
                'The user task description to analyze for complexity assessment.',
          },
          'context': {
            'type': 'string',
            'description':
                'Optional additional context about the current project, files involved, '
                'or any relevant information that helps assess task complexity.',
          },
        },
        'required': ['task'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final task = arguments['task'] as String?;
    if (task == null || task.isEmpty) {
      return ToolResult.error('task is required');
    }

    if (invokeLlm == null) {
      _log.warn('invokeLlm callback not injected');
      return ToolResult.error(
        'Task complexity analysis is not available. '
        'The LLM callback has not been configured.',
      );
    }

    final context = arguments['context'] as String?;

    final prompt = _buildAnalysisPrompt(task, context);

    try {
      final response = await invokeLlm!(prompt);
      if (response.isEmpty) {
        return ToolResult.error('AI returned empty analysis result');
      }
      return ToolResult.success(response);
    } catch (e) {
      _log.error('Task complexity analysis failed', e);
      return ToolResult.error('Task complexity analysis failed: $e');
    }
  }

  /// 构建任务复杂度分析的 prompt
  String _buildAnalysisPrompt(String task, String? context) {
    final buffer = StringBuffer();

    buffer.writeln('你是一个开发任务复杂度评估专家。请根据以下任务描述，判断其复杂度等级并给出执行建议。');
    buffer.writeln();
    buffer.writeln('## 任务分级标准');
    buffer.writeln();
    buffer.writeln('### 1. 小型任务 → 直接执行');
    buffer.writeln('适用于：单文件修改、简单查询、格式转换等可在 1-3 轮工具调用内完成的工作。');
    buffer.writeln('做法：主 Agent 直接使用工具完成，无需创建待办或规格文档。');
    buffer.writeln();
    buffer.writeln('### 2. 中型任务 → 待办驱动 + 子 Agent 执行');
    buffer.writeln('适用于：涉及多文件修改、需要多步骤完成、有明确预期的工作。');
    buffer.writeln('做法：');
    buffer.writeln('1. 使用 todo_manage 创建待办列表，将任务拆分为可独立执行的子项');
    buffer.writeln('2. 对每个待办项，使用 spawn_sub_agent 创建子 Agent 执行');
    buffer.writeln('3. 子 Agent 返回结果后，主 Agent 验收代码质量和需求满足度');
    buffer.writeln('4. 验收通过则标记待办为 completed，不通过则修正后重新执行');
    buffer.writeln('5. 所有待办完成后向用户汇报整体结果');
    buffer.writeln();
    buffer.writeln('### 3. 复杂任务 → Spec 驱动 + 分阶段执行');
    buffer.writeln('适用于：需求不够明确、涉及架构调整、需要多个中型任务协作的工作。');
    buffer.writeln('做法：');
    buffer.writeln('1. 提示用户创建 Spec，使用 spec_manage 记录需求规格');
    buffer.writeln('2. 与用户反复讨论、修正 Spec，直到需求完全对齐');
    buffer.writeln('3. 根据最终 Spec 拆分为多个中型任务，使用 todo_manage 创建待办列表');
    buffer.writeln('4. 按照中型任务的流程逐个执行');
    buffer.writeln('5. 所有待办完成后对照 Spec 做最终检查');
    buffer.writeln();
    buffer.writeln('## 待分析的任务');
    buffer.writeln();
    buffer.writeln(task);

    if (context != null && context.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## 补充上下文');
      buffer.writeln();
      buffer.writeln(context);
    }

    buffer.writeln();
    buffer.writeln('## 输出要求');
    buffer.writeln();
    buffer.writeln('请按以下格式输出分析结果：');
    buffer.writeln();
    buffer.writeln('**复杂度等级**：小型/中型/复杂');
    buffer.writeln();
    buffer.writeln('**判断依据**：(简要说明为什么是这个等级)');
    buffer.writeln();
    buffer.writeln('**执行策略**：(根据对应等级的做法，给出具体的执行步骤建议)');
    buffer.writeln();
    buffer.writeln('**注意事项**：(如有需要特别注意的风险或依赖项)');

    return buffer.toString();
  }
}
