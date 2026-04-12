import 'dart:async';
import 'dart:convert';

import 'package:llm_dart/llm_dart.dart' as llm;
import 'package:meta/meta.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import '../tool/agent_tool.dart';
import '../tool/cancellable_tool_executor.dart';
import '../tool/permission_manager.dart';
import '../tool/tool_registry.dart';
import 'chat_msg.dart';
import 'context_compressor.dart';
import 'session_memory_manager.dart';

/// Tool calling 循环最大迭代次数
const int _maxToolCallIterations = 100;

/// 并行工具执行结果（内部使用）
class _ToolExecResult {
  final llm.ToolCall toolCall;
  final String toolName;
  final ToolResult result;
  final int durationMs;
  final bool wasCancelled;

  const _ToolExecResult({
    required this.toolCall,
    required this.toolName,
    required this.result,
    required this.durationMs,
    this.wasCancelled = false,
  });
}

/// 基于 llm_dart 的聊天适配器实现
///
/// 使用 llm_dart 库实现 IChatAdapter 接口，
/// 支持 OpenAI、Anthropic、Google AI、Ollama 等多种 LLM 提供商。
class LlmChatAdapter implements IChatAdapter {
  /// llm_dart ChatCapability 实例
  llm.ChatCapability? _chatCapability;

  /// 提供商配置
  ProviderConfig? _providerConfig;

  /// 会话记忆管理器（protected，供子类访问）
  @protected
  final SessionMemoryManager memoryManager = SessionMemoryManager();

  /// 当前员工 UUID（同时作为会话 ID）
  @protected
  String? currentEmployeeUuid;

  /// 当前设备 ID（用于区分不同设备的消息记录）
  @protected
  String? deviceId;

  /// 当前上下文
  Map<String, dynamic>? _context;

  /// 是否正在流式输出
  bool _isStreaming = false;

  /// 工具注册器
  ToolRegistry? _toolRegistry;

  /// 权限管理器
  ToolPermissionManager? _permissionManager;

  /// 工具事件回调
  void Function(ToolEvent event)? _toolEventCallback;

  /// 当前正在并行执行的工具列表（用于取消）
  final List<AgentTool> _runningTools = [];

  /// 上下文压缩器
  ContextCompressor? _compressor;

  /// dio CancelToken（用于取消 LLM 流式请求）
  llm.CancelToken? _dioCancelToken;

  LlmChatAdapter();

  // ===== IChatAdapter 属性实现 =====

  String? get currentSessionUuid => currentEmployeeUuid;

  @override
  List<Map<String, dynamic>> get currentMessages {
    if (currentEmployeeUuid == null) return [];

    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return [];

    return session.allMessages.map(_messageWrapperToMap).toList();
  }

  @override
  Map<String, dynamic>? get currentContext => _context;

  @override
  bool get isStreaming => _isStreaming;

  // ===== IChatAdapter 方法实现 =====

  @override
  Future<void> initSession({
    required String employeeId,
    int? recentLimit,
  }) async {
    currentEmployeeUuid = employeeId;
    memoryManager.getOrCreateSession(employeeId);
  }

  @override
  Future<void> loadRemainingMessages() async {
    // 基类无持久化，无需加载
  }

  @override
  Stream<StreamResponse> streamMessage(
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  }) async* {
    print('[LlmChatAdapter] streamMessage called');
    print('[LlmChatAdapter] _chatCapability: $_chatCapability');
    print('[LlmChatAdapter] _providerConfig: $_providerConfig');
    print('[LlmChatAdapter] currentEmployeeUuid: $currentEmployeeUuid');

    if (_chatCapability == null) {
      print('[LlmChatAdapter] ERROR: _chatCapability is null');
      yield StreamResponse.error('未配置 LLM Provider，请先调用 updateProvider()');
      return;
    }

    if (_isStreaming) {
      print('[LlmChatAdapter] ERROR: already streaming');
      yield StreamResponse.error('正在处理中，请等待当前请求完成');
      return;
    }

    if (currentEmployeeUuid == null) {
      print('[LlmChatAdapter] ERROR: currentEmployeeUuid is null');
      yield StreamResponse.error('未初始化会话，请先调用 initSession()');
      return;
    }

    _isStreaming = true;
    _dioCancelToken = llm.CancelToken();
    StreamSubscription? cancelSubscription;


    try {
      // 获取用户输入
      final userContent = messageData['content'] as String? ?? '';
      if (userContent.isEmpty) {
        yield StreamResponse.error('消息内容不能为空');
        return;
      }

      // 添加用户消息到历史
      final userMessage = ChatMsg.user(userContent);
      final userMessageId = messageData['id'] as String?;
      if (userMessageId != null) {
        print('[LlmChatAdapter] 使用客户端提供的消息ID: $userMessageId');
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          userMessage,
          messageId: userMessageId,
        );
      } else {
        print('[LlmChatAdapter] 没有提供消息ID，自动生成');
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          userMessage,
        );
      }

      // 检查是否有可用工具
      final hasTools = _toolRegistry != null && !_toolRegistry!.isEmpty;

      // 准备上下文压缩（每轮用户消息调用一次）
      final systemPrompt = _buildSystemPrompt();
      if (_compressor != null) {
        final session = memoryManager.getSession(currentEmployeeUuid!);
        if (session != null) {
          final chatMsgs = session.allMessages
              .map((wrapper) => wrapper.message)
              .toList();
          await _compressor!.prepareCompression(
            employeeId: currentEmployeeUuid!,
            allMessages: chatMsgs,
            session: session,
            systemPrompt: systemPrompt,
          );
        }
      }

      // Tool calling 循环
      bool completedNormally = false;

      // 取消监听（只设置一次，避免每轮循环重建）
      bool streamCancelled = false;
      cancelSubscription = cancellationToken?.onCancel.listen((_) {
        streamCancelled = true;
        _dioCancelToken?.cancel('User cancelled');
      });

      // 重复工具调用检测
      String? lastToolCallsSignature;
      const int maxConsecutiveDuplicateRounds = 3;
      int consecutiveDuplicateCount = 0;

      for (var iteration = 0; iteration < _maxToolCallIterations; iteration++) {
        // 检查取消
        if (cancellationToken?.isCancelled == true) {
          yield StreamResponse.error('Cancelled');
          return;
        }

        // 构建消息列表
        final List<ChatMsg> chatMsgs;
        if (_compressor != null) {
          final session = memoryManager.getSession(currentEmployeeUuid!);
          final allMsgs =
              session?.allMessages.map((wrapper) => wrapper.message).toList() ??
              [];
          chatMsgs = _compressor!.buildCompressedMessages(
            employeeId: currentEmployeeUuid!,
            allMessages: allMsgs,
            systemPrompt: systemPrompt,
          );
        } else {
          chatMsgs = memoryManager.buildMessages(
            employeeId: currentEmployeeUuid!,
            systemPrompt: systemPrompt,
          );
        }

        // 转换为 llm_dart ChatMessage
        final llmMessages = chatMsgs.map((m) => m.toLlmDart()).toList();

        // 构建工具列表
        final List<llm.Tool>? llmTools;
        if (hasTools && _toolRegistry != null && _providerConfig != null) {
          llmTools = _toolRegistry!.getLlmDartTools(_providerConfig!.provider);
        } else {
          llmTools = null;
        }

        if (hasTools) {
          print('[LlmChatAdapter] 已注册工具列表 (${_toolRegistry!.length} 个):');
          for (final toolName in _toolRegistry!.toolNames) {
            print('[LlmChatAdapter]   - $toolName');
          }
        }
        print(
          '[LlmChatAdapter] calling LLM, messages count: ${llmMessages.length}, hasTools: $hasTools',
        );

        // 调用 LLM 流式接口
        final aiContentBuffer = StringBuffer();
        final toolCallAggregator = llm.ToolCallAggregator();
        llm.ChatResponse? finalResponse;

        try {
          final stream = _chatCapability!.chatStream(
            llmMessages,
            tools: llmTools,
            cancelToken: _dioCancelToken,
          );

          await for (final event in stream) {
            if (streamCancelled || cancellationToken?.isCancelled == true) {
              yield StreamResponse.error('Cancelled');
              return;
            }
            print(event.runtimeType);

            switch (event) {
              case llm.TextDeltaEvent():
                final chunk = event.delta;
                if (chunk.isNotEmpty) {
                  aiContentBuffer.write(chunk);
                  yield StreamResponse.chunk(chunk);
                }
                break;
              case llm.ToolCallDeltaEvent():
                toolCallAggregator.addDelta(event.toolCall);
                break;
              case llm.ThinkingDeltaEvent():
                // 忽略 thinking 事件
                break;
              case llm.CompletionEvent():
                finalResponse = event.response;
                break;
              case llm.ErrorEvent():
                print(
                  '[LlmChatAdapter] LLM stream error event: ${event.error}',
                );
                yield StreamResponse.error('LLM 调用异常: ${event.error.message}');
                break;
              default:
                break;
            }
          }
        } catch (e) {
          print('[LlmChatAdapter] LLM stream error: $e');
          yield StreamResponse.error('LLM 调用异常: $e');
          return;
        }

        // 检查取消
        if (cancellationToken?.isCancelled == true) {
          yield StreamResponse.error('Cancelled');
          return;
        }

        // 确定最终响应：优先使用 CompletionEvent 中的数据，回退到聚合数据
        final toolCalls =
            finalResponse?.toolCalls ?? toolCallAggregator.completedCalls;

        if (toolCalls.isEmpty || !hasTools) {
          // 没有工具调用 → 将 AI 文本加入历史，结束循环
          final aiContent = aiContentBuffer.toString();
          if (aiContent.isNotEmpty) {
            memoryManager.addMessage(
              currentEmployeeUuid!,
              deviceId ?? 'default',
              ChatMsg.assistant(aiContent),
            );
          }
          completedNormally = true;
          break;
        }

        // 有工具调用 → 将 AI 消息（含 toolCalls）加入历史
        final toolCallInfos = toolCalls
            .map((tc) => ToolCallInfo.fromLlmDart(tc))
            .toList();
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          ChatMsg.assistant(
            aiContentBuffer.toString(),
            toolCalls: toolCallInfos,
          ),
        );

        // 重复工具调用检测
        final currentSignature = toolCalls
            .map((tc) {
              return '${tc.function.name}:${tc.function.arguments}';
            })
            .join('|');

        if (currentSignature == lastToolCallsSignature) {
          consecutiveDuplicateCount++;
          print(
            '[LlmChatAdapter] 检测到重复工具调用 (第 $consecutiveDuplicateCount 次): '
            '$currentSignature',
          );
          if (consecutiveDuplicateCount >= maxConsecutiveDuplicateRounds) {
            print(
              '[LlmChatAdapter] 连续 $maxConsecutiveDuplicateRounds 轮重复工具调用，'
              '强制终止循环',
            );
            yield StreamResponse.error(
              '检测到工具调用死循环：LLM 连续 '
              '$maxConsecutiveDuplicateRounds 轮发出相同的工具调用。'
              '请尝试修改您的需求或手动提供相关信息。',
            );
            return;
          }
        } else {
          consecutiveDuplicateCount = 0;
        }
        lastToolCallsSignature = currentSignature;

        // ===== 工具执行阶段（权限检查串行 + 执行并行） =====

        // Phase 1: 权限检查 + 收集待执行工具
        final pendingExecutions =
            <
              ({llm.ToolCall call, AgentTool tool, Map<String, dynamic> args})
            >[];
        // 收集早期结果（未找到/被拒绝的工具），后续统一合并写入
        final earlyResults = <ToolResultInfo>[];
        for (final toolCall in toolCalls) {
          if (streamCancelled || cancellationToken?.isCancelled == true) {
            yield StreamResponse.error('Cancelled');
            return;
          }

          final toolName = toolCall.function.name;
          final toolCallId = toolCall.id;
          Map<String, dynamic> toolArguments;
          try {
            toolArguments =
                jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
          } catch (_) {
            toolArguments = {};
          }

          // 广播工具调用开始事件
          yield StreamResponse.toolCallStart(
            toolCallId: toolCallId,
            toolName: toolName,
            arguments: toolArguments,
          );
          _toolEventCallback?.call(
            ToolCallStartEvent(
              toolCallId: toolCallId,
              toolName: toolName,
              arguments: toolArguments,
            ),
          );

          // 查找工具
          final tool = _toolRegistry!.getTool(toolName);
          if (tool == null) {
            final errorResult = '工具 "$toolName" 未注册';
            earlyResults.add(ToolResultInfo(
              toolCallId: toolCallId,
              content: errorResult,
              isError: true,
              name: toolName,
            ));
            yield StreamResponse.toolCallResult(
              toolCallId: toolCallId,
              toolName: toolName,
              result: errorResult,
              isError: true,
            );
            _toolEventCallback?.call(
              ToolCallResultEvent(
                toolCallId: toolCallId,
                toolName: toolName,
                result: errorResult,
                isError: true,
              ),
            );
            continue;
          }

          // 权限检查（串行，因为可能需要等待用户交互）
          if (_permissionManager != null && tool.requiresPermission) {
            final decision = await _permissionManager!.checkPermission(
              tool,
              toolArguments,
            );

            if (decision == PermissionDecision.deny) {
              final denyResult =
                  _permissionManager!.lastDenyMessage ??
                  '权限被拒绝: 用户拒绝了工具 "$toolName" 的执行';
              earlyResults.add(ToolResultInfo(
                toolCallId: toolCallId,
                content: denyResult,
                isError: true,
                name: toolName,
              ));
              yield StreamResponse.toolCallResult(
                toolCallId: toolCallId,
                toolName: toolName,
                result: denyResult,
                isError: true,
              );
              _toolEventCallback?.call(
                ToolCallResultEvent(
                  toolCallId: toolCallId,
                  toolName: toolName,
                  result: denyResult,
                  isError: true,
                ),
              );
              continue;
            }
          }

          pendingExecutions.add((
            call: toolCall,
            tool: tool,
            args: toolArguments,
          ));
        }

        // Phase 2: 并行执行已批准的工具
        if (pendingExecutions.isEmpty && earlyResults.isEmpty) {
          // 没有任何工具结果，继续循环
          continue;
        }

        // Phase 3: 按顺序处理执行结果并写入历史
        // 将所有工具结果（包括早期拒绝/未找到的）合并为一条分组消息写入
        final allToolResults = <ToolResultInfo>[...earlyResults];

        // 如果只有早期结果（无 pending 执行），直接写入
        if (pendingExecutions.isEmpty) {
          memoryManager.addMessage(
            currentEmployeeUuid!,
            deviceId ?? 'default',
            ChatMsg.toolResultGroup(allToolResults),
            metadata: {
              'toolNames': allToolResults.map((r) => r.name).toList(),
            },
          );
          continue;
        }

        _runningTools.addAll(pendingExecutions.map((e) => e.tool));

        // 启动并行执行，每个 future 自行捕获异常
        final results = await Future.wait(
          pendingExecutions.map((exec) async {
            final stopwatch = Stopwatch()..start();
            final toolName = exec.tool.name;
            ToolResult result;
            bool wasCancelled = false;
            try {
              final token = cancellationToken ?? CancellationToken();
              final executor = CancellableToolExecutor(exec.tool, token);
              result = await executor.execute(exec.args);
            } on ToolCancelledException {
              result = ToolResult.error('工具调用已取消: $toolName');
              wasCancelled = true;
            } catch (e) {
              result = ToolResult.error('工具执行异常: $e');
            } finally {
              stopwatch.stop();
            }
            final resultPreview = result.content.length > 100
                ? '${result.content.substring(0, 100)}...(truncated, total ${result.content.length} chars)'
                : result.content;
            print(
              '[LlmChatAdapter] 工具执行完成: $toolName, isError=${result.isError}, '
              'duration=${stopwatch.elapsedMilliseconds}ms, result=$resultPreview',
            );
            return _ToolExecResult(
              toolCall: exec.call,
              toolName: toolName,
              result: result,
              durationMs: stopwatch.elapsedMilliseconds,
              wasCancelled: wasCancelled,
            );
          }),
        );

        _runningTools.clear();

        // 如果因取消导致所有工具被终止，直接退出
        if (results.any((r) => r.wasCancelled) &&
            (streamCancelled || cancellationToken?.isCancelled == true)) {
          // 将已取消工具的结果加入 earlyResults 并写入
          for (final r in results) {
            if (r.wasCancelled) {
              allToolResults.add(ToolResultInfo(
                toolCallId: r.toolCall.id,
                content: r.result.content,
                isError: true,
                name: r.toolName,
              ));
            }
          }
          memoryManager.addMessage(
            currentEmployeeUuid!,
            deviceId ?? 'default',
            ChatMsg.toolResultGroup(allToolResults),
            metadata: {
              'toolNames': allToolResults.map((r) => r.name).toList(),
            },
          );
          yield StreamResponse.error('Cancelled');
          return;
        }

        // 收集执行结果
        for (final r in results) {
          allToolResults.add(ToolResultInfo(
            toolCallId: r.toolCall.id,
            content: r.result.content,
            isError: r.result.isError,
            name: r.toolName,
          ));

          // 广播工具调用结果事件（仍然逐个 yield 给前端）
          yield StreamResponse.toolCallResult(
            toolCallId: r.toolCall.id,
            toolName: r.toolName,
            result: r.result.content,
            isError: r.result.isError,
            durationMs: r.durationMs,
          );
          _toolEventCallback?.call(
            ToolCallResultEvent(
              toolCallId: r.toolCall.id,
              toolName: r.toolName,
              result: r.result.content,
              isError: r.result.isError,
              durationMs: r.durationMs,
            ),
          );

          // 工具调用出错时，yield 提示给用户看到
          if (r.result.isError) {
            final userHint =
                '\n⚠️ 工具 ${r.toolName} 执行失败: ${r.result.content.split('\n').first}';
            yield StreamResponse.chunk(userHint);
          }
        }

        // 将所有工具结果合并为一条分组消息写入历史
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          ChatMsg.toolResultGroup(allToolResults),
          metadata: {
            'toolNames': allToolResults.map((r) => r.name).toList(),
          },
        );

        // 所有工具执行完毕，继续循环让 LLM 处理结果
      }

      // 达到最大迭代次数限制
      if (!completedNormally) {
        final errorMsg =
            '已达到最大工具调用轮次（$_maxToolCallIterations 次），请尝试简化您的需求或拆分为多个问题';
        yield StreamResponse.error(errorMsg);
        return;
      }

      // 发送完成信号
      yield StreamResponse.done();
    } catch (e) {
      yield StreamResponse.error('LLM 请求失败: $e');
    } finally {
      cancelSubscription?.cancel();
      _isStreaming = false;
      _dioCancelToken = null;
      _runningTools.clear();
    }
  }

  @override
  Future<void> stopStreaming() async {
    _isStreaming = false;
    _dioCancelToken?.cancel('User stopped streaming');
    _dioCancelToken = null;

    // 取消正在执行的工具
    for (final tool in _runningTools) {
      tool.cancel();
    }
    _runningTools.clear();
  }

  @override
  Future<List<AgentMessage>> getSessionMessages(String employeeId) async {
    final session = memoryManager.getSession(employeeId);
    if (session == null) return [];

    final messages = session.allMessages.map(_messageWrapperToMap).toList();
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  @override
  Future<void> clearCurrentSession() async {
    if (currentEmployeeUuid != null) {
      memoryManager.clearSession(currentEmployeeUuid!);
      _compressor?.clearCache(currentEmployeeUuid!);
    }
  }

  @override
  void setContext(Map<String, dynamic> contextData) {
    _context = {...?_context, ...contextData};
  }

  @override
  void clearContext() {
    _context = null;
  }

  @override
  bool removeMessageFromMemory(String messageId) {
    if (currentEmployeeUuid == null) {
      print(
        '[LlmChatAdapter] removeMessageFromMemory: currentEmployeeUuid is null',
      );
      return false;
    }

    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) {
      print('[LlmChatAdapter] removeMessageFromMemory: session not found');
      return false;
    }

    return session.removeMessage(messageId);
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    print('[LlmChatAdapter] updateProvider called with: $providerConfig');
    final config = ProviderConfig.fromMap(providerConfig);
    print(
      '[LlmChatAdapter] parsed config: provider=${config.provider}, model=${config.model}, baseUrl=${config.baseUrl}',
    );
    config.validate();
    print('[LlmChatAdapter] config validated successfully');

    _chatCapability = await _buildChatCapability(config);
    _providerConfig = config;
    print('[LlmChatAdapter] _chatCapability created: $_chatCapability');

    // 配置上下文压缩器
    final compression = config.compressionConfig;
    if (compression != null && compression.enabled) {
      _compressor = ContextCompressor(
        config: compression,
        onSummarize: (prompt) async {
          final messages = [llm.ChatMessage.user(prompt)];
          final response = await _chatCapability!.chat(messages);
          return response.text ?? '';
        },
      );
    } else {
      _compressor?.dispose();
      _compressor = null;
    }
  }

  @override
  Map<String, dynamic>? getProviderConfig() {
    return _providerConfig?.toMap();
  }

  @override
  Future<void> updateProjectContext(
    Map<String, dynamic>? projectContext,
  ) async {
    if (projectContext != null) {
      _context = {...?_context, ...projectContext};
    }
  }

  @override
  void setToolRegistry(ToolRegistry? registry) {
    _toolRegistry = registry;
  }

  @override
  void setPermissionManager(ToolPermissionManager? manager) {
    _permissionManager = manager;
  }

  @override
  void setToolEventCallback(void Function(ToolEvent event)? callback) {
    _toolEventCallback = callback;
  }

  @override
  void updateMessageStatus(
    String messageId,
    AgentMessageStatus status, {
    String? error,
  }) {
    // 内存适配器不需要持久化，子类 PersistentChatAdapter 可重写此方法
  }

  @override
  Future<String> invokeOnce(String prompt) async {
    if (_chatCapability == null) {
      throw Exception('未配置 LLM Provider');
    }
    final messages = [llm.ChatMessage.user(prompt)];
    final response = await _chatCapability!.chat(messages);
    return response.text ?? '';
  }

  @override
  Future<void> dispose() async {
    await stopStreaming();
    memoryManager.dispose();
    _compressor?.dispose();
    _compressor = null;
    _chatCapability = null;
    _providerConfig = null;
    _context = null;
    currentEmployeeUuid = null;
    _toolRegistry = null;
    _permissionManager = null;
    _toolEventCallback = null;
  }

  // ===== 内部方法 =====

  /// 构建聊天能力
  Future<llm.ChatCapability> _buildChatCapability(ProviderConfig config) async {
    final builder = llm.ai();

    switch (config.provider) {
      case LLMProvider.openai:
        builder.openai();
      case LLMProvider.anthropic:
        builder.anthropic();
      case LLMProvider.google:
        builder.google();
      case LLMProvider.ollama:
        builder.ollama();
    }

    builder.model(config.model);

    if (config.apiKey != null && config.apiKey!.isNotEmpty) {
      builder.apiKey(config.apiKey!);
    }

    if (config.baseUrl != null && config.baseUrl!.isNotEmpty) {
      builder.baseUrl(config.baseUrl!);
    }

    builder.temperature(config.options.temperature);

    if (config.options.maxTokens != null) {
      builder.maxTokens(config.options.maxTokens!);
    }

    if (config.options.topP != null) {
      builder.topP(config.options.topP!);
    }

    if (config.options.stop != null && config.options.stop!.isNotEmpty) {
      builder.stopSequences(config.options.stop!);
    }

    return await builder.build();
  }

  /// 构建系统提示词
  String? _buildSystemPrompt() {
    if (_context == null) return null;

    final parts = <String>[];

    final systemPrompt = _context!['systemPrompt'] as String?;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      parts.add(systemPrompt);
    }

    final projectName = _context!['projectName'] as String?;
    final projectContext = _context!['projectContext'];
    final projectUuid = _context!['projectUuid'] as String?;
    final workPath = _context!['workPath'] as String?;

    final hasProject =
        (projectName != null && projectName.isNotEmpty) ||
        projectContext != null ||
        (projectUuid != null && projectUuid.isNotEmpty) ||
        (workPath != null && workPath.isNotEmpty);

    if (hasProject) {
      final projectLines = <String>[];

      if (projectName != null && projectName.isNotEmpty) {
        projectLines.add('当前工作项目: $projectName');
      }
      if (projectUuid != null && projectUuid.isNotEmpty) {
        projectLines.add('项目ID: $projectUuid');
      }
      if (workPath != null && workPath.isNotEmpty) {
        projectLines.add('项目工作路径: $workPath');
      }
      if (projectContext != null) {
        projectLines.add('项目上下文:\n$projectContext');
      }

      parts.add(
        '## 当前工作项目\n'
        '${projectLines.join('\n')}\n\n'
        '请基于以上项目信息进行工作。所有操作和回答都应围绕此项目展开，'
        '如果用户没有特别指定，默认在当前项目范围内执行任务。'
        '${workPath != null && workPath.isNotEmpty ? '\n读写文件时请优先使用工作路径 $workPath 作为根目录。' : ''}',
      );
    }

    final additionalInfo = _context!['additionalInfo'];
    if (additionalInfo != null) {
      parts.add('补充信息:\n$additionalInfo');
    }

    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// 将 MessageWrapper 转换为 Map（用于持久化）
  Map<String, dynamic> _messageWrapperToMap(MessageWrapper wrapper) {
    final message = wrapper.message;

    final roleStr = switch (message.role) {
      ChatMsgRole.system => 'system',
      ChatMsgRole.user => 'user',
      ChatMsgRole.assistant => 'assistant',
      ChatMsgRole.tool => 'tool',
    };

    final map = <String, dynamic>{
      'uuid': wrapper.uuid,
      'id': wrapper.uuid,
      'role': roleStr,
      'content': message.content,
      'createdAt': wrapper.createdAt.toIso8601String(),
    };

    // assistant 消息附加 toolCalls 信息
    if (message.role == ChatMsgRole.assistant &&
        message.toolCalls != null &&
        message.toolCalls!.isNotEmpty) {
      map['toolCalls'] = message.toolCalls!
          .map(
            (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
          )
          .toList();
    }

    // tool 消息附加 toolCallId、toolName 和 type
    if (message.role == ChatMsgRole.tool) {
      map['toolCallId'] = message.toolCallId;
      map['type'] = 'functionResult';
      final toolName = wrapper.metadata?['toolName'] as String?;
      if (toolName != null) {
        map['toolName'] = toolName;
      }
      if (message.isError) {
        map['isError'] = true;
      }
    }

    // 从 wrapper.metadata 读取 status
    if (wrapper.metadata != null && wrapper.metadata!['status'] != null) {
      map['status'] = wrapper.metadata!['status'];
    }

    return map;
  }
}
