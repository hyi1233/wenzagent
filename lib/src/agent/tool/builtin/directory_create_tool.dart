import 'dart:io';

import '../agent_tool.dart';

/// 目录创建工具
///
/// 创建新目录，支持递归创建父目录。
class DirectoryCreateTool extends AgentTool {
  @override
  String get name => 'directory_create';

  @override
  String get description =>
      'Create a new directory at the specified path. '
      'Set recursive to true to create parent directories as needed.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'The path of the directory to create',
      },
      'recursive': {
        'type': 'boolean',
        'description':
            'If true, create parent directories if they do not exist. Default: true',
      },
    },
    'required': ['path'],
  };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'file_write';

  @override
  String get permissionArgKey => 'path';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('参数错误: path 不能为空');
    }

    final recursive = arguments['recursive'] as bool? ?? true;

    try {
      final dir = Directory(path);

      if (await dir.exists()) {
        return ToolResult.success('目录已存在: $path');
      }

      await dir.create(recursive: recursive);
      return ToolResult.success('目录已创建: $path');
    } catch (e) {
      return ToolResult.error('创建目录失败: $e');
    }
  }
}
