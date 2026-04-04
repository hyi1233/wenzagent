import 'dart:io';

import '../agent_tool.dart';

/// 内容搜索工具
///
/// 在文件内容中搜索匹配的文本或正则模式（类似 grep）。
class ContentSearchTool extends AgentTool {
  @override
  String get name => 'content_search';

  @override
  String get description =>
      'Search file contents for a text or regex pattern (grep-like). '
      'Returns matching lines with file paths and line numbers. '
      'Optionally filter files by name pattern.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'directory': {
        'type': 'string',
        'description': 'The root directory to search in',
      },
      'pattern': {
        'type': 'string',
        'description': 'Text or regex pattern to search for in file contents',
      },
      'filePattern': {
        'type': 'string',
        'description':
            'Optional glob pattern to filter files (e.g., "*.dart"). Default: search all text files',
      },
      'maxResults': {
        'type': 'integer',
        'description':
            'Maximum number of matching lines to return. Default: 100',
      },
      'caseSensitive': {
        'type': 'boolean',
        'description': 'Whether the search is case-sensitive. Default: true',
      },
    },
    'required': ['directory', 'pattern'],
  };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final directory = arguments['directory'] as String?;
    if (directory == null || directory.isEmpty) {
      return ToolResult.error('参数错误: directory 不能为空');
    }

    final pattern = arguments['pattern'] as String?;
    if (pattern == null || pattern.isEmpty) {
      return ToolResult.error('参数错误: pattern 不能为空');
    }

    final dir = Directory(directory);
    if (!await dir.exists()) {
      return ToolResult.error('目录不存在: $directory');
    }

    final maxResults = arguments['maxResults'] as int? ?? 100;
    final caseSensitive = arguments['caseSensitive'] as bool? ?? true;
    final filePattern = arguments['filePattern'] as String?;

    try {
      final regex = RegExp(pattern, caseSensitive: caseSensitive);
      RegExp? fileRegex;
      if (filePattern != null && filePattern.isNotEmpty) {
        fileRegex = RegExp(
          _globToRegex(filePattern),
          caseSensitive: !Platform.isWindows,
        );
      }

      final results = <String>[];
      var fileCount = 0;

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (results.length >= maxResults) break;

        final baseName = entity.path.split(Platform.pathSeparator).last;

        // 跳过二进制文件等
        if (_isBinaryFile(baseName)) continue;

        // 文件名过滤
        if (fileRegex != null && !fileRegex.hasMatch(baseName)) continue;

        try {
          final lines = await entity.readAsLines();
          var hasMatch = false;
          for (var i = 0; i < lines.length; i++) {
            if (results.length >= maxResults) break;
            if (regex.hasMatch(lines[i])) {
              if (!hasMatch) {
                hasMatch = true;
                fileCount++;
              }
              results.add('${entity.path}:${i + 1}: ${lines[i]}');
            }
          }
        } catch (_) {
          // 跳过无法读取的文件（如二进制文件）
        }
      }

      if (results.isEmpty) {
        return ToolResult.success('未找到匹配 "$pattern" 的内容');
      }

      return ToolResult.success(
        '在 $fileCount 个文件中找到 ${results.length} 个匹配:\n${results.join('\n')}',
      );
    } catch (e) {
      return ToolResult.error('搜索内容失败: $e');
    }
  }

  bool _isBinaryFile(String name) {
    const binaryExtensions = {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.bmp',
      '.ico',
      '.webp',
      '.mp3',
      '.mp4',
      '.avi',
      '.mov',
      '.wav',
      '.flac',
      '.zip',
      '.tar',
      '.gz',
      '.rar',
      '.7z',
      '.exe',
      '.dll',
      '.so',
      '.dylib',
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.class',
      '.jar',
      '.pyc',
      '.o',
      '.obj',
      '.ttf',
      '.otf',
      '.woff',
      '.woff2',
    };
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return binaryExtensions.contains(name.substring(dot).toLowerCase());
  }

  String _globToRegex(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final char = glob[i];
      switch (char) {
        case '*':
          buffer.write('.*');
          break;
        case '?':
          buffer.write('.');
          break;
        case '.':
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '+':
        case '^':
        case r'$':
        case '|':
        case r'\':
          buffer.write('\\$char');
          break;
        default:
          buffer.write(char);
      }
    }
    buffer.write(r'$');
    return buffer.toString();
  }
}
