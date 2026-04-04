import 'dart:io';

import '../agent_tool.dart';

/// 命令执行工具
///
/// 执行 shell 命令并返回输出。
class CommandExecuteTool extends AgentTool {
  @override
  String get name => 'command_execute';

  @override
  String get description =>
      'Execute a shell command and return its output (stdout and stderr). '
      'Use with caution. The command runs in the system shell.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'command': {
        'type': 'string',
        'description': 'The shell command to execute',
      },
      'workingDirectory': {
        'type': 'string',
        'description':
            'The working directory for the command. Default: current directory',
      },
      'timeout': {
        'type': 'integer',
        'description':
            'Timeout in seconds. The command will be killed if it exceeds this. Default: 30',
      },
    },
    'required': ['command'],
  };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'command_execute';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final command = arguments['command'] as String?;
    if (command == null || command.isEmpty) {
      return ToolResult.error('参数错误: command 不能为空');
    }

    final workingDirectory = arguments['workingDirectory'] as String?;
    final timeout = arguments['timeout'] as int? ?? 30;

    try {
      // 根据平台选择 shell
      final ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run(
          'cmd',
          ['/c', command],
          workingDirectory: workingDirectory,
          runInShell: false,
        ).timeout(Duration(seconds: timeout));
      } else {
        result = await Process.run(
          'sh',
          ['-c', command],
          workingDirectory: workingDirectory,
          runInShell: false,
        ).timeout(Duration(seconds: timeout));
      }

      final stdout = (result.stdout as String).trim();
      final stderr = (result.stderr as String).trim();
      final exitCode = result.exitCode;

      final output = StringBuffer();
      output.writeln('Exit code: $exitCode');
      if (stdout.isNotEmpty) {
        output.writeln('--- stdout ---');
        output.writeln(stdout);
      }
      if (stderr.isNotEmpty) {
        output.writeln('--- stderr ---');
        output.writeln(stderr);
      }

      return ToolResult(
        content: output.toString().trim(),
        isError: exitCode != 0,
        metadata: {'exitCode': exitCode, 'command': command},
      );
    } on ProcessException catch (e) {
      return ToolResult.error('执行命令失败: ${e.message}');
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        return ToolResult.error('命令执行超时 (${timeout}s): $command');
      }
      return ToolResult.error('执行命令失败: $e');
    }
  }
}
