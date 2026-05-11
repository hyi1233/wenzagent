import 'package:test/test.dart';
import 'package:wenzagent/src/persistence/entities/mcp_server_config.dart';
import 'package:wenzagent/src/skill/mcp/mcp_client.dart';
import 'package:wenzagent/src/skill/mcp/mcp_client_provider.dart';
import 'package:wenzagent/src/skill/mcp/mcp_skill.dart';
import 'package:wenzagent/src/skill/skill.dart';

void main() {
  group('McpClientProvider', () {
    test('接口定义 createClient 方法', () {
      final provider = _MockMcpClientProvider();
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final client = provider.createClient(config);
      expect(client, isA<McpClient>());
      expect(client, isA<_MockMcpClient>());
    });

    test('createClient 传入正确的配置', () {
      bool callbackCalled = false;
      final provider = _TrackingMcpClientProvider(() {
        callbackCalled = true;
      });

      final config = McpServerConfig(
        name: 'tracked',
        transportType: 'sse',
        url: 'http://localhost:8080/sse',
      );

      provider.createClient(config);
      expect(callbackCalled, isTrue);
    });
  });

  group('McpSkill', () {
    tearDown(() {
      // 恢复静态工厂为默认值
      McpSkill.clientFactory = (config) => _MockMcpClient(config);
    });

    test('使用实例注入的 McpClientProvider', () async {
      final mockProvider = _MockMcpClientProvider();
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-mcp',
        name: 'Test MCP',
        description: 'Test',
        serverConfig: config,
        clientProvider: mockProvider,
      );

      expect(skill.type, equals(SkillType.mcp));
      expect(skill.status, equals(SkillStatus.uninitialized));

      // 初始化（使用 mock client，不实际连接）
      await skill.initialize();
      expect(skill.status, equals(SkillStatus.active));
      expect(skill.tools.length, equals(2)); // mock 返回 2 个工具

      await skill.dispose();
      expect(skill.status, equals(SkillStatus.disposed));
    });

    test('回退到静态 clientFactory', () async {
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      // 设置静态工厂
      McpSkill.clientFactory = (cfg) => _MockMcpClient(cfg);

      final skill = McpSkill(
        id: 'test-mcp-static',
        name: 'Test MCP Static',
        description: 'Test',
        serverConfig: config,
        // 不注入 clientProvider
      );

      await skill.initialize();
      expect(skill.status, equals(SkillStatus.active));
      expect(skill.tools.length, equals(2));

      await skill.dispose();
    });

    test('实例注入优先于静态工厂', () async {
      bool staticFactoryCalled = false;
      bool instanceProviderCalled = false;

      // 设置静态工厂（不应被调用）
      McpSkill.clientFactory = (cfg) {
        staticFactoryCalled = true;
        return _MockMcpClient(cfg);
      };

      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-priority',
        name: 'Test Priority',
        description: 'Test',
        serverConfig: config,
        clientProvider: _TrackingMcpClientProvider(() {
          instanceProviderCalled = true;
        }),
      );

      await skill.initialize();

      expect(instanceProviderCalled, isTrue);
      expect(staticFactoryCalled, isFalse);

      await skill.dispose();
    });

    test('healthCheck 返回正确结果', () async {
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-health',
        name: 'Test Health',
        description: 'Test',
        serverConfig: config,
        clientProvider: _MockMcpClientProvider(),
      );

      // 未初始化时 healthCheck 返回 false
      expect(await skill.healthCheck(), isFalse);

      await skill.initialize();
      expect(await skill.healthCheck(), isTrue);

      await skill.dispose();
      expect(await skill.healthCheck(), isFalse);
    });

    test('serverConfig getter 返回正确配置', () {
      final config = McpServerConfig(
        name: 'my_server',
        transportType: 'sse',
        url: 'http://localhost:9090/sse',
      );

      final skill = McpSkill(
        id: 'test-config',
        name: 'Test Config',
        description: 'Test',
        serverConfig: config,
      );

      expect(skill.serverConfig.name, equals('my_server'));
      expect(skill.serverConfig.transportType, equals('sse'));
    });

    test('工具名称来自 MCP 服务器', () async {
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-tools',
        name: 'Test Tools',
        description: 'Test',
        serverConfig: config,
        clientProvider: _MockMcpClientProvider(),
      );

      await skill.initialize();
      final toolNames = skill.tools.map((t) => t.name).toList();
      expect(toolNames, equals(['mcp_mock_tool_1', 'mcp_mock_tool_2']));

      await skill.dispose();
    });
  });
}

// ===== Mock 类 =====

class _MockMcpClientProvider implements McpClientProvider {
  @override
  McpClient createClient(McpServerConfig config) => _MockMcpClient(config);
}

class _TrackingMcpClientProvider implements McpClientProvider {
  final void Function() onCreated;
  _TrackingMcpClientProvider(this.onCreated);

  @override
  McpClient createClient(McpServerConfig config) {
    onCreated();
    return _MockMcpClient(config);
  }
}

class _MockMcpClient implements McpClient {
  final McpServerConfig _config;
  bool _connected = false;

  _MockMcpClient(this._config);

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<List<McpToolDefinition>> listTools() async {
    if (!_connected) throw StateError('Not connected');
    return [
      const McpToolDefinition(name: 'mock_tool_1', description: 'Mock tool 1'),
      const McpToolDefinition(name: 'mock_tool_2', description: 'Mock tool 2'),
    ];
  }

  @override
  Future<McpToolCallResult> callTool(String name, Map<String, dynamic> arguments) async {
    return McpToolCallResult(content: 'mock result for $name');
  }

  @override
  Future<bool> ping() async => _connected;

  @override
  bool get isReconnecting => false;

  @override
  Future<void> reconnect() async {
    _connected = true;
  }

  @override
  Stream<McpReconnectEvent> get onReconnect => const Stream.empty();
}
