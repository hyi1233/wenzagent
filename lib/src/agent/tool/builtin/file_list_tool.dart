import 'dart:io';

import '../agent_tool.dart';

/// 文件列表工具
///
/// 列出指定目录下的文件和子目录。
class FileListTool extends AgentTool {
  @override
  String get name => 'file_list';

  @override
  String get description =>
      'List files and directories in the specified directory path. '
      'Returns a list of entries with their type (file/directory), name, and size.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'The directory path to list contents of',
      },
      'recursive': {
        'type': 'boolean',
        'description': 'If true, list contents recursively. Default: false',
      },
      'includeHidden': {
        'type': 'boolean',
        'description':
            'If true, include hidden files (starting with dot). Default: false',
      },
    },
    'required': ['path'],
  };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('参数错误: path 不能为空');
    }

    final dir = Directory(path);
    if (!await dir.exists()) {
      return ToolResult.error('目录不存在: $path');
    }

    final recursive = arguments['recursive'] as bool? ?? false;
    final includeHidden = arguments['includeHidden'] as bool? ?? false;

    try {
      final entries = <String>[];
      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        final name = entity.path.replaceFirst(
          '${dir.path}${Platform.pathSeparator}',
          '',
        );

        // 过滤隐藏文件
        if (!includeHidden) {
          final baseName = name.split(Platform.pathSeparator).last;
          if (baseName.startsWith('.')) continue;
        }

        final stat = await entity.stat();
        final type = stat.type == FileSystemEntityType.directory
            ? 'DIR'
            : 'FILE';
        final size = stat.type == FileSystemEntityType.file
            ? ' (${stat.size} bytes)'
            : '';
        entries.add('[$type] $name$size');
      }

      if (entries.isEmpty) {
        return ToolResult.success('目录为空: $path');
      }

      entries.sort();
      return ToolResult.success(entries.join('\n'));
    } catch (e) {
      return ToolResult.error('列出目录内容失败: $e');
    }
  }
}
