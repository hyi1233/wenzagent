import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('PermissionRule', () {
    group('matches', () {
      test('exact 模式精确匹配参数值', () {
        final rule = PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '/workspace/test.txt',
          mode: PermissionMatchMode.exact,
        );

        expect(
          rule.matches('file_write', {'path': '/workspace/test.txt'}),
          isTrue,
        );
        expect(
          rule.matches('file_write', {'path': '/workspace/other.txt'}),
          isFalse,
        );
        expect(
          rule.matches('file_delete', {'path': '/workspace/test.txt'}),
          isFalse, // 工具名不匹配
        );
        expect(
          rule.matches('file_write', {}),
          isFalse, // 缺少参数
        );
      });

      test('regex 模式正则匹配参数值', () {
        final rule = PermissionRule(
          tool: 'command_execute',
          arg: 'command',
          pattern: r'git\s+\w+.*',
          mode: PermissionMatchMode.regex,
        );

        expect(rule.matches('command_execute', {'command': 'git commit -m "hi"'}),
            isTrue);
        expect(
            rule.matches('command_execute', {'command': 'git push'}), isTrue);
        expect(
            rule.matches('command_execute', {'command': 'npm install'}),
            isFalse);
      });

      test('all 模式仅匹配工具名', () {
        final rule = PermissionRule(
          tool: 'file_write',
          mode: PermissionMatchMode.all,
        );

        expect(rule.matches('file_write', {'path': '/any/path'}), isTrue);
        expect(rule.matches('file_write', {}), isTrue);
        expect(rule.matches('file_delete', {'path': '/any/path'}), isFalse);
      });

      test('arg 为 null 时仅匹配工具名', () {
        final rule = PermissionRule(
          tool: 'mcp',
          arg: null,
          pattern: '',
          mode: PermissionMatchMode.exact,
        );

        expect(rule.matches('mcp', {'anyKey': 'anyValue'}), isTrue);
        expect(rule.matches('other', {'anyKey': 'anyValue'}), isFalse);
      });

      test('参数值非字符串时返回 false', () {
        final rule = PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '/test',
          mode: PermissionMatchMode.exact,
        );

        expect(rule.matches('file_write', {'path': 123}), isFalse);
        expect(rule.matches('file_write', {'path': null}), isFalse);
      });
    });

    group('derivePattern', () {
      test('路径推导为目录 + .*', () {
        expect(
          PermissionRule.derivePattern('/workspace/src/main.dart'),
          equals(RegExp.escape('/workspace/src/') + '.*'),
        );
        expect(
          PermissionRule.derivePattern('/tmp/file.txt'),
          equals(RegExp.escape('/tmp/') + '.*'),
        );
      });

      test('Windows 路径推导', () {
        expect(
          PermissionRule.derivePattern(r'C:\Users\test\file.txt'),
          equals(RegExp.escape(r'C:\Users\test\') + '.*'),
        );
      });

      test('命令推导为第一个词 + .*', () {
        expect(
          PermissionRule.derivePattern('git commit -m "msg"'),
          equals('git.*'),
        );
        expect(
          PermissionRule.derivePattern('npm install'),
          equals('npm.*'),
        );
      });

      test('空字符串返回 .*', () {
        expect(PermissionRule.derivePattern(''), equals('.*'));
      });
    });

    group('JSON 序列化', () {
      test('toJson / fromJson 往返', () {
        final rule = PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: r'/workspace/.*',
          mode: PermissionMatchMode.regex,
          createTime: DateTime(2026, 1, 1),
        );

        final json = jsonEncode(rule.toJson());
        final restored = PermissionRule.fromJson(jsonDecode(json));
        expect(restored.tool, equals('file_write'));
        expect(restored.arg, equals('path'));
        expect(restored.pattern, equals(r'/workspace/.*'));
        expect(restored.mode, equals(PermissionMatchMode.regex));
      });

      test('无 arg 的规则序列化', () {
        final rule = PermissionRule(
          tool: 'mcp',
          mode: PermissionMatchMode.all,
        );

        final json = jsonEncode(rule.toJson());
        final map = jsonDecode(json) as Map<String, dynamic>;
        expect(map.containsKey('arg'), isFalse);
      });
    });

    group('equality', () {
      test('相同规则相等', () {
        final a = PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '/test',
          mode: PermissionMatchMode.exact,
        );
        final b = PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '/test',
          mode: PermissionMatchMode.exact,
        );
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('不同规则不相等', () {
        final a = PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '/test',
          mode: PermissionMatchMode.exact,
        );
        final b = PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '/other',
          mode: PermissionMatchMode.exact,
        );
        expect(a, isNot(equals(b)));
      });
    });
  });

  group('PermissionConfig', () {
    test('empty 创建空配置', () {
      final config = PermissionConfig.empty();
      expect(config.whitelist, isEmpty);
      expect(config.blacklist, isEmpty);
    });

    test('fromJsonString 解析 JSON', () {
      final json = jsonEncode({
        'whitelist': [
          {'tool': 'file_write', 'arg': 'path', 'pattern': '/workspace/.*', 'mode': 'regex'},
          {'tool': 'command_execute', 'mode': 'all'},
        ],
        'blacklist': [
          {'tool': 'command_execute', 'arg': 'command', 'pattern': r'rm\s+-rf.*', 'mode': 'regex'},
        ],
      });

      final config = PermissionConfig.fromJsonString(json);
      expect(config.whitelist.length, equals(2));
      expect(config.blacklist.length, equals(1));
      expect(config.whitelist[0].tool, equals('file_write'));
      expect(config.whitelist[0].mode, equals(PermissionMatchMode.regex));
      expect(config.blacklist[0].pattern, equals(r'rm\s+-rf.*'));
    });

    test('fromJsonString 空字符串返回空配置', () {
      expect(PermissionConfig.fromJsonString('').whitelist, isEmpty);
      expect(PermissionConfig.fromJsonString('{}').whitelist, isEmpty);
      expect(PermissionConfig.fromJsonString('invalid').whitelist, isEmpty);
    });

    test('evaluate 黑名单优先', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(tool: 'command_execute', mode: PermissionMatchMode.all),
        ],
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // 黑名单命中 → deny
      expect(
        config.evaluate('command_execute', {'command': 'rm -rf /'}),
        equals(PermissionVerdict.deny),
      );

      // 未命中黑名单 → 白名单命中 → allow
      expect(
        config.evaluate('command_execute', {'command': 'git status'}),
        equals(PermissionVerdict.allow),
      );

      // 其他工具 → ask
      expect(
        config.evaluate('file_write', {'path': '/test'}),
        equals(PermissionVerdict.ask),
      );
    });

    test('addWhitelistRule 返回新实例（不可变）', () {
      final config = PermissionConfig.empty();
      final rule = PermissionRule(
        tool: 'file_write',
        mode: PermissionMatchMode.all,
      );

      final newConfig = config.addWhitelistRule(rule);
      expect(config.whitelist, isEmpty); // 原实例不变
      expect(newConfig.whitelist.length, equals(1));
    });

    test('toJsonString / fromJsonString 往返', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: '/workspace/.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final json = config.toJsonString();
      final restored = PermissionConfig.fromJsonString(json);

      expect(restored.whitelist.length, equals(1));
      expect(restored.blacklist.length, equals(1));
      expect(
        restored.whitelist[0].matches('file_write', {'path': '/workspace/src/main.dart'}),
        isTrue,
      );
      expect(
        restored.blacklist[0].matches('command_execute', {'command': 'rm -rf /'}),
        isTrue,
      );
    });
  });

  group('ToolPermissionManager', () {
    late ToolPermissionManager manager;

    setUp(() {
      manager = ToolPermissionManager();
    });

    test('不需要权限的工具直接放行', () {
      final tool = _MockTool(
        name: 'file_read',
        requiresPermission: false,
        permissionType: 'file_read',
      );

      expect(
        manager.checkPermission(tool, {'path': '/test'}),
        completion(equals(PermissionDecision.allow)),
      );
    });

    test('无配置无回调时默认拒绝', () async {
      final tool = _MockTool(
        name: 'file_write',
        requiresPermission: true,
        permissionType: 'file_write',
        permissionArgKey: 'path',
      );

      final decision = await manager.checkPermission(tool, {'path': '/test'});
      expect(decision, equals(PermissionDecision.deny));
    });

    test('黑名单命中直接拒绝，设置 lastDenyMessage', () async {
      manager.configure(PermissionConfig(
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      ));

      final tool = _MockTool(
        name: 'command_execute',
        requiresPermission: true,
        permissionType: 'command_execute',
        permissionArgKey: 'command',
      );

      final decision = await manager.checkPermission(
          tool, {'command': 'rm -rf /'});
      expect(decision, equals(PermissionDecision.deny));
      expect(manager.lastDenyMessage, isNotNull);
      expect(manager.lastDenyMessage, contains('安全策略阻止'));
    });

    test('白名单命中直接放行', () async {
      manager.configure(PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: r'/workspace/.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      ));

      final tool = _MockTool(
        name: 'file_write',
        requiresPermission: true,
        permissionType: 'file_write',
        permissionArgKey: 'path',
      );

      final decision = await manager.checkPermission(
          tool, {'path': '/workspace/src/main.dart'});
      expect(decision, equals(PermissionDecision.allow));
      expect(manager.lastDenyMessage, isNull);
    });

    test('白名单未命中走用户确认', () async {
      manager.configure(PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: r'/workspace/.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      ));

      manager.onPermissionRequest = (request) async {
        // 模拟用户选择 allowAlways
        return PermissionDecision.allowAlways;
      };

      final tool = _MockTool(
        name: 'file_write',
        requiresPermission: true,
        permissionType: 'file_write',
        permissionArgKey: 'path',
      );

      final decision = await manager.checkPermission(
          tool, {'path': '/other/path/test.txt'});
      expect(decision, equals(PermissionDecision.allowAlways));
      // allowAlways 加入缓存
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);
    });

    test('allowAlways 缓存生效', () async {
      manager.configure(PermissionConfig.empty());
      manager.onPermissionRequest = (_) async => PermissionDecision.allowAlways;

      final tool = _MockTool(
        name: 'file_write',
        requiresPermission: true,
        permissionType: 'file_write',
        permissionArgKey: 'path',
      );

      // 第一次触发用户确认
      await manager.checkPermission(tool, {'path': '/test'});
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);

      // 第二次直接放行
      manager.onPermissionRequest = (_) async => throw StateError('不应调用');
      final decision2 = await manager.checkPermission(tool, {'path': '/other'});
      expect(decision2, equals(PermissionDecision.allow));
    });

    test('addApproval 添加规则并触发回调', () async {
      var callbackCalled = false;
      PermissionConfig? callbackConfig;

      manager.onConfigChanged = (config) {
        callbackCalled = true;
        callbackConfig = config;
      };

      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/exact/path',
        mode: PermissionMatchMode.exact,
      );

      manager.addApproval(rule);

      expect(callbackCalled, isTrue);
      expect(callbackConfig!.whitelist.length, equals(1));
      expect(callbackConfig!.whitelist[0], equals(rule));

      // exact 模式不加入 always 缓存
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isFalse);
    });

    test('addApproval all 模式加入 always 缓存', () {
      manager.addApproval(PermissionRule(
        tool: 'command_execute',
        mode: PermissionMatchMode.all,
      ));

      expect(manager.allowedAlwaysPatterns.contains('command_execute'), isTrue);
    });

    test('configure 将 all 规则加入缓存', () {
      manager.configure(PermissionConfig(
        whitelist: [
          PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all),
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: 'git.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      ));

      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);
      expect(manager.allowedAlwaysPatterns.contains('command_execute'), isFalse);
    });

    test('removeApproval 移除规则', () {
      final rule = PermissionRule(
        tool: 'file_write',
        mode: PermissionMatchMode.all,
      );

      manager.addApproval(rule);
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);

      manager.removeApproval(rule);
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isFalse);
    });
  });

  group('PermissionApprovalScope', () {
    test('fromString 正确解析', () {
      expect(PermissionApprovalScope.fromString('once'),
          equals(PermissionApprovalScope.once));
      expect(PermissionApprovalScope.fromString('exact'),
          equals(PermissionApprovalScope.exact));
      expect(PermissionApprovalScope.fromString('pattern'),
          equals(PermissionApprovalScope.pattern));
      expect(PermissionApprovalScope.fromString('all'),
          equals(PermissionApprovalScope.all));
      expect(PermissionApprovalScope.fromString('invalid'),
          equals(PermissionApprovalScope.once));
    });
  });
}

/// 测试用 Mock 工具
class _MockTool extends AgentTool {
  @override
  final String name;
  @override
  final bool requiresPermission;
  @override
  final String permissionType;
  @override
  final String? permissionArgKey;

  _MockTool({
    required this.name,
    required this.requiresPermission,
    required this.permissionType,
    this.permissionArgKey,
  });

  @override
  String get description => 'Mock tool for testing';

  @override
  Map<String, dynamic> get inputJsonSchema => {'type': 'object'};

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    return ToolResult.success('mock');
  }
}
