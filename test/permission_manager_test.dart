import 'dart:convert';
import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';
import 'package:wenzagent/src/service/permission_forwarder.dart';

void main() {
  group('PermissionRule - 单条规则匹配', () {
    group('exact 精确匹配', () {
      test('路径精确匹配 - 文件写入', () {
        final rule = PermissionRule(
          tool: 'file_write', arg: 'path',
          pattern: '/workspace/project/test.txt', mode: PermissionMatchMode.exact,
        );
        expect(rule.matches('file_write', {'path': '/workspace/project/test.txt'}), isTrue);
        expect(rule.matches('file_write', {'path': '/workspace/project/other.txt'}), isFalse);
        expect(rule.matches('file_delete', {'path': '/workspace/project/test.txt'}), isFalse);
        expect(rule.matches('file_write', {}), isFalse);
        expect(rule.matches('file_write', {'path': 123}), isFalse);
        expect(rule.matches('file_write', {'path': null}), isFalse);
      });

      test('命令精确匹配', () {
        final rule = PermissionRule(
          tool: 'command_execute', arg: 'command',
          pattern: 'git status', mode: PermissionMatchMode.exact,
        );
        expect(rule.matches('command_execute', {'command': 'git status'}), isTrue);
        expect(rule.matches('command_execute', {'command': 'git status --short'}), isFalse);
      });

      test('文件删除权限精确匹配路径', () {
        final rule = PermissionRule(
          tool: 'file_delete', arg: 'path',
          pattern: '/tmp/cache', mode: PermissionMatchMode.exact,
        );
        expect(rule.matches('file_delete', {'path': '/tmp/cache'}), isTrue);
        expect(rule.matches('file_delete', {'path': '/tmp/cache/sub'}), isFalse);
      });
    });

    group('regex 正则匹配', () {
      test('文件路径正则 - 匹配目录下所有文件', () {
        final rule = PermissionRule(
          tool: 'file_write', arg: 'path',
          pattern: r'/workspace/.*', mode: PermissionMatchMode.regex,
        );
        expect(rule.matches('file_write', {'path': '/workspace/src/main.dart'}), isTrue);
        expect(rule.matches('file_write', {'path': '/workspace/test.txt'}), isTrue);
        expect(rule.matches('file_write', {'path': '/other/path/file.txt'}), isFalse);
      });

      test('命令正则 - 仅允许 git 命令', () {
        final rule = PermissionRule(
          tool: 'command_execute', arg: 'command',
          pattern: r'git\s+\w+.*', mode: PermissionMatchMode.regex,
        );
        expect(rule.matches('command_execute', {'command': 'git commit -m "hi"'}), isTrue);
        expect(rule.matches('command_execute', {'command': 'npm install'}), isFalse);
      });

      test('黑名单阻止危险命令 - rm -rf / sudo', () {
        final rmRule = PermissionRule(
          tool: 'command_execute', arg: 'command',
          pattern: r'rm\s+-rf\s+/', mode: PermissionMatchMode.regex,
        );
        final sudoRule = PermissionRule(
          tool: 'command_execute', arg: 'command',
          pattern: r'^sudo\s+.*', mode: PermissionMatchMode.regex,
        );
        expect(rmRule.matches('command_execute', {'command': 'rm -rf /'}), isTrue);
        expect(rmRule.matches('command_execute', {'command': 'rm -rf ./cache'}), isFalse);
        expect(sudoRule.matches('command_execute', {'command': 'sudo rm -rf /'}), isTrue);
        expect(sudoRule.matches('command_execute', {'command': 'echo sudo'}), isFalse);
      });

      test('Windows 路径正则匹配', () {
        final rule = PermissionRule(
          tool: 'file_write', arg: 'path',
          pattern: r'C:\\Users\\.*', mode: PermissionMatchMode.regex,
        );
        expect(rule.matches('file_write', {'path': r'C:\Users\test\file.txt'}), isTrue);
        expect(rule.matches('file_write', {'path': r'D:\project\file.txt'}), isFalse);
      });

      test('无效正则返回 false', () {
        final rule = PermissionRule(
          tool: 'file_write', arg: 'path',
          pattern: r'[invalid(regex', mode: PermissionMatchMode.regex,
        );
        expect(rule.matches('file_write', {'path': '/any/path'}), isFalse);
      });
    });

    group('all 全部匹配', () {
      test('all 模式匹配所有参数值', () {
        final rule = PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all);
        expect(rule.matches('file_write', {'path': '/any/path'}), isTrue);
        expect(rule.matches('file_write', {}), isTrue);
        expect(rule.matches('file_delete', {'path': '/any'}), isFalse);
      });
    });

    group('arg 为 null 时仅匹配工具名', () {
      test('null arg 模式', () {
        final rule = PermissionRule(tool: 'mcp', arg: null, pattern: '', mode: PermissionMatchMode.exact);
        expect(rule.matches('mcp', {'anyKey': 'anyValue'}), isTrue);
        expect(rule.matches('mcp', {}), isTrue);
        expect(rule.matches('other', {'anyKey': 'anyValue'}), isFalse);
      });
    });
  });

  group('PermissionRule.derivePattern', () {
    test('Unix/Windows 路径推导', () {
      expect(PermissionRule.derivePattern('/workspace/src/main.dart'),
          equals('${RegExp.escape('/workspace/src/')}.*'));
      expect(PermissionRule.derivePattern(r'C:\Users\test\file.txt'),
          equals('${RegExp.escape(r'C:\Users\test\')}.*'));
    });
    test('命令推导', () {
      expect(PermissionRule.derivePattern('git commit -m "msg"'), equals('git.*'));
      expect(PermissionRule.derivePattern('npm install'), equals('npm.*'));
    });
    test('空字符串返回 .*', () {
      expect(PermissionRule.derivePattern(''), equals('.*'));
      expect(PermissionRule.derivePattern('ls'), equals('ls.*'));
    });
  });

  group('PermissionConfig - 白名单/黑名单综合判定', () {
    test('空配置 - 所有工具 ask', () {
      final config = PermissionConfig.empty();
      expect(config.evaluate('file_write', {'path': '/test'}), equals(PermissionVerdict.ask));
      expect(config.evaluate('command_execute', {'command': 'ls'}), equals(PermissionVerdict.ask));
    });

    test('白名单: file_write regex + file_read all', () {
      final config = PermissionConfig(whitelist: [
        PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex),
        PermissionRule(tool: 'file_read', mode: PermissionMatchMode.all),
      ]);
      expect(config.evaluate('file_write', {'path': '/workspace/src/main.dart'}), equals(PermissionVerdict.allow));
      expect(config.evaluate('file_write', {'path': '/tmp/test.txt'}), equals(PermissionVerdict.ask));
      expect(config.evaluate('file_read', {'path': '/etc/passwd'}), equals(PermissionVerdict.allow));
    });

    test('黑名单: 阻止 rm -rf 和 sudo', () {
      final config = PermissionConfig(blacklist: [
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'rm\s+-rf.*', mode: PermissionMatchMode.regex),
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'^sudo\s+.*', mode: PermissionMatchMode.regex),
      ]);
      expect(config.evaluate('command_execute', {'command': 'rm -rf /'}), equals(PermissionVerdict.deny));
      expect(config.evaluate('command_execute', {'command': 'sudo apt install'}), equals(PermissionVerdict.deny));
      expect(config.evaluate('command_execute', {'command': 'echo hello'}), equals(PermissionVerdict.ask));
    });

    test('黑名单优先于白名单 - 文件写入', () {
      final config = PermissionConfig(
        whitelist: [PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all)],
        blacklist: [PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/etc/.*', mode: PermissionMatchMode.regex)],
      );
      expect(config.evaluate('file_write', {'path': '/etc/config'}), equals(PermissionVerdict.deny));
      expect(config.evaluate('file_write', {'path': '/workspace/test.txt'}), equals(PermissionVerdict.allow));
    });

    test('黑名单优先于白名单 - 命令执行', () {
      final config = PermissionConfig(
        whitelist: [PermissionRule(tool: 'command_execute', mode: PermissionMatchMode.all)],
        blacklist: [
          PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'rm\s+-rf.*', mode: PermissionMatchMode.regex),
          PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'^sudo\s+.*', mode: PermissionMatchMode.regex),
        ],
      );
      expect(config.evaluate('command_execute', {'command': 'rm -rf /'}), equals(PermissionVerdict.deny));
      expect(config.evaluate('command_execute', {'command': 'git status'}), equals(PermissionVerdict.allow));
    });

    test('同时命中白名单 exact 和黑名单 regex → deny', () {
      final config = PermissionConfig(
        whitelist: [PermissionRule(tool: 'command_execute', arg: 'command', pattern: 'sudo apt install', mode: PermissionMatchMode.exact)],
        blacklist: [PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'^sudo\s+.*', mode: PermissionMatchMode.regex)],
      );
      expect(config.evaluate('command_execute', {'command': 'sudo apt install'}), equals(PermissionVerdict.deny));
    });

    test('多工具组合: 读写删 + 命令', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex),
          PermissionRule(tool: 'file_delete', arg: 'path', pattern: r'/tmp/.*', mode: PermissionMatchMode.regex),
          PermissionRule(tool: 'file_read', mode: PermissionMatchMode.all),
        ],
        blacklist: [PermissionRule(tool: 'file_delete', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex)],
      );
      expect(config.evaluate('file_read', {'path': '/etc/passwd'}), equals(PermissionVerdict.allow));
      expect(config.evaluate('file_write', {'path': '/workspace/test.txt'}), equals(PermissionVerdict.allow));
      expect(config.evaluate('file_write', {'path': '/tmp/test.txt'}), equals(PermissionVerdict.ask));
      expect(config.evaluate('file_delete', {'path': '/workspace/src/main.dart'}), equals(PermissionVerdict.deny));
      expect(config.evaluate('file_delete', {'path': '/tmp/cache'}), equals(PermissionVerdict.allow));
      expect(config.evaluate('command_execute', {'command': 'ls'}), equals(PermissionVerdict.ask));
    });

    test('不可变性: add/remove 返回新实例', () {
      final wlRule = PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all);
      final blRule = PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'rm\s+-rf.*', mode: PermissionMatchMode.regex);
      final config = PermissionConfig.empty()
          .addWhitelistRule(wlRule)
          .addBlacklistRule(blRule);
      expect(config.whitelist.length, equals(1));
      expect(config.blacklist.length, equals(1));

      final removed = config.removeWhitelistRule(wlRule).removeBlacklistRule(blRule);
      expect(removed.whitelist, isEmpty);
      expect(removed.blacklist, isEmpty);
    });

    test('JSON 序列化往返', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex),
          PermissionRule(tool: 'command_execute', mode: PermissionMatchMode.all),
        ],
        blacklist: [PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'rm\s+-rf.*', mode: PermissionMatchMode.regex)],
      );
      final restored = PermissionConfig.fromJsonString(config.toJsonString());
      expect(restored.whitelist.length, equals(2));
      expect(restored.blacklist.length, equals(1));
      expect(restored.whitelist[0].mode, equals(PermissionMatchMode.regex));
      expect(restored.whitelist[1].mode, equals(PermissionMatchMode.all));
    });
  });

  group('ToolPermissionManager - 文件读写权限校验', () {
    late ToolPermissionManager manager;
    setUp(() => manager = ToolPermissionManager());

    test('file_read 需要权限 - 无配置时默认拒绝', () async {
      final tool = _MockTool(name: 'file_read', requiresPermission: true, permissionType: 'file_read', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/any'}), equals(PermissionDecision.deny));
    });

    test('file_read 白名单命中 - 放行', () async {
      manager.configure(PermissionConfig(whitelist: [
        PermissionRule(tool: 'file_read', mode: PermissionMatchMode.all),
      ]));
      final tool = _MockTool(name: 'file_read', requiresPermission: true, permissionType: 'file_read', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/any'}), equals(PermissionDecision.allow));
    });

    test('file_write 无配置无回调 - 默认拒绝', () async {
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/test.txt'}), equals(PermissionDecision.deny));
    });

    test('file_write 白名单 regex 命中 - 放行', () async {
      manager.configure(PermissionConfig(whitelist: [
        PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex),
      ]));
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/workspace/src/main.dart'}), equals(PermissionDecision.allow));
      expect(manager.lastDenyMessage, isNull);
    });

    test('file_write 白名单未命中 - 走用户确认', () async {
      manager.configure(PermissionConfig(whitelist: [
        PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex),
      ]));
      manager.onPermissionRequest = (r) async => PermissionDecision.allow;
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/etc/passwd'}), equals(PermissionDecision.allow));
    });

    test('file_write 黑名单命中 - 拒绝并设置 lastDenyMessage', () async {
      manager.configure(PermissionConfig(blacklist: [
        PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/etc/.*', mode: PermissionMatchMode.regex),
      ]));
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      final d = await manager.checkPermission(tool, {'path': '/etc/shadow'});
      expect(d, equals(PermissionDecision.deny));
      expect(manager.lastDenyMessage, contains('安全策略阻止'));
    });

    test('file_write 黑名单优先于白名单', () async {
      manager.configure(PermissionConfig(
        whitelist: [PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all)],
        blacklist: [PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/etc/.*', mode: PermissionMatchMode.regex)],
      ));
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/etc/config'}), equals(PermissionDecision.deny));
      expect(await manager.checkPermission(tool, {'path': '/workspace/test.txt'}), equals(PermissionDecision.allow));
    });

    test('file_delete 白名单允许 /tmp，黑名单阻止 /workspace', () async {
      manager.configure(PermissionConfig(
        whitelist: [PermissionRule(tool: 'file_delete', arg: 'path', pattern: r'/tmp/.*', mode: PermissionMatchMode.regex)],
        blacklist: [PermissionRule(tool: 'file_delete', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex)],
      ));
      final tool = _MockTool(name: 'file_delete', requiresPermission: true, permissionType: 'file_delete', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/tmp/cache'}), equals(PermissionDecision.allow));
      expect(await manager.checkPermission(tool, {'path': '/workspace/src/main.dart'}), equals(PermissionDecision.deny));
    });
  });

  group('ToolPermissionManager - 命令执行权限校验', () {
    late ToolPermissionManager manager;
    setUp(() => manager = ToolPermissionManager());

    test('无配置 - 默认拒绝', () async {
      final tool = _MockTool(name: 'command_execute', requiresPermission: true, permissionType: 'command_execute', permissionArgKey: 'command');
      expect(await manager.checkPermission(tool, {'command': 'ls'}), equals(PermissionDecision.deny));
    });

    test('白名单仅允许 git 命令', () async {
      manager.configure(PermissionConfig(whitelist: [
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'git\s+.*', mode: PermissionMatchMode.regex),
      ]));
      final tool = _MockTool(name: 'command_execute', requiresPermission: true, permissionType: 'command_execute', permissionArgKey: 'command');
      expect(await manager.checkPermission(tool, {'command': 'git status'}), equals(PermissionDecision.allow));
      expect(await manager.checkPermission(tool, {'command': 'rm -rf /'}), equals(PermissionDecision.deny));
    });

    test('黑名单阻止 rm -rf / sudo / chmod 777', () async {
      manager.configure(PermissionConfig(blacklist: [
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'rm\s+-rf.*', mode: PermissionMatchMode.regex),
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'^sudo\s+.*', mode: PermissionMatchMode.regex),
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'chmod\s+777.*', mode: PermissionMatchMode.regex),
      ]));
      final tool = _MockTool(name: 'command_execute', requiresPermission: true, permissionType: 'command_execute', permissionArgKey: 'command');
      expect(await manager.checkPermission(tool, {'command': 'rm -rf /'}), equals(PermissionDecision.deny));
      expect(await manager.checkPermission(tool, {'command': 'sudo rm -rf /'}), equals(PermissionDecision.deny));
      expect(await manager.checkPermission(tool, {'command': 'chmod 777 /etc/shadow'}), equals(PermissionDecision.deny));
      expect(manager.lastDenyMessage, contains('安全策略阻止'));
    });

    test('黑名单优先 - all 白名单 + 多条黑名单', () async {
      manager.configure(PermissionConfig(
        whitelist: [PermissionRule(tool: 'command_execute', mode: PermissionMatchMode.all)],
        blacklist: [
          PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'rm\s+-rf.*', mode: PermissionMatchMode.regex),
          PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'^sudo\s+.*', mode: PermissionMatchMode.regex),
        ],
      ));
      final tool = _MockTool(name: 'command_execute', requiresPermission: true, permissionType: 'command_execute', permissionArgKey: 'command');
      expect(await manager.checkPermission(tool, {'command': 'git status'}), equals(PermissionDecision.allow));
      expect(await manager.checkPermission(tool, {'command': 'npm install'}), equals(PermissionDecision.allow));
      expect(await manager.checkPermission(tool, {'command': 'rm -rf /'}), equals(PermissionDecision.deny));
      expect(await manager.checkPermission(tool, {'command': 'sudo apt update'}), equals(PermissionDecision.deny));
    });

    test('白名单未命中 - 走用户确认', () async {
      manager.configure(PermissionConfig(whitelist: [
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'git\s+.*', mode: PermissionMatchMode.regex),
      ]));
      var captured = false;
      manager.onPermissionRequest = (r) async {
        captured = true;
        expect(r.suggestedPattern, isNotNull);
        return PermissionDecision.allow;
      };
      final tool = _MockTool(name: 'command_execute', requiresPermission: true, permissionType: 'command_execute', permissionArgKey: 'command');
      expect(await manager.checkPermission(tool, {'command': 'flutter run'}), equals(PermissionDecision.allow));
      expect(captured, isTrue);
    });
  });

  group('ToolPermissionManager - 缓存与规则管理', () {
    late ToolPermissionManager manager;
    setUp(() => manager = ToolPermissionManager());

    test('allowAlways 后自动放行不再调用回调', () async {
      manager.configure(PermissionConfig.empty());
      manager.onPermissionRequest = (_) async => PermissionDecision.allowAlways;
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');

      await manager.checkPermission(tool, {'path': '/test'});
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);

      manager.onPermissionRequest = (_) async => throw StateError('不应调用');
      expect(await manager.checkPermission(tool, {'path': '/other'}), equals(PermissionDecision.allow));
    });

    test('configure 时 all 类型白名单自动加入缓存', () {
      manager.configure(PermissionConfig(whitelist: [
        PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all),
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: 'git.*', mode: PermissionMatchMode.regex),
      ]));
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);
      expect(manager.allowedAlwaysPatterns.contains('command_execute'), isFalse);
    });

    test('clearAllowedAlways 清除缓存，重新 configure 空 config 后不再自动放行', () async {
      manager.configure(PermissionConfig(whitelist: [
        PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all),
      ]));
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);

      manager.clearAllowedAlways();
      expect(manager.allowedAlwaysPatterns, isEmpty);

      // 重新配置空 config，all 规则不再注入缓存
      manager.configure(PermissionConfig.empty());
      expect(manager.allowedAlwaysPatterns, isEmpty);

      // 无 always 缓存 + 空 config → 无回调 → 默认拒绝
      manager.onPermissionRequest = (_) async => PermissionDecision.deny;
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      expect(await manager.checkPermission(tool, {'path': '/test'}), equals(PermissionDecision.deny));
    });

    test('addApproval exact 触发回调但不加入缓存', () {
      PermissionConfig? captured;
      manager.onConfigChanged = (c) => captured = c;
      manager.addApproval(PermissionRule(tool: 'file_write', arg: 'path', pattern: '/x', mode: PermissionMatchMode.exact));
      expect(captured!.whitelist.length, equals(1));
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isFalse);
    });

    test('addApproval all 模式加入缓存', () {
      manager.addApproval(PermissionRule(tool: 'command_execute', mode: PermissionMatchMode.all));
      expect(manager.allowedAlwaysPatterns.contains('command_execute'), isTrue);
    });

    test('removeApproval 清除缓存', () {
      final rule = PermissionRule(tool: 'file_write', mode: PermissionMatchMode.all);
      manager.addApproval(rule);
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isTrue);
      manager.removeApproval(rule);
      expect(manager.allowedAlwaysPatterns.contains('file_write'), isFalse);
    });

    test('lastDenyMessage: 黑名单拒绝设置, 白名单放行清除', () async {
      manager.configure(PermissionConfig(blacklist: [
        PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/etc/.*', mode: PermissionMatchMode.regex),
      ]));
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      await manager.checkPermission(tool, {'path': '/etc/passwd'});
      expect(manager.lastDenyMessage, isNotNull);
      await manager.checkPermission(tool, {'path': '/workspace/test.txt'});
      expect(manager.lastDenyMessage, isNull);
    });
  });

  group('PermissionForwarder - 子 Agent 权限转发', () {
    test('无转发回调时默认拒绝', () async {
      final f = PermissionForwarder();
      final tool = _MockTool(name: 'file_write', requiresPermission: true, permissionType: 'file_write', permissionArgKey: 'path');
      expect(await f.checkPermission(tool, {'path': '/test'}), equals(PermissionDecision.deny));
    });

    test('通过转发回调获取决策', () async {
      final f = PermissionForwarder();
      f.onForwardPermissionRequest = (r) async => PermissionDecision.allow;
      final tool = _MockTool(name: 'command_execute', requiresPermission: true, permissionType: 'command_execute', permissionArgKey: 'command');
      expect(await f.checkPermission(tool, {'command': 'git status'}), equals(PermissionDecision.allow));
    });

    test('继承规则引擎 - 黑名单命中不需要转发', () async {
      final f = PermissionForwarder();
      f.configure(PermissionConfig(blacklist: [
        PermissionRule(tool: 'command_execute', arg: 'command', pattern: r'rm\s+-rf.*', mode: PermissionMatchMode.regex),
      ]));
      final tool = _MockTool(name: 'command_execute', requiresPermission: true, permissionType: 'command_execute', permissionArgKey: 'command');
      expect(await f.checkPermission(tool, {'command': 'rm -rf /'}), equals(PermissionDecision.deny));
    });
  });

  group('枚举工具方法', () {
    test('PermissionMatchMode.fromString', () {
      expect(PermissionMatchMode.fromString('exact'), equals(PermissionMatchMode.exact));
      expect(PermissionMatchMode.fromString('regex'), equals(PermissionMatchMode.regex));
      expect(PermissionMatchMode.fromString('all'), equals(PermissionMatchMode.all));
      expect(PermissionMatchMode.fromString('invalid'), equals(PermissionMatchMode.exact));
    });
    test('PermissionDecision.fromString', () {
      expect(PermissionDecision.fromString('allow'), equals(PermissionDecision.allow));
      expect(PermissionDecision.fromString('allowAlways'), equals(PermissionDecision.allowAlways));
      expect(PermissionDecision.fromString('unknown'), equals(PermissionDecision.deny));
    });
    test('PermissionApprovalScope.fromString', () {
      expect(PermissionApprovalScope.fromString('once'), equals(PermissionApprovalScope.once));
      expect(PermissionApprovalScope.fromString('all'), equals(PermissionApprovalScope.all));
    });
    test('AgentStatus.waitingPermission', () {
      expect(AgentStatus.waitingPermission.name, equals('waitingPermission'));
    });
  });

  group('AgentPermissionRequest 序列化', () {
    test('toMap / fromMap 往返', () {
      final req = AgentPermissionRequest(
        requestId: 'perm_001', type: 'tool_execution',
        description: 'test', functionName: 'file_write',
        permissionType: 'file_write',
        permissionArgKey: 'path', permissionArgValue: '/workspace/test.txt',
        suggestedPattern: '${RegExp.escape('/workspace/')}.*',
      );
      final restored = AgentPermissionRequest.fromMap(req.toMap());
      expect(restored.requestId, equals('perm_001'));
      expect(restored.permissionArgValue, equals('/workspace/test.txt'));
    });
  });

  group('PermissionRule JSON 序列化与相等性', () {
    test('toJson / fromJson 往返', () {
      final rule = PermissionRule(tool: 'file_write', arg: 'path', pattern: r'/workspace/.*', mode: PermissionMatchMode.regex);
      final restored = PermissionRule.fromJson(jsonDecode(jsonEncode(rule.toJson())));
      expect(restored.tool, equals('file_write'));
      expect(restored.mode, equals(PermissionMatchMode.regex));
    });
    test('equality', () {
      final a = PermissionRule(tool: 'x', arg: 'p', pattern: '/t', mode: PermissionMatchMode.exact);
      final b = PermissionRule(tool: 'x', arg: 'p', pattern: '/t', mode: PermissionMatchMode.exact);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(PermissionRule(tool: 'x', arg: 'p', pattern: '/o', mode: PermissionMatchMode.exact))));
    });
  });
}

class _MockTool extends AgentTool {
  @override final String name;
  @override final bool requiresPermission;
  @override final String permissionType;
  @override final String? permissionArgKey;
  _MockTool({required this.name, required this.requiresPermission, required this.permissionType, this.permissionArgKey});
  @override String get description => 'Mock';
  @override Map<String, dynamic> get inputJsonSchema => {'type': 'object'};
  @override Future<ToolResult> execute(Map<String, dynamic> arguments) async => ToolResult.success('mock');
}
