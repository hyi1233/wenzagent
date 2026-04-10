import 'dart:async';
import 'dart:io';

import '../agent_tool.dart';

/// 命令执行工具
///
/// 执行 shell 命令并返回输出。
/// 支持中断正在执行的命令。
class CommandExecuteTool extends AgentTool {
  /// 当前正在执行的进程
  Process? _currentProcess;

  /// 是否被取消
  bool _isCancelled = false;

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
  String get permissionArgKey => 'command';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final command = arguments['command'] as String?;
    if (command == null || command.isEmpty) {
      return ToolResult.error('参数错误: command 不能为空');
    }

    final workingDirectory = arguments['workingDirectory'] as String?;
    final timeout = arguments['timeout'] as int? ?? 30;

    _isCancelled = false;
    _currentProcess = null;

    try {
      // 根据平台启动进程
      if (Platform.isWindows) {
        _currentProcess = await Process.start(
          'cmd',
          ['/c', command],
          workingDirectory: workingDirectory,
          runInShell: false,
        );
      } else {
        _currentProcess = await Process.start(
          'sh',
          ['-c', command],
          workingDirectory: workingDirectory,
          runInShell: false,
        );
      }

      // 创建取消监听器
      final cancellationCompleter = Completer<Map<String, dynamic>>();
      final outputCompleter = Completer<Map<String, dynamic>>();
      
      // 监听取消
      StreamSubscription? cancelMonitor;
      cancelMonitor = await _createCancellationMonitor(cancellationCompleter);
      
      // 监听进程输出和退出
      _monitorProcessOutput(
        _currentProcess!,
        outputCompleter,
      );

      // 设置超时
      final timeoutFuture = Future.delayed(
        Duration(seconds: timeout),
        () => {'timeout': true},
      );

      // 等待：进程完成、超时或取消
      final result = await Future.any([
        outputCompleter.future,
        timeoutFuture,
        cancellationCompleter.future,
      ]);

      // 清理监听器
      await cancelMonitor.cancel();
      
      // 处理结果
      if (result['cancelled'] == true) {
        _killProcess();
        return ToolResult.error('命令执行被取消: $command');
      }

      if (result['timeout'] == true) {
        _killProcess();
        return ToolResult.error('命令执行超时 (${timeout}s): $command');
      }

      final exitCode = result['exitCode'] as int;
      final stdout = result['stdout'] as String;
      final stderr = result['stderr'] as String;

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
      return ToolResult.error('执行命令失败: $e');
    } finally {
      _currentProcess = null;
    }
  }

  /// 创建取消监听器
  Future<StreamSubscription> _createCancellationMonitor(
    Completer<Map<String, dynamic>> completer,
  ) async {
    // 使用定时器检查取消状态
    return Stream.periodic(Duration(milliseconds: 100)).listen((_) {
      if (_isCancelled && !completer.isCompleted) {
        completer.complete({'cancelled': true});
      }
    });
  }

  /// 监听进程输出和退出
  Future<void> _monitorProcessOutput(
    Process process,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      // 等待进程退出
      final exitCode = await process.exitCode;

      // 收集输出
      final stdout = await process.stdout.transform<String>(systemEncoding.decoder).join();
      final stderr = await process.stderr.transform<String>(systemEncoding.decoder).join();

      if (!completer.isCompleted) {
        completer.complete({
          'exitCode': exitCode,
          'stdout': stdout.trim(),
          'stderr': stderr.trim(),
        });
      }
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }
  }

  /// 取消正在执行的命令
  @override
  void cancel() {
    _isCancelled = true;
    _killProcess();
  }

  /// 杀死进程
  void _killProcess() {
    try {
      _currentProcess?.kill();
    } catch (e) {
      // 忽略杀死进程时的错误
    }
  }
}
