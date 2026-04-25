import '../../shared/shared.dart';
import '../../utils/logger.dart';
import 'context_compression_config.dart';
import 'session_memory_manager.dart';
import 'token_estimator.dart';

/// LLM 摘要回调类型
///
/// 由 [LlmChatAdapter] 注入，用于调用 LLM 生成对话摘要。
typedef SummarizeCallback = Future<String> Function(String prompt);

/// 消息轮次
///
/// 一个"轮次"从 user 消息开始，到下一个 user 消息之前结束。
/// 包含用户消息及其后续的所有 assistant/tool 消息。
class MessageTurn {
  /// 在原始消息列表中的起始索引
  final int startIndex;

  /// 在原始消息列表中的结束索引（包含）
  final int endIndex;

  /// 本轮次包含的消息
  final List<ChatMessage> messages;

  const MessageTurn({
    required this.startIndex,
    required this.endIndex,
    required this.messages,
  });

  /// 消息数量
  int get length => messages.length;
}

/// 压缩缓存
class _CompressionCache {
  /// 缓存的摘要文本
  String? summary;

  /// 摘要覆盖到的原始消息索引
  int summarizedUpToIndex;

  /// 生成缓存时的消息总数（用于检测过期）
  int messagesCountWhenCached;

  _CompressionCache({this.summary, this.summarizedUpToIndex = 0})
    : messagesCountWhenCached = 0;
}

/// 上下文压缩器
///
/// 负责将超出 token 预算的对话历史进行智能压缩。
/// 采用两阶段策略:
/// 1. Phase 1: 截断旧工具结果内容（便宜、同步）
/// 2. Phase 2: 用 LLM 对最早的轮次生成摘要（按需、异步、缓存）
///
/// 使用方法:
/// 1. 每轮用户消息后调用 [prepareCompression]（异步，可能触发 LLM 摘要）
/// 2. Tool calling loop 中每次迭代调用 [buildCompressedMessages]（同步，使用缓存）
class ContextCompressor {
  static final _log = Logger('ContextCompressor');

  final ContextCompressionConfig config;
  final SummarizeCallback onSummarize;

  /// token 估算器
  late final TokenEstimator _estimator = config.estimator;

  /// 每个会话的压缩缓存
  final Map<String, _CompressionCache> _sessionCaches = {};

  ContextCompressor({required this.config, required this.onSummarize});

  /// 准备压缩（每轮用户消息调用一次）
  ///
  /// 分析当前消息历史，决定压缩策略，必要时生成 LLM 摘要。
  /// 结果缓存供后续 [buildCompressedMessages] 使用。
  Future<void> prepareCompression({
    required String employeeId,
    required List<ChatMessage> allMessages,
    required SessionHistory session,
    String? systemPrompt,
  }) async {
    if (!config.enabled || allMessages.isEmpty) return;

    final budget = config.effectiveBudget;
    if (budget <= 0) return;

    // 估算系统提示 token
    final systemTokens = systemPrompt != null
        ? _estimator.estimateTokens(systemPrompt) +
              4 // message overhead
        : 0;

    // 分组为轮次
    final turns = groupIntoTurns(allMessages);
    if (turns.isEmpty) return;

    // 确定最近保留窗口
    final recentCount = config.recentTurnsKeep.clamp(1, turns.length);
    final recentStart = turns.length - recentCount;

    // 获取或创建缓存
    final cache = _sessionCaches.putIfAbsent(
      employeeId,
      () => _CompressionCache(
        summary: session.conversationSummary,
        summarizedUpToIndex: session.summarizedUpToIndex,
      ),
    );

    // 估算最近轮次的 token（始终保留完整）
    final recentMessages = <ChatMessage>[];
    for (var i = recentStart; i < turns.length; i++) {
      recentMessages.addAll(turns[i].messages);
    }
    final recentTokens = _estimator.estimateMessagesTotal(recentMessages);

    // 剩余预算给旧消息和摘要
    var remainingBudget = budget - systemTokens - recentTokens;

    if (remainingBudget <= 0) {
      // 连最近轮次都超了预算，只能全部保留最近轮次（无法再压缩）
      return;
    }

    // 收集旧轮次（最近窗口之前的）
    if (recentStart <= 0) {
      // 没有旧轮次需要压缩
      return;
    }

    // Phase 1: 对旧轮次的工具结果进行截断，估算 token
    final oldTurns = turns.sublist(0, recentStart);
    final truncatedOldMessages = _truncateToolResults(oldTurns);
    final oldTokens = _estimator.estimateMessagesTotal(truncatedOldMessages);

    if (oldTokens <= remainingBudget) {
      // Phase 1 截断后就在预算内了，不需要摘要
      // 清除过期的摘要缓存（如果有的话，旧轮次已经可以全部保留）
      return;
    }

    // Phase 2: 需要摘要压缩
    // 检查已有摘要是否足够新
    final needsResummarize = _needsResummarize(
      cache: cache,
      totalMessages: allMessages.length,
      oldTurnsEndIndex: oldTurns.last.endIndex,
    );

    if (needsResummarize) {
      await _generateSummary(
        cache: cache,
        session: session,
        oldTurns: oldTurns,
        remainingBudget: remainingBudget,
      );
    }
  }

  /// 构建压缩后的消息列表（同步，使用缓存）
  ///
  /// 在 tool calling loop 的每次迭代中调用。
  List<ChatMessage> buildCompressedMessages({
    required String employeeId,
    required List<ChatMessage> allMessages,
    String? systemPrompt,
  }) {
    if (!config.enabled || allMessages.isEmpty) {
      // 未启用压缩，回退到全量
      return _buildFullMessages(allMessages, systemPrompt);
    }

    final budget = config.effectiveBudget;
    if (budget <= 0) {
      return _buildFullMessages(allMessages, systemPrompt);
    }

    final result = <ChatMessage>[];

    // 1. 系统提示
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add(ChatMessage.system(
        id: '',
        employeeId: employeeId,
        content: systemPrompt,
      ));
    }

    // 分组为轮次
    final turns = groupIntoTurns(allMessages);
    if (turns.isEmpty) return result;

    final recentCount = config.recentTurnsKeep.clamp(1, turns.length);
    final recentStart = turns.length - recentCount;

    // 2. 获取缓存
    final cache = _sessionCaches[employeeId];

    // 3. 注入摘要（如果有）
    if (cache?.summary != null && cache!.summary!.isNotEmpty) {
      result.add(
        ChatMessage.system(
          id: '',
          employeeId: employeeId,
          content: '[Prior Conversation Summary]\n${cache.summary}',
        ),
      );
    }

    // 4. 处理旧轮次（摘要覆盖之后、最近窗口之前）
    if (recentStart > 0) {
      final summarizedEndIndex = cache?.summarizedUpToIndex ?? 0;

      // 收集摘要未覆盖的旧轮次
      for (var i = 0; i < recentStart; i++) {
        final turn = turns[i];
        if (turn.endIndex < summarizedEndIndex) {
          // 这个轮次已被摘要覆盖，跳过
          continue;
        }
        // 对工具消息进行截断后加入
        for (final msg in turn.messages) {
          result.add(_maybeTrancateToolMessage(msg));
        }
      }
    }

    // 5. 最近轮次完整保留
    for (var i = recentStart; i < turns.length; i++) {
      result.addAll(turns[i].messages);
    }

    // 6. 合并连续的 tool result 消息（与非压缩路径 buildMessages 保持一致）
    //
    // 非压缩路径 SessionMemoryManager.buildMessages 会调用 mergeConsecutiveToolResults，
    // 压缩路径也必须调用，否则连续的单条 tool result 不会被合并为分组消息，
    // 导致 Anthropic 等严格提供商收到多个独立的 tool_result 消息，
    // 可能触发 "unexpected tool_use_id" 错误。
    final merged = LlmMessageMapper.mergeConsecutiveToolResults(result);

    // 7. 修复压缩边界处的 tool_call/tool_result 配对问题
    //
    // 当摘要覆盖了旧轮次的部分消息时，可能导致 tool_call 和 tool_result
    // 被拆分到摘要内外的不同区域，破坏 Anthropic 等严格提供商的消息序列要求。
    // 例如：assistant(toolCalls) 被保留但对应的 tool_result 被摘要覆盖，
    // 或者 tool_result 被保留但其对应的 assistant(toolCalls) 被摘要覆盖。
    _ensureToolCallResultPairs(merged);

    return merged;
  }

  /// 确保 tool_call / tool_result 严格配对
  ///
  /// 压缩边界可能将 assistant(toolCalls) 和对应的 tool_result 拆到不同区域，
  /// 导致 Anthropic 等 API 报 "unexpected tool_use_id" 错误。
  ///
  /// 策略：单次前向遍历，收集需要删除/strip 的索引，最后统一处理。
  static void _ensureToolCallResultPairs(List<ChatMessage> result) {
    if (result.length < 2) return;

    // 需要删除的消息索引
    final toRemove = <int>{};
    // 需要移除 toolCalls 的 assistant 消息索引
    final toStrip = <int>{};

    // 前一条 assistant(toolCalls) 的 tool_call_id 集合
    Set<String>? prevToolCallIds;
    int? prevAssistantIdx;

    for (var i = 0; i < result.length; i++) {
      final msg = result[i];

      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        // ── 遇到新的 assistant(toolCalls) ──
        // 先处理前一条未配对的 assistant
        if (prevToolCallIds != null &&
            prevToolCallIds.isNotEmpty &&
            prevAssistantIdx != null &&
            !toStrip.contains(prevAssistantIdx)) {
          _log.warn(
            '_ensureToolCallResultPairs: assistant at [$prevAssistantIdx] 无匹配 tool_result, '
            'strip toolCalls (ids=$prevToolCallIds)',
          );
          toStrip.add(prevAssistantIdx);
        }
        prevToolCallIds = msg.toolCalls!.map((tc) => tc.id).toSet();
        prevAssistantIdx = i;
      } else if (msg.role == MessageRole.tool) {
        // ── 遇到 tool_result ──
        if (prevToolCallIds == null || prevToolCallIds.isEmpty) {
          // 前面没有未配对的 assistant(toolCalls) → 孤立 tool_result
          _log.warn(
            '_ensureToolCallResultPairs: 丢弃孤立 tool_result at [$i] '
            '(前面无未配对的 assistant)',
          );
          toRemove.add(i);
        } else {
          // 此分支已通过上面的 null/isEmpty 检查，prevToolCallIds 必定非空
          final ids = prevToolCallIds;
          // 检查 tool_result 的 toolCallId 是否匹配
          final matchIds = msg.isToolResultGroup
              ? msg.toolResults!
                    .where((r) => ids.contains(r.toolCallId))
                    .map((r) => r.toolCallId)
                    .toSet()
              : (ids.contains(msg.toolCallId ?? '')
                  ? {msg.toolCallId ?? ''}
                  : <String>{});

          if (matchIds.isEmpty) {
            _log.warn(
              '_ensureToolCallResultPairs: 丢弃不匹配 tool_result at [$i] '
              '(expected=$prevToolCallIds)',
            );
            toRemove.add(i);
          } else {
            for (final id in matchIds) {
              prevToolCallIds.remove(id);
            }
          }
        }
      } else {
        // ── 遇到 user/system 等非 tool 消息 ──
        // 如果前面有未配对的 assistant(toolCalls)，strip 之
        if (prevToolCallIds != null &&
            prevToolCallIds.isNotEmpty &&
            prevAssistantIdx != null &&
            !toStrip.contains(prevAssistantIdx)) {
          _log.warn(
            '_ensureToolCallResultPairs: ${msg.role.name} at [$i] 打断了 tool_call 配对, '
            'strip assistant at [$prevAssistantIdx] (ids=$prevToolCallIds)',
          );
          toStrip.add(prevAssistantIdx);
        }
        prevToolCallIds = null;
        prevAssistantIdx = null;
      }
    }

    // 序列末尾：strip 未配对的 assistant(toolCalls)
    if (prevToolCallIds != null &&
        prevToolCallIds.isNotEmpty &&
        prevAssistantIdx != null &&
        !toStrip.contains(prevAssistantIdx)) {
      _log.warn(
        '_ensureToolCallResultPairs: 序列末尾 assistant at [$prevAssistantIdx] 无匹配 tool_result, '
        'strip toolCalls (ids=$prevToolCallIds)',
      );
      toStrip.add(prevAssistantIdx);
    }

    // 统一处理：先 strip，再删除（倒序）
    for (final idx in toStrip) {
      _stripAssistantToolCallsInList(result, idx);
    }
    if (toRemove.isNotEmpty) {
      final sorted = toRemove.toList()..sort((a, b) => b.compareTo(a));
      for (final idx in sorted) {
        if (idx >= 0 && idx < result.length) {
          result.removeAt(idx);
        }
      }
    }
  }

  /// 在消息列表中 strip 指定索引处 assistant 消息的 toolCalls，
  /// 转为内联文本描述，确保 LLM 能感知历史工具调用。
  static void _stripAssistantToolCallsInList(
    List<ChatMessage> result,
    int index,
  ) {
    if (index < 0 || index >= result.length) return;
    final msg = result[index];
    if (msg.role != MessageRole.assistant ||
        msg.toolCalls == null ||
        msg.toolCalls!.isEmpty) {
      return;
    }
    final content = msg.content;
    final toolSummary = msg.toolCalls!
        .map((tc) {
          final args = tc.arguments;
          String argsPreview;
          if (args.length <= 3) {
            argsPreview = args.entries
                .map((e) => '${e.key}=${e.value}')
                .join(', ');
          } else {
            argsPreview = args.entries.take(3)
                .map((e) => '${e.key}=${e.value}')
                .join(', ');
            argsPreview += ', ...(共${args.length}个参数)';
          }
          return '${tc.name}($argsPreview)';
        })
        .join('; ');
    final inlineNote =
        '[已调用工具: $toolSummary，但结果因上下文压缩被移除，请勿重复调用]';

    final newContent = (content == null || content.trim().isEmpty)
        ? inlineNote
        : '$content\n$inlineNote';

    result[index] = msg.copyWith(
      clearToolCalls: true,
      type: 'text',
      content: newContent,
    );
  }

  /// 清除指定会话的压缩缓存
  void clearCache(String employeeId) {
    _sessionCaches.remove(employeeId);
  }

  /// 清除所有缓存
  void dispose() {
    _sessionCaches.clear();
  }

  // ===== 消息轮次分组 =====

  /// 将消息列表分组为对话轮次
  ///
  /// 每遇到 user 消息开始一个新轮次。
  /// 轮次包含该 user 消息及后续所有 assistant/tool 消息直到下一个 user。
  /// assistant(toolCalls) + 对应 tool 消息永远在同一轮次内。
  ///
  /// 对于开头的非 user 消息（如果有），归入第一个虚拟轮次。
  static List<MessageTurn> groupIntoTurns(List<ChatMessage> messages) {
    if (messages.isEmpty) return [];

    final turns = <MessageTurn>[];
    var currentStart = 0;
    var currentMessages = <ChatMessage>[];

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];

      if (msg.role == MessageRole.user && currentMessages.isNotEmpty) {
        // 遇到新的 user 消息，结束当前轮次
        turns.add(
          MessageTurn(
            startIndex: currentStart,
            endIndex: i - 1,
            messages: List.unmodifiable(currentMessages),
          ),
        );
        currentStart = i;
        currentMessages = [];
      }

      currentMessages.add(msg);
    }

    // 最后一个轮次
    if (currentMessages.isNotEmpty) {
      turns.add(
        MessageTurn(
          startIndex: currentStart,
          endIndex: messages.length - 1,
          messages: List.unmodifiable(currentMessages),
        ),
      );
    }

    return turns;
  }

  // ===== 工具结果截断 =====

  /// 对旧轮次中的 tool 消息内容进行截断
  List<ChatMessage> _truncateToolResults(List<MessageTurn> turns) {
    final result = <ChatMessage>[];
    for (final turn in turns) {
      for (final msg in turn.messages) {
        result.add(_maybeTrancateToolMessage(msg));
      }
    }
    return result;
  }

  /// 如果是 tool 消息且内容过长，截断之
  ChatMessage _maybeTrancateToolMessage(ChatMessage message) {
    if (message.role != MessageRole.tool) return message;

    final maxChars = config.toolResultMaxChars;

    if (message.isToolResultGroup) {
      // 分组格式：对每个 result 的 content 分别截断
      var anyTruncated = false;
      final truncatedResults = message.toolResults!.map((r) {
        if (r.content.length > maxChars) {
          anyTruncated = true;
          return ToolResult(
            toolCallId: r.toolCallId,
            content: '${r.content.substring(0, maxChars)}'
                '\n...[truncated, ${r.content.length} chars total]',
            isError: r.isError,
            name: r.name,
          );
        }
        return r;
      }).toList();
      if (!anyTruncated) return message;
      return message.copyWith(
        content: truncatedResults.map((r) => r.content).join('\n'),
        toolResults: truncatedResults,
      );
    }

    // 单条格式
    final content = message.content ?? '';
    if (content.length <= maxChars) return message;

    final truncated =
        '${content.substring(0, maxChars)}'
        '\n...[truncated, ${content.length} chars total]';

    return message.copyWith(content: truncated);
  }

  // ===== 摘要生成 =====

  /// 判断是否需要重新生成摘要
  bool _needsResummarize({
    required _CompressionCache cache,
    required int totalMessages,
    required int oldTurnsEndIndex,
  }) {
    // 没有摘要 → 需要生成
    if (cache.summary == null || cache.summary!.isEmpty) return true;

    // 摘要覆盖的范围相对于旧消息范围太少（新消息翻倍以上）
    final uncoveredOld = oldTurnsEndIndex - cache.summarizedUpToIndex;
    if (uncoveredOld > cache.summarizedUpToIndex && uncoveredOld > 10) {
      return true;
    }

    return false;
  }

  /// 使用 LLM 生成对话摘要
  Future<void> _generateSummary({
    required _CompressionCache cache,
    required SessionHistory session,
    required List<MessageTurn> oldTurns,
    required int remainingBudget,
  }) async {
    // 确定需要摘要的轮次范围：从开头到能让剩余轮次在预算内的位置
    // 贪心策略：从最旧的轮次开始摘要，直到剩余能放下
    var turnsToSummarize = 0;
    var turnsToKeepTokens = 0;

    // 先算出所有旧轮次截断后的 token
    final truncatedPerTurn = <int>[];
    for (final turn in oldTurns) {
      final truncated = <ChatMessage>[];
      for (final msg in turn.messages) {
        truncated.add(_maybeTrancateToolMessage(msg));
      }
      truncatedPerTurn.add(_estimator.estimateMessagesTotal(truncated));
    }

    // 预留摘要 token
    final summaryBudget =
        _estimator.estimateTokens('A' * (config.summaryMaxTokens * 3)) + 10;
    final keepBudget = remainingBudget - summaryBudget;

    // 从最后一个旧轮次往前，尽量多保留
    turnsToKeepTokens = 0;
    for (var i = oldTurns.length - 1; i >= 0; i--) {
      final newTotal = turnsToKeepTokens + truncatedPerTurn[i];
      if (newTotal > keepBudget) {
        turnsToSummarize = i + 1;
        break;
      }
      turnsToKeepTokens = newTotal;
    }

    // 至少摘要 1 个轮次
    if (turnsToSummarize == 0) turnsToSummarize = 1;

    // 构建摘要 prompt
    final messagesToSummarize = <ChatMessage>[];
    for (var i = 0; i < turnsToSummarize; i++) {
      messagesToSummarize.addAll(oldTurns[i].messages);
    }

    final formattedMessages = _formatMessagesForSummary(messagesToSummarize);
    final prompt =
        'Please provide a concise summary of the following conversation '
        'between a user and an AI assistant.\n'
        'Preserve: key facts, user requests, important decisions, tool call results and outcomes.\n'
        'Omit: verbatim tool outputs, redundant details.\n'
        'Keep the summary concise (under ${config.summaryMaxTokens} tokens).\n\n'
        'Conversation:\n---\n$formattedMessages\n---\n\nSummary:';

    try {
      final summary = await onSummarize(prompt);
      final summarizedEndIndex = oldTurns[turnsToSummarize - 1].endIndex + 1;

      cache.summary = summary;
      cache.summarizedUpToIndex = summarizedEndIndex;
      cache.messagesCountWhenCached = messagesToSummarize.length;

      // 同步到 SessionHistory
      session.conversationSummary = summary;
      session.summarizedUpToIndex = summarizedEndIndex;
    } catch (e) {
      // 摘要生成失败，回退到仅截断模式（不报错，降级处理）
      _log.warn('summary generation failed, falling back to truncation-only mode: $e');
    }
  }

  /// 将消息格式化为适合摘要的文本
  String _formatMessagesForSummary(List<ChatMessage> messages) {
    final buffer = StringBuffer();

    for (final msg in messages) {
      final role = switch (msg.role) {
        MessageRole.user => 'User',
        MessageRole.assistant => 'Assistant',
        MessageRole.tool => 'Tool Result',
        MessageRole.system => 'System',
      };

      var content = msg.content ?? '';

      // 截断过长的内容（摘要 prompt 本身也不能太长）
      if (content.length > 500) {
        content = '${content.substring(0, 500)}...[truncated]';
      }

      // 对 assistant 消息附加工具调用信息
      if (msg.role == MessageRole.assistant && msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
        final toolNames = msg.toolCalls!.map((tc) => tc.name).join(', ');
        buffer.writeln('$role: $content');
        buffer.writeln('  [Called tools: $toolNames]');
      } else if (msg.role == MessageRole.tool) {
        if (msg.isToolResultGroup) {
          final parts = msg.toolResults!.map((r) {
            var c = r.content;
            if (c.length > 500) c = '${c.substring(0, 500)}...[truncated]';
            final err = r.isError ? ' [ERROR]' : '';
            return '  [${r.name ?? r.toolCallId}]$err: $c';
          }).join('\n');
          buffer.writeln('Tool Results:\n$parts');
        } else {
          buffer.writeln('$role (${msg.toolCallId}): $content');
        }
      } else {
        buffer.writeln('$role: $content');
      }
    }

    return buffer.toString();
  }

  // ===== 辅助方法 =====

  /// 不压缩的全量消息构建
  List<ChatMessage> _buildFullMessages(
    List<ChatMessage> allMessages,
    String? systemPrompt,
  ) {
    final result = <ChatMessage>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add(ChatMessage.system(
        id: '',
        employeeId: '',
        content: systemPrompt,
      ));
    }
    result.addAll(allMessages);
    return result;
  }
}
