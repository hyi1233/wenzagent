import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

/// 远程 Agent 客户端
///
/// 通过 RPC 远程访问 Agent 服务。
/// 支持对话、会话管理、状态订阅等功能。
class AgentClient {
  final Future<Map<String, dynamic>> Function(String method, Map<String, dynamic> params) _rpcCall;
  final Stream<Map<String, dynamic>>? _eventStream;

  final _stateController = StreamController<AgentStateSnapshot>.broadcast();
  StreamSubscription? _eventSubscription;

  String? _currentEmployeeId;
  String? _currentSessionId;

  AgentClient({
    required Future<Map<String, dynamic>> Function(String method, Map<String, dynamic> params) rpcCall,
    Stream<Map<String, dynamic>>? eventStream,
  })  : _rpcCall = rpcCall,
        _eventStream = eventStream {
    _subscribeEvents();
  }

  /// 当前员工ID
  String? get currentEmployeeId => _currentEmployeeId;

  /// 当前会话ID
  String? get currentSessionId => _currentSessionId;

  /// 状态变更流
  Stream<AgentStateSnapshot> get onStateChanged => _stateController.stream;

  void _subscribeEvents() {
    if (_eventStream == null) return;

    _eventSubscription = _eventStream.listen((event) {
      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>?;

      if (type == 'agentStateChanged' && data != null) {
        try {
          final snapshot = AgentStateSnapshot.fromMap(data);
          _stateController.add(snapshot);
        } catch (_) {}
      }
    });
  }

  /// 创建或获取 Agent
  Future<Map<String, dynamic>> getOrCreateAgent({
    required String employeeId,
  }) async {
    final result = await _rpcCall(
      AgentRpcConfig.methodGetOrCreateAgent,
      {
        'employeeId': employeeId,
      },
    );

    _currentEmployeeId = employeeId;
    _currentSessionId = result['employeeId'] as String?;

    return result;
  }

  /// 发送消息
  Future<String> sendMessage({
    required String content,
    String? employeeId,
  }) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final input = MessageInput(
      content: content,
      employeeId: empId,
    );

    final result = await _rpcCall(
      AgentRpcConfig.methodSendMessage,
      {
        'employeeId': empId,
        'messageData': input.toMap(),
      },
    );

    return result['messageId'] as String;
  }

  /// 中断当前处理
  Future<void> interrupt({String? employeeId}) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    await _rpcCall(AgentRpcConfig.methodInterrupt, {
      'employeeId': empId,
    });
  }

  /// 获取会话列表
  Future<List<Map<String, dynamic>>> getSessionList({String? employeeId}) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetSessionList, {
      'employeeId': empId,
    });

    return (result['sessions'] as List).cast<Map<String, dynamic>>();
  }

  /// 创建新会话
  Future<String> createSession({String? employeeId}) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodCreateSession, {
      'employeeId': empId,
    });

    _currentSessionId = result['employeeId'] as String;
    return _currentSessionId!;
  }

  /// 切换会话
  Future<void> switchSession({
    required String employeeId,
  }) async {
    final empId = _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    await _rpcCall(AgentRpcConfig.methodSwitchSession, {
      'employeeId': empId,
      'sessionId': employeeId,
    });

    _currentSessionId = employeeId;
  }

  /// 获取会话消息
  Future<List<AgentMessage>> getSessionMessages({
    String? employeeId,
  }) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetSessionMessages, {
      'employeeId': empId,
    });

    final messages = (result['messages'] as List).cast<Map<String, dynamic>>();
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 获取 Agent 状态
  Future<AgentStateSnapshot> getState({String? employeeId}) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetState, {
      'employeeId': empId,
    });

    return AgentStateSnapshot.fromMap(result);
  }

  /// 设置上下文
  Future<void> setContext({
    required Map<String, dynamic> contextData,
    String? employeeId,
  }) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    await _rpcCall(AgentRpcConfig.methodSetContext, {
      'employeeId': empId,
      'contextData': contextData,
    });
  }

  /// 获取上下文
  Future<Map<String, dynamic>?> getContext({String? employeeId}) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetContext, {
      'employeeId': empId,
    });

    return result['context'] as Map<String, dynamic>?;
  }

  // ===== 模型管理 =====

  /// 切换 AI 模型
  Future<void> setProvider({
    required ProviderConfig providerConfig,
    String? employeeId,
  }) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    await _rpcCall(AgentRpcConfig.methodSetProvider, {
      'employeeId': empId,
      'providerConfig': providerConfig.toMap(),
    });
  }

  /// 获取当前模型配置
  Future<ProviderConfig?> getProvider({String? employeeId}) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetProvider, {
      'employeeId': empId,
    });

    final configMap = result['providerConfig'] as Map<String, dynamic>?;
    return configMap != null ? ProviderConfig.fromMap(configMap) : null;
  }

  // ===== 项目管理 =====

  /// 绑定项目
  Future<void> setProject({
    required ProjectData? projectData,
    String? employeeId,
  }) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    await _rpcCall(AgentRpcConfig.methodSetProject, {
      'employeeId': empId,
      'projectData': projectData?.toMap(),
    });
  }

  /// 获取当前项目UUID
  Future<String?> getProjectUuid({String? employeeId}) async {
    final empId = employeeId ?? _currentEmployeeId;
    if (empId == null) {
      throw Exception('employeeId is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetProjectUuid, {
      'employeeId': empId,
    });

    return result['projectUuid'] as String?;
  }

  /// 获取活跃 Agent 列表
  Future<List<Map<String, dynamic>>> getActiveSummaries() async {
    final result = await _rpcCall(AgentRpcConfig.methodGetActiveSummaries, {});
    return (result['summaries'] as List).cast<Map<String, dynamic>>();
  }

  /// 释放资源
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    await _stateController.close();
  }
}
