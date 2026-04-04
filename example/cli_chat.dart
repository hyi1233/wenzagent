import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// ============================================================
/// WenzAgent CLI 交互式对话工具
/// ============================================================
///
/// 用于测试完整的对话功能、Tool Use 和权限确认流程。
///
/// 使用方法:
///   dart run example/cli_chat.dart
///
/// 环境变量（可选，也可以交互式输入）:
///   LLM_API_KEY   - API 密钥
///   LLM_BASE_URL  - API 基础 URL（如 https://api.openai.com/v1）
///   LLM_MODEL     - 模型名称（如 gpt-4o）
///
/// 对话中命令:
///   /quit         - 退出
///   /tools        - 查看已注册的工具列表
///   /clear        - 清空当前会话
///   /help         - 显示帮助信息
///
void main() async {
  _printBanner();

  // 1. 获取 LLM 配置
  final config = _getProviderConfig();
  if (config == null) {
    print('\n[ERROR] 无法获取 LLM 配置，退出。');
    return;
  }

  // 2. 初始化适配器
  final adapter = LangChainChatAdapter();
  await adapter.initSession(employeeUuid: 'cli-user');

  try {
    await adapter.updateProvider(config);
  } catch (e) {
    print('\n[ERROR] Provider 配置失败: $e');
    return;
  }

  // 3. 注册工具
  final registry = ToolRegistry();
  registry.registerTools(BuiltinTools.all());
  adapter.setToolRegistry(registry);

  // 4. 配置权限管理器（交互式确认）
  final permManager = ToolPermissionManager();
  permManager.onPermissionRequest = (request) async {
    return _interactivePermissionPrompt(request);
  };
  adapter.setPermissionManager(permManager);

  // 5. 配置工具事件回调（日志）
  adapter.setToolEventCallback((event) {
    // 事件已在主流中处理，此处做额外日志记录（可选）
  });

  // 6. 设置系统提示
  adapter.setContext({
    'systemPrompt': '你是一个有用的助手，可以使用工具来帮助用户完成文件操作和命令执行等任务。'
        '当用户请求涉及文件系统操作或命令执行时，请主动使用相应的工具来完成。'
        '回答请使用中文。',
  });

  print('\n已注册 ${registry.length} 个工具:');
  for (final tool in registry.tools) {
    final perm = tool.requiresPermission ? ' [需权限]' : '';
    print('  - ${tool.name}$perm: ${_truncate(tool.description, 60)}');
  }

  print('\n${'=' * 60}');
  print('开始对话！输入 /help 查看命令。');
  print('${'=' * 60}\n');

  // 7. 主对话循环
  while (true) {
    stdout.write('你: ');
    final input = stdin.readLineSync();
    if (input == null) break;

    final trimmed = input.trim();
    if (trimmed.isEmpty) continue;

    // 处理命令
    if (trimmed.startsWith('/')) {
      final handled = _handleCommand(trimmed, registry, adapter);
      if (handled == _CommandResult.quit) break;
      continue;
    }

    // 发送消息并处理流式响应
    await _processMessage(adapter, trimmed);
    print(''); // 空行分隔
  }

  // 8. 清理
  await adapter.dispose();
  print('\n再见！');
}

// ============================================================
// 消息处理
// ============================================================

Future<void> _processMessage(LangChainChatAdapter adapter, String input) async {
  stdout.write('\n助手: ');

  final messageData = {
    'id': 'msg_${DateTime.now().millisecondsSinceEpoch}',
    'content': input,
  };

  bool hasTextOutput = false;

  try {
    await for (final response in adapter.streamMessage(messageData)) {
      // 错误
      if (response.error != null) {
        if (hasTextOutput) stdout.writeln();
        print('\n[ERROR] ${response.error}');
        return;
      }

      // 工具事件
      if (response.type != null) {
        _handleToolEvent(response, hasTextOutput);
        // 工具事件后可能还有文本输出，标记需要重新开始打印前缀
        if (response.type == 'toolCallResult') {
          hasTextOutput = false;
        }
        continue;
      }

      // 文本 chunk
      if (response.content != null && response.content!.isNotEmpty) {
        if (!hasTextOutput) {
          hasTextOutput = true;
        }
        stdout.write(response.content);
      }

      // 完成
      if (response.isDone) {
        if (hasTextOutput) stdout.writeln();
        break;
      }
    }
  } catch (e) {
    print('\n[ERROR] 消息处理异常: $e');
  }

  if (!hasTextOutput) {
    // 如果没有任何文本输出（可能只有工具调用），换行
  }
}

void _handleToolEvent(StreamResponse response, bool hadText) {
  final data = response.data ?? {};

  switch (response.type) {
    case 'toolCallStart':
      if (hadText) stdout.writeln();
      final name = data['toolName'] ?? 'unknown';
      final args = data['arguments'] ?? {};
      print('\n  ┌─ 工具调用: $name');
      // 打印参数（简洁格式）
      final argStr = _formatArgs(args);
      if (argStr.isNotEmpty) {
        print('  │  参数: $argStr');
      }
      print('  │  执行中...');

    case 'toolCallResult':
      final name = data['toolName'] ?? 'unknown';
      final result = data['result'] as String? ?? '';
      final isError = data['isError'] as bool? ?? false;
      final durationMs = data['durationMs'] as int?;
      final status = isError ? 'FAIL' : 'OK';
      final duration = durationMs != null ? ' (${durationMs}ms)' : '';

      // 结果预览（限制长度）
      final preview = _truncate(result.replaceAll('\n', '\\n'), 120);
      print('  │  结果[$status]$duration: $preview');
      print('  └─ 工具 $name 完成\n');
      stdout.write('助手: ');

    default:
      break;
  }
}

// ============================================================
// 权限交互
// ============================================================

Future<PermissionDecision> _interactivePermissionPrompt(
  AgentPermissionRequest request,
) async {
  print('\n  ┌─────────────────────────────────────');
  print('  │  权限请求');
  print('  │  工具: ${request.functionName}');
  print('  │  描述: ${request.description}');

  // 显示工具参数
  final toolArgs = request.data?['arguments'] as Map<String, dynamic>?;
  if (toolArgs != null && toolArgs.isNotEmpty) {
    print('  │  参数:');
    for (final entry in toolArgs.entries) {
      final value = _truncate(entry.value.toString(), 80);
      print('  │    ${entry.key}: $value');
    }
  }

  print('  │');
  print('  │  [y] 允许  [n] 拒绝  [a] 始终允许');
  print('  └─────────────────────────────────────');
  stdout.write('  选择: ');

  final input = stdin.readLineSync()?.trim().toLowerCase() ?? 'n';

  switch (input) {
    case 'y':
    case 'yes':
      print('  -> 已允许\n');
      return PermissionDecision.allow;
    case 'a':
    case 'always':
      print('  -> 已允许（后续自动批准同类操作）\n');
      return PermissionDecision.allowAlways;
    default:
      print('  -> 已拒绝\n');
      return PermissionDecision.deny;
  }
}

// ============================================================
// 命令处理
// ============================================================

enum _CommandResult { handled, quit }

_CommandResult _handleCommand(
  String command,
  ToolRegistry registry,
  LangChainChatAdapter adapter,
) {
  switch (command.toLowerCase()) {
    case '/quit':
    case '/exit':
    case '/q':
      return _CommandResult.quit;

    case '/help':
    case '/h':
      _printHelp();
      return _CommandResult.handled;

    case '/tools':
      _printTools(registry);
      return _CommandResult.handled;

    case '/clear':
      adapter.clearCurrentSession();
      print('[INFO] 会话已清空。\n');
      return _CommandResult.handled;

    default:
      print('[WARN] 未知命令: $command  (输入 /help 查看可用命令)\n');
      return _CommandResult.handled;
  }
}

void _printHelp() {
  print('''
┌─ 命令帮助 ─────────────────────────────
│  /help, /h      显示此帮助信息
│  /tools         查看已注册工具列表
│  /clear         清空当前会话历史
│  /quit, /q      退出程序
│
│  提示: 直接输入自然语言与 AI 对话。
│  AI 会根据需要自动调用工具。
│  需要权限的操作会弹出确认提示。
└─────────────────────────────────────────
''');
}

void _printTools(ToolRegistry registry) {
  print('\n┌─ 已注册工具 (${registry.length}) ─────────────');
  for (final tool in registry.tools) {
    final perm = tool.requiresPermission ? ' [需权限]' : '';
    print('│  ${tool.name}$perm');
    print('│    ${_truncate(tool.description, 70)}');
  }
  print('└─────────────────────────────────────────\n');
}

// ============================================================
// 配置获取
// ============================================================

Map<String, dynamic>? _getProviderConfig() {
  print('配置 LLM Provider');
  print('-' * 40);

  // 优先读取环境变量
  final envApiKey = Platform.environment['LLM_API_KEY'];
  final envBaseUrl = Platform.environment['LLM_BASE_URL'];
  final envModel = Platform.environment['LLM_MODEL'];

  String? apiKey = envApiKey;
  String? baseUrl = envBaseUrl;
  String? model = envModel;

  if (envApiKey != null && envApiKey.isNotEmpty) {
    print('  从环境变量读取:');
    print('  API Key: ${_maskKey(envApiKey)}');
    if (envBaseUrl != null) print('  Base URL: $envBaseUrl');
    if (envModel != null) print('  Model: $envModel');
  }

  // 交互式补充缺失配置
  if (apiKey == null || apiKey.isEmpty) {
    stdout.write('  API Key: ');
    apiKey = stdin.readLineSync()?.trim();
    if (apiKey == null || apiKey.isEmpty) {
      return null;
    }
  }

  if (baseUrl == null || baseUrl.isEmpty) {
    stdout.write('  Base URL (回车使用 https://api.openai.com/v1): ');
    final input = stdin.readLineSync()?.trim();
    baseUrl = (input != null && input.isNotEmpty) ? input : null;
  }

  if (model == null || model.isEmpty) {
    stdout.write('  Model (回车使用 gpt-4o): ');
    final input = stdin.readLineSync()?.trim();
    model = (input != null && input.isNotEmpty) ? input : 'gpt-4o';
  }

  return {
    'provider': 'openai',
    'model': model,
    'apiKey': apiKey,
    if (baseUrl != null) 'baseUrl': baseUrl,
    'options': {'temperature': 0.7},
  };
}

// ============================================================
// 工具函数
// ============================================================

void _printBanner() {
  print('''
============================================================
  WenzAgent CLI Chat
  交互式对话 + Tool Use + 权限确认 测试工具
============================================================
''');
}

String _truncate(String text, int maxLen) {
  if (text.length <= maxLen) return text;
  return '${text.substring(0, maxLen - 3)}...';
}

String _maskKey(String key) {
  if (key.length <= 8) return '****';
  return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
}

String _formatArgs(Map<String, dynamic> args) {
  if (args.isEmpty) return '';
  final parts = <String>[];
  for (final entry in args.entries) {
    final value = _truncate(entry.value.toString(), 60);
    parts.add('${entry.key}=$value');
  }
  return parts.join(', ');
}
