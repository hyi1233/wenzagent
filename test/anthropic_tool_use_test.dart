import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/tool/builtin/builtin_tools.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

/// Anthropic provider 工具调用 & 技能使用场景测试
///
/// 核心场景：
/// 1. Anthropic 流式模式下工具调用参数是否正确传递（非空）
/// 2. 多轮工具调用是否正常工作
/// 3. 工具调用事件（toolCallStart/toolCallResult）是否正确携带 arguments
///
/// 环境变量：
///   anthropic_api_key  - Anthropic API Key（必填）
///   anthropic_api_url  - Anthropic API URL（可选，默认 https://api.anthropic.com/v1）
///   anthropic_api_model - 模型名称（可选，默认 claude-sonnet-4-20250514）
void main() {
  late String apiKey;
  late String apiUrl;
  late String apiModel;
  late ProviderConfig providerConfig;

  late AgentImpl agent;
  late AgentProxy localProxy;
  late CachedAgentProxy cachedProxy;
  late MessageStoreService messageStore;
  late String employeeId;
  late String deviceId;

  setUpAll(() async {
    apiKey = Platform.environment['anthropic_api_key'] ?? '';
    apiUrl = Platform.environment['anthropic_api_url'] ?? 'https://api.anthropic.com/v1';
    apiModel = Platform.environment['anthropic_api_model'] ?? 'claude-sonnet-4-20250514';

    if (apiKey.isEmpty) {
      throw Exception(
        '请设置环境变量 anthropic_api_key\n'
        '  Windows PowerShell: \$env:anthropic_api_key = "sk-ant-..."',
      );
    }

    print('\n========================================');
    print('  Anthropic 工具调用 & 技能使用场景测试');
    print('========================================');
    print('API URL: $apiUrl');
    print('API Model: $apiModel');

    providerConfig = ProviderConfig(
      provider: LLMProvider.anthropic,
      apiKey: apiKey,
      baseUrl: apiUrl,
      model: apiModel,
    );

    await HiveManager.instance.initialize(
      storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive_anthropic',
    );

    employeeId = 'anthropic-test-${DateTime.now().millisecondsSinceEpoch}';
    deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
    print('Employee ID: $employeeId');
    print('Device ID: $deviceId\n');
  });

  setUp(() async {
    messageStore = MessageStoreServiceImpl(deviceId: deviceId);

    final adapter = PersistentChatAdapter();

    adapter.persistMessage = (messageData) async {
      final entity = AiEmployeeMessageEntity.fromMap(messageData);
      await messageStore.addMessage(entity, deviceId: deviceId);
    };

    adapter.loadMessages = (empId) async {
      final messages = await messageStore.getMessages(empId);
      return messages.map((m) => m.toMap()).toList();
    };

    adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await messageStore.updateMessageStatus(messageId, status.name, error: error);
    };

    adapter.deleteMessagesCallback = (empId) async {
      await messageStore.deleteMessages(empId, deviceId: deviceId);
    };

    agent = AgentImpl(
      employeeId: employeeId,
      chatAdapter: adapter,
    );

    await agent.initialize(enableBuiltinTools: false);
    agent.registerTools(BuiltinTools.readOnly());
    await agent.setProvider(providerConfig);

    localProxy = AgentProxy.local(
      employeeId: employeeId,
      deviceId: deviceId,
      localAgent: agent,
    );

    cachedProxy = CachedAgentProxy(
      proxy: localProxy,
      messageStore: messageStore,
      deviceId: deviceId,
      employeeId: employeeId,
    );

    await cachedProxy.initialize();
  });

  tearDown(() async {
    await cachedProxy.dispose();
    await localProxy.dispose();
    await agent.dispose();
    await messageStore.deleteMessages(employeeId, deviceId: deviceId);
  });

  tearDownAll(() async {
    await HiveManager.instance.close();
  });

  // ===================================================================
  // 一、工具调用参数传递验证（核心 Bug 复现）
  // ===================================================================
  group('一、工具调用参数传递', () {
    test('Anthropic 流式工具调用：arguments 不应为空', () async {
      print('\n--- 测试：Anthropic 工具调用参数非空 ---');

      final toolCallEvents = <Map<String, dynamic>>[];
      final idleCompleter = Completer<void>();

      // 收集所有工具调用事件
      localProxy.onEvent.listen((event) {
        final type = event['type'] as String?;
        if (type == 'toolCallStart' || type == 'toolCallResult') {
          toolCallEvents.add(Map<String, dynamic>.from(event));
          final data = event['data'] as Map<String, dynamic>? ?? {};
          print('  [事件] $type: toolName=${data['toolName']}, '
              'arguments=${data['arguments']}');
        }
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      // 发送一条一定会触发工具调用的消息
      await cachedProxy.sendMessage(MessageInput(
        content: '请列出当前目录下的文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待 idle 超时'),
      );

      // 验证：应有至少一个 toolCallStart 事件
      final startEvents = toolCallEvents
          .where((e) => e['type'] == 'toolCallStart')
          .toList();

      print('\n  toolCallStart 事件数: ${startEvents.length}');

      expect(startEvents.isNotEmpty, isTrue,
          reason: 'Anthropic 应触发至少一个工具调用');

      // 验证：arguments 不应为空 Map {}
      for (final event in startEvents) {
        final data = event['data'] as Map<String, dynamic>?;
        final args = data?['arguments'];
        print('  检查 arguments: $args (类型: ${args.runtimeType})');

        // 核心断言：arguments 不应是空 Map
        // 如果 arguments 是 {} 则说明 bug 存在
        expect(args, isNotNull,
            reason: 'arguments 不应为 null');

        if (args is Map) {
          expect(args, isNotEmpty,
              reason: 'Anthropic 流式工具调用的 arguments 不应为空 Map {}，'
                  '请检查 langchain_chat_adapter.dart 中是否使用了 argumentsRaw');
        }
      }

      // 验证：成对的 toolCallResult
      final resultEvents = toolCallEvents
          .where((e) => e['type'] == 'toolCallResult')
          .toList();
      expect(resultEvents.length, equals(startEvents.length),
          reason: 'toolCallStart 和 toolCallResult 应成对出现');

      print('  [通过]\n');
    });

    test('多参数工具调用：arguments 应包含完整参数', () async {
      print('\n--- 测试：多参数工具调用 ---');

      final startEvents = <Map<String, dynamic>>[];
      final idleCompleter = Completer<void>();

      localProxy.onEvent.listen((event) {
        if (event['type'] == 'toolCallStart') {
          startEvents.add(Map<String, dynamic>.from(event));
        }
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      // 读取文件，这个工具调用通常会有 path 参数
      await cachedProxy.sendMessage(MessageInput(
        content: '请读取 pubspec.yaml 文件的内容',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待 idle 超时'),
      );

      print('  toolCallStart 事件数: ${startEvents.length}');

      for (final event in startEvents) {
        final data = event['data'] as Map<String, dynamic>? ?? {};
        final args = data['arguments'];
        final toolName = data['toolName'] as String? ?? '';
        print('  工具: $toolName, arguments: $args');

        if (toolName.contains('read') || toolName.contains('file')) {
          // 文件读取工具应有 path 参数
          expect(args, isNotNull);
          if (args is Map) {
            expect(args, isNotEmpty,
                reason: '文件读取工具应包含参数');
            // 验证参数值是有效的（非空字符串等）
            for (final entry in args.entries) {
              print('    参数 ${entry.key} = ${entry.value}');
              expect(entry.value, isNotNull,
                  reason: '参数 ${entry.key} 的值不应为 null');
            }
          }
        }
      }

      print('  [通过]\n');
    });
  });

  // ===================================================================
  // 二、工具调用流程完整性
  // ===================================================================
  group('二、工具调用流程完整性', () {
    test('多轮工具调用：状态流转正确', () async {
      print('\n--- 测试：多轮工具调用状态流转 ---');

      final statuses = <String>[];
      final idleCompleter = Completer<void>();

      cachedProxy.onStateChanged.listen((state) {
        statuses.add(state.status.name);
        print('  [状态] ${state.status.name}');
        if (state.status == AgentStatus.idle && statuses.length > 1) {
          if (!idleCompleter.isCompleted) idleCompleter.complete();
        }
      });

      // 使用一个需要多个步骤的请求
      await cachedProxy.sendMessage(MessageInput(
        content: '请列出 lib 目录的文件，然后读取 pubspec.yaml 文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException('等待 idle 超时'),
      );

      // 验证状态流转
      expect(statuses, contains('idle'),
          reason: '最终状态应为 idle');
      expect(statuses.any((s) => s == 'processing' || s == 'streaming'),
          isTrue, reason: '过程中应有 processing 或 streaming 状态');

      print('  状态序列: $statuses');
      print('  [通过]\n');
    });

    test('toolCallStart 和 toolCallResult 成对出现', () async {
      print('\n--- 测试：事件成对性 ---');

      final events = <Map<String, dynamic>>[];
      final idleCompleter = Completer<void>();

      localProxy.onEvent.listen((event) {
        final type = event['type'] as String?;
        if (type == 'toolCallStart' || type == 'toolCallResult') {
          events.add(Map<String, dynamic>.from(event));
          final data = event['data'] as Map<String, dynamic>? ?? {};
          print('  [事件] $type: ${data['toolName']}');
        }
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle && events.isNotEmpty) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请搜索 dart 文件并读取 pubspec.yaml',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      final starts = events.where((e) => e['type'] == 'toolCallStart').toList();
      final results = events.where((e) => e['type'] == 'toolCallResult').toList();

      print('  toolCallStart: ${starts.length} 个');
      print('  toolCallResult: ${results.length} 个');

      expect(starts.length, equals(results.length),
          reason: 'Start 和 Result 应成对出现');
      expect(starts.length, greaterThan(0),
          reason: '至少应有 1 对工具调用事件');

      print('  [通过]\n');
    });

    test('工具调用结果非空且有效', () async {
      print('\n--- 测试：工具调用结果有效性 ---');

      final resultEvents = <Map<String, dynamic>>[];
      final idleCompleter = Completer<void>();

      localProxy.onEvent.listen((event) {
        if (event['type'] == 'toolCallResult') {
          resultEvents.add(Map<String, dynamic>.from(event));
        }
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请列出当前目录的文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      for (final event in resultEvents) {
        final data = event['data'] as Map<String, dynamic>? ?? {};
        final result = data['result'] as String?;
        final isError = data['isError'] as bool? ?? false;
        final toolName = data['toolName'] as String?;

        print('  工具: $toolName, isError: $isError, '
            'result长度: ${result?.length ?? 0}');

        expect(result, isNotNull,
            reason: '工具调用结果不应为 null');
        expect(result, isNotEmpty,
            reason: '工具调用结果不应为空字符串');

        // 如果 arguments 为空导致的错误，结果中会包含相关错误信息
        if (isError) {
          print('  ⚠️ 工具执行出错: $result');
        }
      }

      print('  [通过]\n');
    });
  });

  // ===================================================================
  // 三、流式响应内容验证
  // ===================================================================
  group('三、流式响应内容', () {
    test('最终应收到文本响应（工具调用后 LLM 总结）', () async {
      print('\n--- 测试：工具调用后有文本总结 ---');

      final snapshots = <List<AgentMessage>>[];
      final idleCompleter = Completer<void>();

      cachedProxy.onMessagesChanged.listen((messages) {
        snapshots.add(List.from(messages));
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请列出 pubspec.yaml 的前3行内容',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      // 检查最终消息列表中应有 assistant 消息
      final finalSnapshot = snapshots.last;
      final assistantMessages = finalSnapshot.where(
          (m) => m.role == 'assistant' && m.type != 'functionCall').toList();

      print('  最终消息数: ${finalSnapshot.length}');
      print('  assistant 消息数: ${assistantMessages.length}');

      for (final m in assistantMessages) {
        print('  - assistant[${m.id}] type=${m.type} '
            'content长度=${m.content?.length ?? 0}');
      }

      // 应有至少一条带内容的 assistant 消息（LLM 的总结）
      expect(assistantMessages.isNotEmpty, isTrue,
          reason: '应有 assistant 消息');

      print('  [通过]\n');
    });
  });

  // ===================================================================
  // 四、argumentsRaw vs arguments 对比诊断
  // ===================================================================
  group('四、argumentsRaw vs arguments 诊断', () {
    test('打印工具调用的 argumentsRaw 以辅助诊断', () async {
      print('\n--- 诊断：arguments vs argumentsRaw ---');

      final toolCallStarts = <Map<String, dynamic>>[];
      final idleCompleter = Completer<void>();

      localProxy.onEvent.listen((event) {
        if (event['type'] == 'toolCallStart') {
          toolCallStarts.add(Map<String, dynamic>.from(event));
        }
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请读取 pubspec.yaml 文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      if (toolCallStarts.isEmpty) {
        print('  未触发工具调用');
        return;
      }

      for (final event in toolCallStarts) {
        final data = event['data'] as Map<String, dynamic>? ?? {};
        final toolName = data['toolName'];
        final args = data['arguments'];
        print('  工具: $toolName');
        print('  arguments (Map): $args');

        if (args is Map && args.isEmpty) {
          print('  ❌ BUG 确认: arguments 为空 Map {}');
          print('  原因: langchain_anthropic 的 MessageStreamEventTransformer '
              '在流式 delta 事件中设置 arguments: const {}，'
              '仅将 JSON 填入 argumentsRaw');
          print('  修复: langchain_chat_adapter.dart 应在 arguments 为空时'
              '尝试 jsonDecode(argumentsRaw)');
        } else if (args is Map && args.isNotEmpty) {
          print('  ✅ arguments 非空，参数传递正常');
          // 打印每个参数
          for (final entry in args.entries) {
            print('    ${entry.key}: ${entry.value}');
          }
        }
      }

      print('  [通过]\n');
    });
  });

  print('\n=== 所有 Anthropic 测试完成 ===\n');
}
