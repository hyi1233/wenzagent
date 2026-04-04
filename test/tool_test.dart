import 'dart:io';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

/// 自定义测试工具：不需要权限
class EchoTool extends AgentTool {
  @override
  String get name => 'echo';

  @override
  String get description => 'Echo back the input message';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'message': {
            'type': 'string',
            'description': 'The message to echo',
          },
        },
        'required': ['message'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final message = arguments['message'] as String? ?? '';
    return ToolResult.success('Echo: $message');
  }
}

/// 自定义测试工具：需要权限
class DangerousTool extends AgentTool {
  @override
  String get name => 'dangerous_action';

  @override
  String get description => 'A tool that requires permission';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {'type': 'string'},
        },
        'required': ['action'],
      };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'dangerous';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    return ToolResult.success('Dangerous action done: ${arguments['action']}');
  }
}

void main() {
  // ============================================================
  // ToolResult 测试
  // ============================================================
  group('ToolResult', () {
    test('success 工厂构造', () {
      final result = ToolResult.success('ok', metadata: {'key': 'value'});
      expect(result.content, 'ok');
      expect(result.isError, false);
      expect(result.metadata, {'key': 'value'});
    });

    test('error 工厂构造', () {
      final result = ToolResult.error('fail');
      expect(result.content, 'fail');
      expect(result.isError, true);
      expect(result.metadata, isNull);
    });

    test('toMap / fromMap 序列化往返', () {
      final original = ToolResult.success('data', metadata: {'a': 1});
      final map = original.toMap();
      final restored = ToolResult.fromMap(map);
      expect(restored.content, original.content);
      expect(restored.isError, original.isError);
      expect(restored.metadata?['a'], 1);
    });

    test('fromMap 默认值处理', () {
      final result = ToolResult.fromMap({});
      expect(result.content, '');
      expect(result.isError, false);
      expect(result.metadata, isNull);
    });
  });

  // ============================================================
  // AgentTool 基类测试
  // ============================================================
  group('AgentTool', () {
    late EchoTool echoTool;
    late DangerousTool dangerousTool;

    setUp(() {
      echoTool = EchoTool();
      dangerousTool = DangerousTool();
    });

    test('基本属性', () {
      expect(echoTool.name, 'echo');
      expect(echoTool.requiresPermission, false);
      expect(echoTool.permissionType, 'echo'); // 默认等于 name

      expect(dangerousTool.name, 'dangerous_action');
      expect(dangerousTool.requiresPermission, true);
      expect(dangerousTool.permissionType, 'dangerous');
    });

    test('execute 返回正确结果', () async {
      final result = await echoTool.execute({'message': 'hello'});
      expect(result.content, 'Echo: hello');
      expect(result.isError, false);
    });

    test('toToolSpec 转换', () {
      final spec = echoTool.toToolSpec();
      expect(spec.name, 'echo');
      expect(spec.description, 'Echo back the input message');
      expect(spec.inputJsonSchema, isNotNull);
    });

    test('toMap 序列化', () {
      final map = echoTool.toMap();
      expect(map['name'], 'echo');
      expect(map['description'], isNotEmpty);
      expect(map['inputJsonSchema'], isA<Map>());
      expect(map['requiresPermission'], false);
      expect(map['permissionType'], 'echo');
    });
  });

  // ============================================================
  // ToolRegistry 测试
  // ============================================================
  group('ToolRegistry', () {
    late ToolRegistry registry;

    setUp(() {
      registry = ToolRegistry();
    });

    test('初始状态为空', () {
      expect(registry.isEmpty, true);
      expect(registry.length, 0);
      expect(registry.tools, isEmpty);
      expect(registry.toolNames, isEmpty);
    });

    test('registerTool 注册单个工具', () {
      registry.registerTool(EchoTool());
      expect(registry.length, 1);
      expect(registry.contains('echo'), true);
      expect(registry.getTool('echo'), isA<EchoTool>());
    });

    test('registerTool 重复注册抛出异常', () {
      registry.registerTool(EchoTool());
      expect(
        () => registry.registerTool(EchoTool()),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('registerTools 批量注册', () {
      registry.registerTools([EchoTool(), DangerousTool()]);
      expect(registry.length, 2);
      expect(registry.contains('echo'), true);
      expect(registry.contains('dangerous_action'), true);
    });

    test('unregisterTool 注销工具', () {
      registry.registerTool(EchoTool());
      expect(registry.contains('echo'), true);
      registry.unregisterTool('echo');
      expect(registry.contains('echo'), false);
      expect(registry.length, 0);
    });

    test('unregisterTool 不存在的工具不报错', () {
      registry.unregisterTool('nonexistent');
      expect(registry.length, 0);
    });

    test('getTool 不存在的工具返回 null', () {
      expect(registry.getTool('nonexistent'), isNull);
    });

    test('toolNames 返回所有工具名称', () {
      registry.registerTools([EchoTool(), DangerousTool()]);
      final names = registry.toolNames;
      expect(names, containsAll(['echo', 'dangerous_action']));
    });

    test('toolSpecs 返回 ToolSpec 列表', () {
      registry.registerTools([EchoTool(), DangerousTool()]);
      final specs = registry.toolSpecs;
      expect(specs.length, 2);
      final specNames = specs.map((s) => s.name).toList();
      expect(specNames, containsAll(['echo', 'dangerous_action']));
    });

    test('toMapList 序列化', () {
      registry.registerTool(EchoTool());
      final list = registry.toMapList();
      expect(list.length, 1);
      expect(list[0]['name'], 'echo');
    });

    test('clear 清空所有工具', () {
      registry.registerTools([EchoTool(), DangerousTool()]);
      expect(registry.length, 2);
      registry.clear();
      expect(registry.isEmpty, true);
    });
  });

  // ============================================================
  // ToolPermissionManager 测试
  // ============================================================
  group('ToolPermissionManager', () {
    late ToolPermissionManager permManager;

    setUp(() {
      permManager = ToolPermissionManager();
    });

    test('不需要权限的工具直接放行', () async {
      final tool = EchoTool();
      final decision = await permManager.checkPermission(tool, {});
      expect(decision, PermissionDecision.allow);
    });

    test('需要权限但无回调时默认拒绝', () async {
      final tool = DangerousTool();
      final decision =
          await permManager.checkPermission(tool, {'action': 'test'});
      expect(decision, PermissionDecision.deny);
    });

    test('权限回调返回 allow', () async {
      permManager.onPermissionRequest = (_) async => PermissionDecision.allow;
      final tool = DangerousTool();
      final decision =
          await permManager.checkPermission(tool, {'action': 'test'});
      expect(decision, PermissionDecision.allow);
    });

    test('权限回调返回 deny', () async {
      permManager.onPermissionRequest = (_) async => PermissionDecision.deny;
      final tool = DangerousTool();
      final decision =
          await permManager.checkPermission(tool, {'action': 'test'});
      expect(decision, PermissionDecision.deny);
    });

    test('allowAlways 自动缓存后续请求', () async {
      var callCount = 0;
      permManager.onPermissionRequest = (_) async {
        callCount++;
        return PermissionDecision.allowAlways;
      };

      final tool = DangerousTool();

      // 第一次调用：触发回调
      final d1 =
          await permManager.checkPermission(tool, {'action': 'first'});
      expect(d1, PermissionDecision.allowAlways);
      expect(callCount, 1);

      // 第二次调用：走缓存，不触发回调
      final d2 =
          await permManager.checkPermission(tool, {'action': 'second'});
      expect(d2, PermissionDecision.allow);
      expect(callCount, 1); // 仍然是1次

      expect(permManager.allowedAlwaysPatterns, contains('dangerous'));
    });

    test('clearAllowedAlways 清除缓存', () async {
      permManager.onPermissionRequest =
          (_) async => PermissionDecision.allowAlways;

      final tool = DangerousTool();
      await permManager.checkPermission(tool, {});
      expect(permManager.allowedAlwaysPatterns.isNotEmpty, true);

      permManager.clearAllowedAlways();
      expect(permManager.allowedAlwaysPatterns.isEmpty, true);

      // 清除后再次调用应触发回调
      var called = false;
      permManager.onPermissionRequest = (_) async {
        called = true;
        return PermissionDecision.allow;
      };
      await permManager.checkPermission(tool, {});
      expect(called, true);
    });

    test('权限请求包含正确的 AgentPermissionRequest 信息', () async {
      AgentPermissionRequest? capturedRequest;
      permManager.onPermissionRequest = (req) async {
        capturedRequest = req;
        return PermissionDecision.allow;
      };

      final tool = DangerousTool();
      await permManager.checkPermission(tool, {'action': 'test_action'});

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.type, 'tool_execution');
      expect(capturedRequest!.functionName, 'dangerous_action');
      expect(capturedRequest!.permissionType, 'dangerous');
      expect(capturedRequest!.data?['toolName'], 'dangerous_action');
      expect(capturedRequest!.data?['arguments']['action'], 'test_action');
    });
  });

  // ============================================================
  // BuiltinTools 工厂测试
  // ============================================================
  group('BuiltinTools', () {
    test('all() 返回 9 个内置工具', () {
      final tools = BuiltinTools.all();
      expect(tools.length, 9);

      final names = tools.map((t) => t.name).toSet();
      expect(
        names,
        containsAll([
          'file_read',
          'file_write',
          'file_list',
          'file_search',
          'content_search',
          'command_execute',
          'file_info',
          'file_delete',
          'directory_create',
        ]),
      );
    });

    test('readOnly() 只返回不需要权限的工具', () {
      final tools = BuiltinTools.readOnly();
      for (final tool in tools) {
        expect(tool.requiresPermission, false,
            reason: '${tool.name} should not require permission');
      }
      expect(tools.length, 5);
    });

    test('fileTools() 不包含 command_execute', () {
      final tools = BuiltinTools.fileTools();
      final names = tools.map((t) => t.name).toSet();
      expect(names.contains('command_execute'), false);
      expect(tools.length, 8);
    });

    test('所有工具都能生成有效的 ToolSpec', () {
      final tools = BuiltinTools.all();
      for (final tool in tools) {
        final spec = tool.toToolSpec();
        expect(spec.name, isNotEmpty, reason: '${tool.name} spec name');
        expect(spec.description, isNotEmpty,
            reason: '${tool.name} spec description');
        expect(spec.inputJsonSchema, isNotNull,
            reason: '${tool.name} spec schema');
      }
    });

    test('所有工具都能序列化为 Map', () {
      final tools = BuiltinTools.all();
      for (final tool in tools) {
        final map = tool.toMap();
        expect(map['name'], tool.name);
        expect(map['description'], isNotEmpty);
        expect(map['inputJsonSchema'], isA<Map>());
        expect(map['requiresPermission'], isA<bool>());
        expect(map['permissionType'], isNotEmpty);
      }
    });
  });

  // ============================================================
  // 内置工具功能测试（使用临时目录）
  // ============================================================
  group('内置工具功能测试', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('wenzagent_tool_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    // ---- FileReadTool ----
    group('FileReadTool', () {
      late FileReadTool tool;
      setUp(() => tool = FileReadTool());

      test('读取存在的文件', () async {
        final file = File('${tempDir.path}/test.txt');
        await file.writeAsString('line1\nline2\nline3');

        final result = await tool.execute({'path': file.path});
        expect(result.isError, false);
        expect(result.content, 'line1\nline2\nline3');
      });

      test('带 offset 和 limit 读取', () async {
        final file = File('${tempDir.path}/lines.txt');
        await file.writeAsString('a\nb\nc\nd\ne');

        final result = await tool.execute({
          'path': file.path,
          'offset': 1,
          'limit': 2,
        });
        expect(result.isError, false);
        // offset=1 从第二行开始，limit=2 读2行 => b, c
        expect(result.content, contains('b'));
        expect(result.content, contains('c'));
        // 不应包含 d, e
        expect(result.content, isNot(contains('\td')));
      });

      test('读取不存在的文件返回错误', () async {
        final result =
            await tool.execute({'path': '${tempDir.path}/nonexistent.txt'});
        expect(result.isError, true);
        expect(result.content, contains('文件不存在'));
      });

      test('path 为空返回错误', () async {
        final result = await tool.execute({'path': ''});
        expect(result.isError, true);
        expect(result.content, contains('path 不能为空'));
      });
    });

    // ---- FileWriteTool ----
    group('FileWriteTool', () {
      late FileWriteTool tool;
      setUp(() => tool = FileWriteTool());

      test('写入新文件', () async {
        final path = '${tempDir.path}/new_file.txt';
        final result =
            await tool.execute({'path': path, 'content': 'hello world'});
        expect(result.isError, false);
        expect(result.content, contains('文件写入成功'));

        final content = await File(path).readAsString();
        expect(content, 'hello world');
      });

      test('覆盖已有文件', () async {
        final path = '${tempDir.path}/overwrite.txt';
        await File(path).writeAsString('old');

        await tool.execute({'path': path, 'content': 'new'});
        final content = await File(path).readAsString();
        expect(content, 'new');
      });

      test('追加模式', () async {
        final path = '${tempDir.path}/append.txt';
        await File(path).writeAsString('start');

        await tool.execute({
          'path': path,
          'content': '_end',
          'append': true,
        });
        final content = await File(path).readAsString();
        expect(content, 'start_end');
      });

      test('自动创建父目录', () async {
        final path = '${tempDir.path}/sub/dir/file.txt';
        final result = await tool.execute({'path': path, 'content': 'deep'});
        expect(result.isError, false);
        expect(await File(path).exists(), true);
      });

      test('需要权限', () {
        expect(tool.requiresPermission, true);
        expect(tool.permissionType, 'file_write');
      });
    });

    // ---- FileListTool ----
    group('FileListTool', () {
      late FileListTool tool;
      setUp(() => tool = FileListTool());

      test('列出目录内容', () async {
        await File('${tempDir.path}/a.txt').writeAsString('a');
        await File('${tempDir.path}/b.txt').writeAsString('b');
        await Directory('${tempDir.path}/subdir').create();

        final result = await tool.execute({'path': tempDir.path});
        expect(result.isError, false);
        expect(result.content, contains('a.txt'));
        expect(result.content, contains('b.txt'));
        expect(result.content, contains('[DIR]'));
        expect(result.content, contains('[FILE]'));
      });

      test('空目录', () async {
        final emptyDir = await Directory('${tempDir.path}/empty').create();
        final result = await tool.execute({'path': emptyDir.path});
        expect(result.isError, false);
        expect(result.content, contains('目录为空'));
      });

      test('不存在的目录返回错误', () async {
        final result =
            await tool.execute({'path': '${tempDir.path}/nonexistent'});
        expect(result.isError, true);
        expect(result.content, contains('目录不存在'));
      });

      test('递归列出', () async {
        final subdir = await Directory('${tempDir.path}/sub').create();
        await File('${subdir.path}/nested.txt').writeAsString('nested');

        final result = await tool.execute({
          'path': tempDir.path,
          'recursive': true,
        });
        expect(result.isError, false);
        expect(result.content, contains('nested.txt'));
      });
    });

    // ---- FileSearchTool ----
    group('FileSearchTool', () {
      late FileSearchTool tool;
      setUp(() => tool = FileSearchTool());

      test('按模式搜索文件', () async {
        await File('${tempDir.path}/test.dart').writeAsString('dart');
        await File('${tempDir.path}/test.txt').writeAsString('txt');
        await File('${tempDir.path}/other.dart').writeAsString('dart2');

        final result = await tool.execute({
          'directory': tempDir.path,
          'pattern': '*.dart',
        });
        expect(result.isError, false);
        expect(result.content, contains('test.dart'));
        expect(result.content, contains('other.dart'));
        expect(result.content, isNot(contains('test.txt')));
      });

      test('无匹配结果', () async {
        await File('${tempDir.path}/test.txt').writeAsString('txt');
        final result = await tool.execute({
          'directory': tempDir.path,
          'pattern': '*.xyz',
        });
        expect(result.isError, false);
        expect(result.content, contains('未找到匹配'));
      });

      test('目录不存在返回错误', () async {
        final result = await tool.execute({
          'directory': '${tempDir.path}/no_such_dir',
          'pattern': '*',
        });
        expect(result.isError, true);
        expect(result.content, contains('目录不存在'));
      });
    });

    // ---- ContentSearchTool ----
    group('ContentSearchTool', () {
      late ContentSearchTool tool;
      setUp(() => tool = ContentSearchTool());

      test('在文件内容中搜索文本', () async {
        await File('${tempDir.path}/code.dart')
            .writeAsString('void main() {\n  print("hello");\n}');
        await File('${tempDir.path}/readme.txt')
            .writeAsString('This is a readme.\nNo code here.');

        final result = await tool.execute({
          'directory': tempDir.path,
          'pattern': 'main',
        });
        expect(result.isError, false);
        expect(result.content, contains('code.dart'));
        expect(result.content, contains('main'));
      });

      test('带文件模式过滤', () async {
        await File('${tempDir.path}/a.dart').writeAsString('hello dart');
        await File('${tempDir.path}/b.txt').writeAsString('hello txt');

        final result = await tool.execute({
          'directory': tempDir.path,
          'pattern': 'hello',
          'filePattern': '*.dart',
        });
        expect(result.isError, false);
        expect(result.content, contains('a.dart'));
        expect(result.content, isNot(contains('b.txt')));
      });

      test('无匹配内容', () async {
        await File('${tempDir.path}/data.txt').writeAsString('foo bar');
        final result = await tool.execute({
          'directory': tempDir.path,
          'pattern': 'zzzzz_no_match',
        });
        expect(result.isError, false);
        expect(result.content, contains('未找到匹配'));
      });
    });

    // ---- FileInfoTool ----
    group('FileInfoTool', () {
      late FileInfoTool tool;
      setUp(() => tool = FileInfoTool());

      test('获取文件信息', () async {
        final file = File('${tempDir.path}/info_test.txt');
        await file.writeAsString('some content');

        final result = await tool.execute({'path': file.path});
        expect(result.isError, false);
        expect(result.content, contains('路径:'));
        expect(result.content, contains('类型:'));
        expect(result.content, contains('文件'));
        expect(result.content, contains('大小:'));
      });

      test('获取目录信息', () async {
        final dir = await Directory('${tempDir.path}/info_dir').create();
        final result = await tool.execute({'path': dir.path});
        expect(result.isError, false);
        expect(result.content, contains('目录'));
      });

      test('路径不存在返回错误', () async {
        final result =
            await tool.execute({'path': '${tempDir.path}/nonexistent_path'});
        expect(result.isError, true);
        expect(result.content, contains('路径不存在'));
      });

      test('不需要权限', () {
        expect(tool.requiresPermission, false);
      });
    });

    // ---- FileDeleteTool ----
    group('FileDeleteTool', () {
      late FileDeleteTool tool;
      setUp(() => tool = FileDeleteTool());

      test('删除文件', () async {
        final file = File('${tempDir.path}/to_delete.txt');
        await file.writeAsString('delete me');
        expect(await file.exists(), true);

        final result = await tool.execute({'path': file.path});
        expect(result.isError, false);
        expect(result.content, contains('文件已删除'));
        expect(await file.exists(), false);
      });

      test('递归删除目录', () async {
        final dir = await Directory('${tempDir.path}/to_delete_dir').create();
        await File('${dir.path}/child.txt').writeAsString('child');

        final result = await tool.execute({
          'path': dir.path,
          'recursive': true,
        });
        expect(result.isError, false);
        expect(result.content, contains('目录已删除'));
        expect(await dir.exists(), false);
      });

      test('删除不存在的路径返回错误', () async {
        final result =
            await tool.execute({'path': '${tempDir.path}/no_such_file'});
        expect(result.isError, true);
        expect(result.content, contains('路径不存在'));
      });

      test('需要权限', () {
        expect(tool.requiresPermission, true);
        expect(tool.permissionType, 'file_delete');
      });
    });

    // ---- DirectoryCreateTool ----
    group('DirectoryCreateTool', () {
      late DirectoryCreateTool tool;
      setUp(() => tool = DirectoryCreateTool());

      test('创建目录', () async {
        final path = '${tempDir.path}/new_dir';
        final result = await tool.execute({'path': path});
        expect(result.isError, false);
        expect(result.content, contains('目录已创建'));
        expect(await Directory(path).exists(), true);
      });

      test('递归创建嵌套目录', () async {
        final path = '${tempDir.path}/a/b/c';
        final result = await tool.execute({'path': path, 'recursive': true});
        expect(result.isError, false);
        expect(await Directory(path).exists(), true);
      });

      test('已存在的目录返回成功提示', () async {
        final dir = await Directory('${tempDir.path}/exists').create();
        final result = await tool.execute({'path': dir.path});
        expect(result.isError, false);
        expect(result.content, contains('目录已存在'));
      });

      test('需要权限', () {
        expect(tool.requiresPermission, true);
        expect(tool.permissionType, 'file_write');
      });
    });

    // ---- CommandExecuteTool ----
    group('CommandExecuteTool', () {
      late CommandExecuteTool tool;
      setUp(() => tool = CommandExecuteTool());

      test('执行简单命令', () async {
        final command = Platform.isWindows ? 'echo hello' : 'echo hello';
        final result = await tool.execute({'command': command});
        expect(result.isError, false);
        expect(result.content, contains('hello'));
        expect(result.content, contains('Exit code: 0'));
      });

      test('指定工作目录', () async {
        final result = await tool.execute({
          'command': Platform.isWindows ? 'cd' : 'pwd',
          'workingDirectory': tempDir.path,
        });
        expect(result.isError, false);
        expect(result.content, contains(tempDir.path));
      });

      test('命令执行失败返回错误', () async {
        final result = await tool.execute({
          'command': Platform.isWindows
              ? 'cmd /c exit 1'
              : 'sh -c "exit 1"',
        });
        expect(result.isError, true);
        expect(result.content, contains('Exit code: 1'));
      });

      test('空命令返回错误', () async {
        final result = await tool.execute({'command': ''});
        expect(result.isError, true);
        expect(result.content, contains('command 不能为空'));
      });

      test('需要权限', () {
        expect(tool.requiresPermission, true);
        expect(tool.permissionType, 'command_execute');
      });
    });
  });

  // ============================================================
  // Registry + PermissionManager 集成测试
  // ============================================================
  group('Registry + PermissionManager 集成', () {
    test('注册全部内置工具 + 自定义工具，逐个执行', () async {
      final registry = ToolRegistry();
      final permManager = ToolPermissionManager();

      // 自动批准所有权限
      permManager.onPermissionRequest =
          (_) async => PermissionDecision.allow;

      // 注册内置工具 + 自定义工具
      registry.registerTools(BuiltinTools.all());
      registry.registerTool(EchoTool());
      expect(registry.length, 10);

      // 验证每个工具都能通过 registry 查找到
      for (final name in registry.toolNames) {
        final tool = registry.getTool(name);
        expect(tool, isNotNull, reason: 'Tool $name should be found');

        // 检查权限
        final decision = await permManager.checkPermission(tool!, {});
        expect(
          decision,
          anyOf(PermissionDecision.allow, PermissionDecision.allowAlways),
          reason: 'Permission for $name should be granted',
        );
      }
    });

    test('权限拒绝的工具不应该被执行', () async {
      final permManager = ToolPermissionManager();
      permManager.onPermissionRequest =
          (_) async => PermissionDecision.deny;

      final tool = CommandExecuteTool();
      final decision = await permManager.checkPermission(
        tool,
        {'command': 'echo test'},
      );
      expect(decision, PermissionDecision.deny);
      // 如果拒绝了就不执行，这是调用方的逻辑
    });

    test('toolSpecs 可以用于 LLM 调用', () {
      final registry = ToolRegistry();
      registry.registerTools(BuiltinTools.all());

      final specs = registry.toolSpecs;
      expect(specs.length, 9);

      // 每个 spec 都应该有 name, description, inputJsonSchema
      for (final spec in specs) {
        expect(spec.name, isNotEmpty);
        expect(spec.description, isNotEmpty);
        expect(spec.inputJsonSchema, isNotNull);
        expect(spec.inputJsonSchema['type'], 'object');
        expect(spec.inputJsonSchema['properties'], isA<Map>());
        expect(spec.inputJsonSchema['required'], isA<List>());
      }
    });
  });
}
