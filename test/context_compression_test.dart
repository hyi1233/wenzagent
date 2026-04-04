import 'dart:convert';

import 'package:langchain_core/chat_models.dart';
import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

/// 创建 AIChatMessageToolCall 的辅助函数
AIChatMessageToolCall _tc(String id, String name, Map<String, dynamic> args) {
  return AIChatMessageToolCall(
    id: id,
    name: name,
    argumentsRaw: jsonEncode(args),
    arguments: args,
  );
}

void main() {
  // ============================================================
  // TokenEstimator 测试
  // ============================================================
  group('CharBasedTokenEstimator', () {
    late CharBasedTokenEstimator estimator;

    setUp(() {
      estimator = CharBasedTokenEstimator(); // default charsPerToken=3.5
    });

    test('空字符串估算为 0 token', () {
      expect(estimator.estimateTokens(''), 0);
    });

    test('英文文本估算', () {
      // "hello" = 5 chars, ceil(5 / 3.5) = ceil(1.43) = 2
      expect(estimator.estimateTokens('hello'), 2);
    });

    test('中文文本估算', () {
      // "你好世界" = 4 chars, ceil(4 / 3.5) = ceil(1.14) = 2
      expect(estimator.estimateTokens('你好世界'), 2);
    });

    test('长文本估算', () {
      // 35 chars => ceil(35 / 3.5) = 10
      final text = 'a' * 35;
      expect(estimator.estimateTokens(text), 10);
    });

    test('自定义 charsPerToken', () {
      final custom = CharBasedTokenEstimator(charsPerToken: 4.0);
      // "12345678" = 8 chars, ceil(8 / 4) = 2
      expect(custom.estimateTokens('12345678'), 2);
    });

    test('HumanChatMessage 估算包含 overhead', () {
      final msg = ChatMessage.humanText('hello');
      final tokens = estimator.estimateMessageTokens(msg);
      // overhead=4 + estimateTokens("hello")=2 => 6
      expect(tokens, 6);
    });

    test('AIChatMessage 无 toolCalls 估算', () {
      final msg = AIChatMessage(content: 'response text');
      final tokens = estimator.estimateMessageTokens(msg);
      // overhead=4 + estimateTokens("response text")=ceil(13/3.5)=4 => 8
      expect(tokens, 8);
    });

    test('AIChatMessage 有 toolCalls 额外估算元数据', () {
      final msg = AIChatMessage(
        content: '',
        toolCalls: [
          _tc('call_123', 'file_read', {'path': '/tmp/test.txt'}),
        ],
      );
      final tokens = estimator.estimateMessageTokens(msg);
      // overhead=4 + content("")=0 + toolCall id + name + argsJson
      // 应该明显大于单纯的 overhead
      expect(tokens, greaterThan(4));
    });

    test('ToolChatMessage 额外估算 toolCallId', () {
      final msg = ToolChatMessage(
        toolCallId: 'call_123',
        content: 'tool output',
      );
      final tokens = estimator.estimateMessageTokens(msg);
      // overhead=4 + content("tool output") + toolCallId("call_123")
      expect(tokens, greaterThan(4));
    });

    test('SystemChatMessage 估算', () {
      final msg = ChatMessage.system('You are a helpful assistant.');
      final tokens = estimator.estimateMessageTokens(msg);
      // overhead=4 + content tokens
      expect(tokens, greaterThan(4));
    });

    test('estimateMessagesTotal 包含请求 overhead', () {
      final messages = <ChatMessage>[
        ChatMessage.humanText('hi'),
        AIChatMessage(content: 'hello'),
      ];
      final total = estimator.estimateMessagesTotal(messages);
      final sum =
          estimator.estimateMessageTokens(messages[0]) +
          estimator.estimateMessageTokens(messages[1]);
      // total = sum + 3 (请求 overhead)
      expect(total, sum + 3);
    });

    test('空消息列表的 total 为 3 (请求 overhead)', () {
      expect(estimator.estimateMessagesTotal([]), 3);
    });
  });

  // ============================================================
  // ContextCompressionConfig 测试
  // ============================================================
  group('ContextCompressionConfig', () {
    test('默认值检查', () {
      const config = ContextCompressionConfig(maxContextTokens: 8000);
      expect(config.maxContextTokens, 8000);
      expect(config.reservedOutputTokens, 4096);
      expect(config.recentTurnsKeep, 3);
      expect(config.toolResultMaxChars, 200);
      expect(config.summaryMaxTokens, 500);
      expect(config.tokenEstimator, isNull);
    });

    test('enabled 属性: maxContextTokens > 0 时启用', () {
      const enabled = ContextCompressionConfig(maxContextTokens: 1000);
      const disabled = ContextCompressionConfig(maxContextTokens: 0);
      const negative = ContextCompressionConfig(maxContextTokens: -1);

      expect(enabled.enabled, true);
      expect(disabled.enabled, false);
      expect(negative.enabled, false);
    });

    test('effectiveBudget 计算', () {
      const config = ContextCompressionConfig(
        maxContextTokens: 8000,
        reservedOutputTokens: 2000,
      );
      expect(config.effectiveBudget, 6000);
    });

    test('estimator 默认返回 CharBasedTokenEstimator', () {
      const config = ContextCompressionConfig(maxContextTokens: 8000);
      expect(config.estimator, isA<CharBasedTokenEstimator>());
    });

    test('toMap / fromMap 序列化往返', () {
      const original = ContextCompressionConfig(
        maxContextTokens: 16000,
        reservedOutputTokens: 2048,
        recentTurnsKeep: 5,
        toolResultMaxChars: 300,
        summaryMaxTokens: 600,
      );
      final map = original.toMap();
      final restored = ContextCompressionConfig.fromMap(map);

      expect(restored.maxContextTokens, 16000);
      expect(restored.reservedOutputTokens, 2048);
      expect(restored.recentTurnsKeep, 5);
      expect(restored.toolResultMaxChars, 300);
      expect(restored.summaryMaxTokens, 600);
    });

    test('fromMap 空 Map 使用默认值', () {
      final config = ContextCompressionConfig.fromMap({});
      expect(config.maxContextTokens, 0);
      expect(config.reservedOutputTokens, 4096);
      expect(config.recentTurnsKeep, 3);
      expect(config.toolResultMaxChars, 200);
      expect(config.summaryMaxTokens, 500);
    });

    test('toString 包含关键信息', () {
      const config = ContextCompressionConfig(maxContextTokens: 8000);
      final str = config.toString();
      expect(str, contains('8000'));
      expect(str, contains('ContextCompressionConfig'));
    });
  });

  // ============================================================
  // SessionHistory 摘要字段测试
  // ============================================================
  group('SessionHistory 摘要字段', () {
    test('新建 SessionHistory 摘要字段为默认值', () {
      final session = SessionHistory(
        sessionUuid: 'test-uuid',
        employeeUuid: 'emp-uuid',
      );
      expect(session.conversationSummary, isNull);
      expect(session.summarizedUpToIndex, 0);
    });

    test('clear 重置摘要字段', () {
      final session = SessionHistory(
        sessionUuid: 'test-uuid',
        employeeUuid: 'emp-uuid',
        conversationSummary: 'some summary',
        summarizedUpToIndex: 5,
      );
      session.clear();
      expect(session.conversationSummary, isNull);
      expect(session.summarizedUpToIndex, 0);
    });

    test('toMap 包含摘要字段', () {
      final session = SessionHistory(
        sessionUuid: 'test-uuid',
        employeeUuid: 'emp-uuid',
        conversationSummary: 'summary text',
        summarizedUpToIndex: 3,
      );
      final map = session.toMap();
      expect(map['conversationSummary'], 'summary text');
      expect(map['summarizedUpToIndex'], 3);
    });

    test('toMap 不包含空摘要字段', () {
      final session = SessionHistory(
        sessionUuid: 'test-uuid',
        employeeUuid: 'emp-uuid',
      );
      final map = session.toMap();
      expect(map.containsKey('conversationSummary'), false);
      expect(map.containsKey('summarizedUpToIndex'), false);
    });
  });

  // ============================================================
  // ContextCompressor.groupIntoTurns 测试
  // ============================================================
  group('ContextCompressor.groupIntoTurns', () {
    test('空列表返回空', () {
      final turns = ContextCompressor.groupIntoTurns([]);
      expect(turns, isEmpty);
    });

    test('单条 Human 消息为一个轮次', () {
      final messages = [ChatMessage.humanText('hello')];
      final turns = ContextCompressor.groupIntoTurns(messages);
      expect(turns.length, 1);
      expect(turns[0].messages.length, 1);
      expect(turns[0].startIndex, 0);
      expect(turns[0].endIndex, 0);
    });

    test('Human + AI 为一个轮次', () {
      final messages = [
        ChatMessage.humanText('hello'),
        AIChatMessage(content: 'hi there'),
      ];
      final turns = ContextCompressor.groupIntoTurns(messages);
      expect(turns.length, 1);
      expect(turns[0].messages.length, 2);
      expect(turns[0].startIndex, 0);
      expect(turns[0].endIndex, 1);
    });

    test('多个轮次分组正确', () {
      final messages = [
        ChatMessage.humanText('q1'),
        AIChatMessage(content: 'a1'),
        ChatMessage.humanText('q2'),
        AIChatMessage(content: 'a2'),
        ChatMessage.humanText('q3'),
        AIChatMessage(content: 'a3'),
      ];
      final turns = ContextCompressor.groupIntoTurns(messages);
      expect(turns.length, 3);

      expect(turns[0].startIndex, 0);
      expect(turns[0].endIndex, 1);
      expect(turns[0].messages.length, 2);

      expect(turns[1].startIndex, 2);
      expect(turns[1].endIndex, 3);

      expect(turns[2].startIndex, 4);
      expect(turns[2].endIndex, 5);
    });

    test('AI + Tool 消息保持在同一轮次', () {
      final messages = [
        ChatMessage.humanText('search for files'),
        AIChatMessage(
          content: '',
          toolCalls: [
            _tc('call_1', 'file_search', {'pattern': '*.dart'}),
          ],
        ),
        ToolChatMessage(toolCallId: 'call_1', content: 'found 3 files'),
        AIChatMessage(content: 'I found 3 dart files.'),
      ];
      final turns = ContextCompressor.groupIntoTurns(messages);
      expect(turns.length, 1);
      expect(turns[0].messages.length, 4);
      expect(turns[0].startIndex, 0);
      expect(turns[0].endIndex, 3);
    });

    test('多轮次含工具调用', () {
      final messages = [
        // Turn 1: user asks, AI calls tool, tool responds, AI replies
        ChatMessage.humanText('read file'),
        AIChatMessage(
          content: '',
          toolCalls: [
            _tc('call_1', 'file_read', {'path': '/tmp/a.txt'}),
          ],
        ),
        ToolChatMessage(toolCallId: 'call_1', content: 'file content'),
        AIChatMessage(content: 'The file contains...'),
        // Turn 2: user asks another question
        ChatMessage.humanText('what about b.txt?'),
        AIChatMessage(content: 'Let me check.'),
      ];
      final turns = ContextCompressor.groupIntoTurns(messages);
      expect(turns.length, 2);
      expect(turns[0].messages.length, 4); // human + AI(tool) + tool + AI
      expect(turns[1].messages.length, 2); // human + AI
    });

    test('开头为非 Human 消息时归入第一个轮次', () {
      final messages = [
        AIChatMessage(content: 'I started first'),
        ChatMessage.humanText('hello'),
        AIChatMessage(content: 'hi'),
      ];
      final turns = ContextCompressor.groupIntoTurns(messages);
      expect(turns.length, 2);
      // 第一个轮次包含开头的 AI 消息
      expect(turns[0].messages.length, 1);
      expect(turns[0].messages[0], isA<AIChatMessage>());
      // 第二个轮次
      expect(turns[1].messages.length, 2);
    });

    test('MessageTurn.length 属性', () {
      final messages = [
        ChatMessage.humanText('hello'),
        AIChatMessage(content: 'world'),
      ];
      final turns = ContextCompressor.groupIntoTurns(messages);
      expect(turns[0].length, 2);
    });
  });

  // ============================================================
  // Phase 1: 工具结果截断测试
  // ============================================================
  group('Phase 1: 工具结果截断', () {
    late ContextCompressor compressor;

    setUp(() {
      compressor = ContextCompressor(
        config: const ContextCompressionConfig(
          maxContextTokens: 100000, // 设得很大，不触发 Phase 2
          reservedOutputTokens: 1000,
          recentTurnsKeep: 1,
          toolResultMaxChars: 50, // 截断阈值 50 字符
        ),
        onSummarize: (prompt) async => 'summary',
      );
    });

    test('短工具结果不被截断', () {
      final messages = [
        // 旧轮次
        ChatMessage.humanText('q1'),
        AIChatMessage(content: '', toolCalls: [_tc('call_1', 'echo', {})]),
        ToolChatMessage(toolCallId: 'call_1', content: 'short result'),
        AIChatMessage(content: 'done'),
        // 最近轮次
        ChatMessage.humanText('q2'),
        AIChatMessage(content: 'a2'),
      ];

      final compressed = compressor.buildCompressedMessages(
        sessionUuid: 'test-session',
        allMessages: messages,
      );

      // 找到 ToolChatMessage
      final toolMsg = compressed.whereType<ToolChatMessage>().first;
      expect(toolMsg.contentAsString, 'short result'); // 未截断
    });

    test('旧轮次长工具结果被截断到 N 字符', () {
      final longContent = 'x' * 200; // 远超 50 字符阈值
      final messages = [
        // 旧轮次
        ChatMessage.humanText('q1'),
        AIChatMessage(content: '', toolCalls: [_tc('call_1', 'echo', {})]),
        ToolChatMessage(toolCallId: 'call_1', content: longContent),
        AIChatMessage(content: 'done'),
        // 最近轮次
        ChatMessage.humanText('q2'),
        AIChatMessage(content: 'a2'),
      ];

      final compressed = compressor.buildCompressedMessages(
        sessionUuid: 'test-session-trunc',
        allMessages: messages,
      );

      // 旧轮次的 ToolChatMessage 应被截断
      final toolMsgs = compressed.whereType<ToolChatMessage>().toList();
      expect(toolMsgs.isNotEmpty, true);
      final toolContent = toolMsgs.first.contentAsString;
      expect(toolContent.length, lessThan(longContent.length));
      expect(toolContent, contains('truncated'));
      expect(toolContent, contains('200 chars total'));
    });

    test('最近轮次的工具结果不被截断', () {
      final longContent = 'y' * 200;
      final messages = [
        // 唯一的轮次也是最近轮次
        ChatMessage.humanText('q1'),
        AIChatMessage(content: '', toolCalls: [_tc('call_1', 'echo', {})]),
        ToolChatMessage(toolCallId: 'call_1', content: longContent),
        AIChatMessage(content: 'done'),
      ];

      final compressed = compressor.buildCompressedMessages(
        sessionUuid: 'test-session-recent',
        allMessages: messages,
      );

      // recentTurnsKeep=1，这是唯一轮次所以是最近轮次，不截断
      final toolMsg = compressed.whereType<ToolChatMessage>().first;
      expect(toolMsg.contentAsString, longContent); // 完整保留
    });

    test('截断保留 toolCallId 不变', () {
      final longContent = 'z' * 200;
      final messages = [
        // 旧轮次
        ChatMessage.humanText('q1'),
        AIChatMessage(content: '', toolCalls: [_tc('call_abc', 'echo', {})]),
        ToolChatMessage(toolCallId: 'call_abc', content: longContent),
        AIChatMessage(content: 'done'),
        // 最近轮次
        ChatMessage.humanText('q2'),
        AIChatMessage(content: 'a2'),
      ];

      final compressed = compressor.buildCompressedMessages(
        sessionUuid: 'test-session-id',
        allMessages: messages,
      );

      final toolMsg = compressed.whereType<ToolChatMessage>().first;
      expect(toolMsg.toolCallId, 'call_abc'); // ID 不变
    });

    test('非 ToolChatMessage 不受截断影响', () {
      final messages = [
        // 旧轮次
        ChatMessage.humanText('a long question ' * 20),
        AIChatMessage(content: 'a long answer ' * 20),
        // 最近轮次
        ChatMessage.humanText('q2'),
        AIChatMessage(content: 'a2'),
      ];

      final compressed = compressor.buildCompressedMessages(
        sessionUuid: 'test-session-nontool',
        allMessages: messages,
      );

      // Human 和 AI 消息应保持原样
      final humanMsgs = compressed.whereType<HumanChatMessage>().toList();
      expect(humanMsgs.length, 2);
      // 旧轮次的 human 消息应保留全文
      expect(humanMsgs[0].contentAsString, 'a long question ' * 20);
    });
  });

  // ============================================================
  // Phase 2: LLM 摘要测试
  // ============================================================
  group('Phase 2: LLM 摘要', () {
    test('token 在预算内时不触发摘要', () async {
      var summarizeCalled = false;

      final compressor = ContextCompressor(
        config: const ContextCompressionConfig(
          maxContextTokens: 100000, // 非常大的预算
          reservedOutputTokens: 1000,
          recentTurnsKeep: 1,
          toolResultMaxChars: 200,
        ),
        onSummarize: (prompt) async {
          summarizeCalled = true;
          return 'summary';
        },
      );

      final session = SessionHistory(
        sessionUuid: 'test-no-summary',
        employeeUuid: 'test-emp',
      );

      final messages = [
        ChatMessage.humanText('q1'),
        AIChatMessage(content: 'a1'),
        ChatMessage.humanText('q2'),
        AIChatMessage(content: 'a2'),
      ];

      await compressor.prepareCompression(
        sessionUuid: 'test-no-summary',
        allMessages: messages,
        session: session,
      );

      expect(summarizeCalled, false);
    });

    test('token 超预算时触发 onSummarize', () async {
      var summarizeCalled = false;
      String? capturedPrompt;

      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 100, // 预算
          reservedOutputTokens: 10, // 实际预算=90
          recentTurnsKeep: 1,
          toolResultMaxChars: 50,
          summaryMaxTokens: 20,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async {
          summarizeCalled = true;
          capturedPrompt = prompt;
          return 'This is a conversation summary.';
        },
      );

      final session = SessionHistory(
        sessionUuid: 'test-summary',
        employeeUuid: 'test-emp',
      );

      // 构造消息：旧轮次很大，最近轮次很小
      final messages = [
        ChatMessage.humanText('A' * 50), // 旧轮次 1
        AIChatMessage(content: 'B' * 50),
        ChatMessage.humanText('C' * 50), // 旧轮次 2
        AIChatMessage(content: 'D' * 50),
        ChatMessage.humanText('recent'), // 最近轮次（小）
        AIChatMessage(content: 'reply'),
      ];

      await compressor.prepareCompression(
        sessionUuid: 'test-summary',
        allMessages: messages,
        session: session,
      );

      expect(summarizeCalled, true);
      expect(capturedPrompt, isNotNull);
      expect(capturedPrompt, contains('Summary:'));
    });

    test('摘要结果缓存到 session', () async {
      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 50,
          reservedOutputTokens: 10,
          recentTurnsKeep: 1,
          toolResultMaxChars: 50,
          summaryMaxTokens: 20,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async => 'cached summary text',
      );

      final session = SessionHistory(
        sessionUuid: 'test-cache',
        employeeUuid: 'test-emp',
      );

      final messages = [
        ChatMessage.humanText('A' * 30),
        AIChatMessage(content: 'B' * 30),
        ChatMessage.humanText('C' * 30),
        AIChatMessage(content: 'D' * 30),
        ChatMessage.humanText('recent'),
        AIChatMessage(content: 'reply'),
      ];

      await compressor.prepareCompression(
        sessionUuid: 'test-cache',
        allMessages: messages,
        session: session,
      );

      // 摘要应被缓存到 session
      expect(session.conversationSummary, isNotNull);
      expect(session.conversationSummary, contains('cached summary text'));
      expect(session.summarizedUpToIndex, greaterThan(0));
    });

    test('摘要缓存复用，不重复调用 onSummarize', () async {
      var summarizeCallCount = 0;

      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 50,
          reservedOutputTokens: 10,
          recentTurnsKeep: 1,
          toolResultMaxChars: 50,
          summaryMaxTokens: 20,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async {
          summarizeCallCount++;
          return 'summary #$summarizeCallCount';
        },
      );

      final session = SessionHistory(
        sessionUuid: 'test-reuse',
        employeeUuid: 'test-emp',
      );

      final messages = [
        ChatMessage.humanText('A' * 30),
        AIChatMessage(content: 'B' * 30),
        ChatMessage.humanText('C' * 30),
        AIChatMessage(content: 'D' * 30),
        ChatMessage.humanText('recent'),
        AIChatMessage(content: 'reply'),
      ];

      // 第一次调用
      await compressor.prepareCompression(
        sessionUuid: 'test-reuse',
        allMessages: messages,
        session: session,
      );
      expect(summarizeCallCount, 1);

      // 第二次调用相同消息，应复用缓存
      await compressor.prepareCompression(
        sessionUuid: 'test-reuse',
        allMessages: messages,
        session: session,
      );
      // 不应该额外调用，因为缓存的摘要覆盖范围足够
      expect(summarizeCallCount, 1);
    });

    test('onSummarize 异常时降级处理（不抛出）', () async {
      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 50,
          reservedOutputTokens: 10,
          recentTurnsKeep: 1,
          toolResultMaxChars: 50,
          summaryMaxTokens: 20,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async => throw Exception('LLM error'),
      );

      final session = SessionHistory(
        sessionUuid: 'test-error',
        employeeUuid: 'test-emp',
      );

      final messages = [
        ChatMessage.humanText('A' * 30),
        AIChatMessage(content: 'B' * 30),
        ChatMessage.humanText('C' * 30),
        AIChatMessage(content: 'D' * 30),
        ChatMessage.humanText('recent'),
        AIChatMessage(content: 'reply'),
      ];

      // 不应该抛出异常
      await compressor.prepareCompression(
        sessionUuid: 'test-error',
        allMessages: messages,
        session: session,
      );

      // session 摘要应保持 null（降级处理）
      expect(session.conversationSummary, isNull);
    });
  });

  // ============================================================
  // buildCompressedMessages 测试
  // ============================================================
  group('buildCompressedMessages', () {
    test('未启用压缩时返回全量消息', () {
      final compressor = ContextCompressor(
        config: const ContextCompressionConfig(maxContextTokens: 0),
        onSummarize: (prompt) async => 'summary',
      );

      final messages = [
        ChatMessage.humanText('hello'),
        AIChatMessage(content: 'world'),
      ];

      final result = compressor.buildCompressedMessages(
        sessionUuid: 'test',
        allMessages: messages,
        systemPrompt: 'You are helpful.',
      );

      expect(result.length, 3); // system + human + ai
      expect(result[0], isA<SystemChatMessage>());
      expect(
        (result[0] as SystemChatMessage).contentAsString,
        'You are helpful.',
      );
    });

    test('system prompt 注入在最前', () {
      final compressor = ContextCompressor(
        config: const ContextCompressionConfig(
          maxContextTokens: 100000,
          recentTurnsKeep: 1,
        ),
        onSummarize: (prompt) async => 'summary',
      );

      final messages = [
        ChatMessage.humanText('hi'),
        AIChatMessage(content: 'hello'),
      ];

      final result = compressor.buildCompressedMessages(
        sessionUuid: 'test-sys',
        allMessages: messages,
        systemPrompt: 'System prompt here',
      );

      expect(result.first, isA<SystemChatMessage>());
      expect(
        (result.first as SystemChatMessage).contentAsString,
        'System prompt here',
      );
    });

    test('无 system prompt 不注入系统消息', () {
      final compressor = ContextCompressor(
        config: const ContextCompressionConfig(
          maxContextTokens: 100000,
          recentTurnsKeep: 1,
        ),
        onSummarize: (prompt) async => 'summary',
      );

      final messages = [
        ChatMessage.humanText('hi'),
        AIChatMessage(content: 'hello'),
      ];

      final result = compressor.buildCompressedMessages(
        sessionUuid: 'test-no-sys',
        allMessages: messages,
      );

      // 不应有 SystemChatMessage
      expect(result.whereType<SystemChatMessage>().length, 0);
    });

    test('空消息列表返回仅 system prompt', () {
      final compressor = ContextCompressor(
        config: const ContextCompressionConfig(maxContextTokens: 100000),
        onSummarize: (prompt) async => 'summary',
      );

      final result = compressor.buildCompressedMessages(
        sessionUuid: 'test-empty',
        allMessages: [],
        systemPrompt: 'Hello',
      );

      expect(result.length, 1);
      expect(result[0], isA<SystemChatMessage>());
    });

    test('摘要注入为 [Prior Conversation Summary] 系统消息', () async {
      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 50,
          reservedOutputTokens: 10,
          recentTurnsKeep: 1,
          toolResultMaxChars: 50,
          summaryMaxTokens: 20,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async => 'The user asked about files.',
      );

      final session = SessionHistory(
        sessionUuid: 'test-inject',
        employeeUuid: 'test-emp',
      );

      final messages = [
        ChatMessage.humanText('A' * 30),
        AIChatMessage(content: 'B' * 30),
        ChatMessage.humanText('C' * 30),
        AIChatMessage(content: 'D' * 30),
        ChatMessage.humanText('recent question'),
        AIChatMessage(content: 'recent answer'),
      ];

      // 触发摘要生成
      await compressor.prepareCompression(
        sessionUuid: 'test-inject',
        allMessages: messages,
        session: session,
      );

      final result = compressor.buildCompressedMessages(
        sessionUuid: 'test-inject',
        allMessages: messages,
        systemPrompt: 'You are an assistant.',
      );

      // 应该包含摘要系统消息
      final systemMsgs = result.whereType<SystemChatMessage>().toList();
      expect(systemMsgs.length, greaterThanOrEqualTo(2)); // system + summary
      final summaryMsg = systemMsgs.firstWhere(
        (m) => m.contentAsString.contains('Prior Conversation Summary'),
      );
      expect(
        summaryMsg.contentAsString,
        contains('The user asked about files.'),
      );
    });
  });

  // ============================================================
  // 缓存管理测试
  // ============================================================
  group('缓存管理', () {
    test('clearCache 清除指定会话缓存', () async {
      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 50,
          reservedOutputTokens: 10,
          recentTurnsKeep: 1,
          toolResultMaxChars: 50,
          summaryMaxTokens: 20,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async => 'summary',
      );

      final session = SessionHistory(
        sessionUuid: 'sess-a',
        employeeUuid: 'emp',
      );

      final messages = [
        ChatMessage.humanText('A' * 30),
        AIChatMessage(content: 'B' * 30),
        ChatMessage.humanText('recent'),
        AIChatMessage(content: 'reply'),
      ];

      await compressor.prepareCompression(
        sessionUuid: 'sess-a',
        allMessages: messages,
        session: session,
      );

      // 清除缓存
      compressor.clearCache('sess-a');

      // buildCompressedMessages 不应包含摘要
      final result = compressor.buildCompressedMessages(
        sessionUuid: 'sess-a',
        allMessages: messages,
      );

      // 没有摘要系统消息
      final summaryMsgs = result
          .whereType<SystemChatMessage>()
          .where(
            (m) => m.contentAsString.contains('Prior Conversation Summary'),
          )
          .toList();
      expect(summaryMsgs, isEmpty);
    });

    test('dispose 清除所有缓存', () {
      final compressor = ContextCompressor(
        config: const ContextCompressionConfig(maxContextTokens: 100000),
        onSummarize: (prompt) async => 'summary',
      );

      // 不应抛出异常
      compressor.dispose();
    });
  });

  // ============================================================
  // 端到端集成测试
  // ============================================================
  group('端到端集成', () {
    test('多轮工具对话 + 小预算 = 有效压缩', () async {
      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 100,
          reservedOutputTokens: 20,
          recentTurnsKeep: 1,
          toolResultMaxChars: 30,
          summaryMaxTokens: 30,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async =>
            'User asked to read files. AI used file_read tool.',
      );

      final session = SessionHistory(
        sessionUuid: 'e2e-test',
        employeeUuid: 'emp',
      );

      final messages = [
        // Turn 1: 读取文件
        ChatMessage.humanText('Read the config file'),
        AIChatMessage(
          content: '',
          toolCalls: [
            _tc('call_1', 'file_read', {'path': '/etc/config.yaml'}),
          ],
        ),
        ToolChatMessage(
          toolCallId: 'call_1',
          content:
              'database:\n  host: localhost\n  port: 5432\n'
              'redis:\n  host: localhost\n  port: 6379\n'
              'logging:\n  level: debug\n  format: json',
        ),
        AIChatMessage(
          content: 'The config file shows database on localhost:5432.',
        ),
        // Turn 2: 另一个问题
        ChatMessage.humanText('What about the log settings?'),
        AIChatMessage(
          content: 'Logging is set to debug level with JSON format.',
        ),
        // Turn 3: 最近轮次
        ChatMessage.humanText('Change log level to info'),
        AIChatMessage(content: 'Done, I updated the log level.'),
      ];

      // 1. 准备压缩
      await compressor.prepareCompression(
        sessionUuid: 'e2e-test',
        allMessages: messages,
        session: session,
      );

      // 2. 构建压缩消息
      final compressed = compressor.buildCompressedMessages(
        sessionUuid: 'e2e-test',
        allMessages: messages,
        systemPrompt: 'You are a system admin assistant.',
      );

      // 验证: 结果是有效的消息列表
      expect(compressed, isNotEmpty);

      // 验证: 第一条是 system prompt
      expect(compressed.first, isA<SystemChatMessage>());
      expect(
        (compressed.first as SystemChatMessage).contentAsString,
        'You are a system admin assistant.',
      );

      // 验证: 最近轮次完整保留
      final lastHuman = compressed.lastWhere((m) => m is HumanChatMessage);
      expect(lastHuman.contentAsString, 'Change log level to info');

      final lastAi = compressed.last;
      expect(lastAi, isA<AIChatMessage>());
      expect(
        (lastAi as AIChatMessage).contentAsString,
        'Done, I updated the log level.',
      );

      // 验证: 压缩后消息数量少于原始消息数量 + system prompt
      expect(compressed.length, lessThanOrEqualTo(messages.length + 2));
    });

    test('prepareCompression 后 buildCompressedMessages 消息有效', () async {
      // 验证 prepare + build 流程中消息的基本有效性
      final compressor = ContextCompressor(
        config: const ContextCompressionConfig(
          maxContextTokens: 100000,
          recentTurnsKeep: 2,
        ),
        onSummarize: (prompt) async => 'summary',
      );

      final session = SessionHistory(
        sessionUuid: 'valid-test',
        employeeUuid: 'emp',
      );

      final messages = [
        ChatMessage.humanText('q1'),
        AIChatMessage(content: 'a1'),
        ChatMessage.humanText('q2'),
        AIChatMessage(content: 'a2'),
        ChatMessage.humanText('q3'),
        AIChatMessage(content: 'a3'),
      ];

      await compressor.prepareCompression(
        sessionUuid: 'valid-test',
        allMessages: messages,
        session: session,
      );

      final result = compressor.buildCompressedMessages(
        sessionUuid: 'valid-test',
        allMessages: messages,
        systemPrompt: 'system',
      );

      // 至少有 system + 最近 2 轮 (4 条) = 5 条
      expect(result.length, greaterThanOrEqualTo(5));

      // 消息类型交替合理：以 system 开头
      expect(result[0], isA<SystemChatMessage>());

      // 最后两轮的消息应完整保留
      final humanMsgs = result.whereType<HumanChatMessage>().toList();
      expect(humanMsgs.last.contentAsString, 'q3');
    });

    test('不同会话 ID 互不影响', () async {
      final compressor = ContextCompressor(
        config: ContextCompressionConfig(
          maxContextTokens: 50,
          reservedOutputTokens: 10,
          recentTurnsKeep: 1,
          toolResultMaxChars: 50,
          summaryMaxTokens: 20,
          tokenEstimator: CharBasedTokenEstimator(charsPerToken: 1.0),
        ),
        onSummarize: (prompt) async => 'summary for this session',
      );

      final sessionA = SessionHistory(
        sessionUuid: 'session-a',
        employeeUuid: 'emp',
      );
      // sessionB 用于验证 prepareCompression 未被调用时无缓存
      SessionHistory(sessionUuid: 'session-b', employeeUuid: 'emp');

      final messagesA = [
        ChatMessage.humanText('A' * 30),
        AIChatMessage(content: 'B' * 30),
        ChatMessage.humanText('recent-a'),
        AIChatMessage(content: 'reply-a'),
      ];

      final messagesB = [
        ChatMessage.humanText('hello'),
        AIChatMessage(content: 'world'),
      ];

      await compressor.prepareCompression(
        sessionUuid: 'session-a',
        allMessages: messagesA,
        session: sessionA,
      );

      // Session B 不应受 Session A 的缓存影响
      final resultB = compressor.buildCompressedMessages(
        sessionUuid: 'session-b',
        allMessages: messagesB,
      );

      // B 没有摘要
      final summaryMsgs = resultB
          .whereType<SystemChatMessage>()
          .where(
            (m) => m.contentAsString.contains('Prior Conversation Summary'),
          )
          .toList();
      expect(summaryMsgs, isEmpty);
    });
  });
}
