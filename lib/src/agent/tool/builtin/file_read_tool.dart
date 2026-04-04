import 'dart:io';

import '../agent_tool.dart';

/// 文件读取工具
///
/// 读取指定路径文件的内容，支持行偏移和行数限制。
class FileReadTool extends AgentTool {
  @override
  String get name => 'file_read';

  @override
  String get description =>
      'Read the contents of a file at the specified path. '
      'Returns the file content as text. '
      'Optionally specify offset (line number to start from, 0-based) '
      'and limit (maximum number of lines to read).';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'The absolute or relative path to the file to read',
      },
      'offset': {
        'type': 'integer',
        'description':
            'Line number to start reading from (0-based). Default: 0',
      },
      'limit': {
        'type': 'integer',
        'description':
            'Maximum number of lines to read. Default: read all lines',
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

    final file = File(path);
    if (!await file.exists()) {
      return ToolResult.error('文件不存在: $path');
    }

    try {
      final content = await file.readAsString();
      final offset = arguments['offset'] as int? ?? 0;
      final limit = arguments['limit'] as int?;

      if (offset > 0 || limit != null) {
        final lines = content.split('\n');
        final start = offset.clamp(0, lines.length);
        final end = limit != null
            ? (start + limit).clamp(start, lines.length)
            : lines.length;
        final sliced = lines.sublist(start, end);
        // 添加行号
        final numbered = <String>[];
        for (var i = 0; i < sliced.length; i++) {
          numbered.add('${start + i + 1}\t${sliced[i]}');
        }
        return ToolResult.success(numbered.join('\n'));
      }

      return ToolResult.success(content);
    } catch (e) {
      return ToolResult.error('读取文件失败: $e');
    }
  }
}
