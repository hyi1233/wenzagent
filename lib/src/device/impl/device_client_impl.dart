import 'dart:async';
import 'dart:convert';

import '../../agent/client/agent_proxy.dart';
import '../../agent/i_agent.dart';
import '../../agent/rpc/agent_rpc_config.dart';
import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
import '../../lan/impl/lan_client_service_impl.dart';
import '../../rpc/remote_call_manager.dart';
import '../../rpc/remote_call_server.dart';
import '../../rpc/rpc_config.dart';
import '../device_client.dart';

/// DeviceClient 实现类
class DeviceClientImpl implements DeviceClient {
  @override
  final String deviceId;

  @override
  final String? deviceName;

  @override
  final String host;

  @override
  final int port;

  @override
  final String? topic;

  /// LAN 客户端
  LanClientServiceImpl? _lanClient;

  /// RPC 管理器（发起调用）
  RemoteCallManager? _rpcManager;

  /// RPC 服务器（处理调用）
  RemoteCallServer? _rpcServer;

  /// 本地 Agent 注册表
  final Map<String, IAgent> _localAgents = {};

  /// 本地代理缓存
  final Map<String, AgentProxy> _localProxies = {};

  /// 远程代理缓存（断线时保留）
  final Map<String, AgentProxy> _remoteProxies = {};

  /// Agent 事件订阅（用于广播到 LAN）
  final Map<String, StreamSubscription<Map<String, dynamic>>> _agentEventSubscriptions = {};

  /// 连接状态控制器
  final _stateController = StreamController<DeviceConnectionState>.broadcast();

  /// Agent 事件控制器
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// 消息订阅
  StreamSubscription<LanMessage>? _messageSubscription;

  /// 当前连接状态
  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;

  /// 是否已释放
  bool _disposed = false;

  DeviceClientImpl({
    required this.deviceId,
    this.deviceName,
    required this.host,
    this.port = 9090,
    this.topic,
  });

  // ===== 只读属性 =====

  @override
  DeviceConnectionState get connectionState => _connectionState;

  @override
  bool get isConnected => _connectionState == DeviceConnectionState.connected;

  @override
  List<String> get localAgentIds => _localAgents.keys.toList();

  @override
  List<String> get remoteAgentIds => _remoteProxies.keys.toList();

  @override
  Stream<DeviceConnectionState> get onStateChanged => _stateController.stream;

  @override
  Stream<Map<String, dynamic>> get onAgentEvent => _eventController.stream;

  // ===== 连接管理 =====

  @override
  Future<void> connect() async {
    if (_disposed) {
      throw StateError('DeviceClient 已释放');
    }

    if (_connectionState == DeviceConnectionState.connected ||
        _connectionState == DeviceConnectionState.connecting) {
      return;
    }

    _updateState(DeviceConnectionState.connecting);

    try {
      // 1. 创建 LAN 客户端
      _lanClient = LanClientServiceImpl(
        deviceId: deviceId,
        topic: topic,
      );

      // 2. 连接服务器
      await _lanClient!.connect(host, port: port);

      // 3. 创建 RPC 管理器（发起调用）
      _rpcManager = RemoteCallManager(
        clientService: _lanClient!,
        localDeviceId: deviceId,
      );

      // 4. 创建 RPC 服务器（处理调用）
      _rpcServer = RemoteCallServer(
        clientService: _lanClient!,
        localDeviceId: deviceId,
      );
      _registerRpcMethods();

      // 5. 订阅消息流
      _messageSubscription = _lanClient!.messageStream.listen(_handleMessage);

      // 6. 发送设备注册信息
      _sendDeviceRegistration();

      _updateState(DeviceConnectionState.connected);
    } catch (e) {
      _updateState(DeviceConnectionState.disconnected);
      rethrow;
    }
  }

  /// 注册 RPC 方法处理器
  void _registerRpcMethods() {
    // 发送消息
    _rpcServer!.register(
      AgentRpcConfig.methodSendMessage,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final messageData = params['messageData'] as Map<String, dynamic>;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        final messageId = await agent.sendMessage(messageData);
        return {'messageId': messageId};
      },
    );

    // 中断处理
    _rpcServer!.register(
      AgentRpcConfig.methodInterrupt,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        await agent.interrupt();
        return {};
      },
    );

    // 获取会话列表
    _rpcServer!.register(
      AgentRpcConfig.methodGetSessionList,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        final sessions = await agent.getSessionList();
        return {'sessions': sessions};
      },
    );

    // 获取会话消息
    _rpcServer!.register(
      AgentRpcConfig.methodGetSessionMessages,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String?;
        final sessionUuid = params['sessionUuid'] as String;
        final agent = employeeUuid != null ? _localAgents[employeeUuid] : null;
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        final messages = await agent.getSessionMessages(sessionUuid);
        return {'messages': messages};
      },
    );

    // 创建会话
    _rpcServer!.register(
      AgentRpcConfig.methodCreateSession,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        final sessionUuid = await agent.createSession();
        return {'sessionUuid': sessionUuid};
      },
    );

    // 切换会话
    _rpcServer!.register(
      AgentRpcConfig.methodSwitchSession,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final sessionUuid = params['sessionUuid'] as String;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        await agent.switchSession(sessionUuid);
        return {};
      },
    );

    // 获取状态
    _rpcServer!.register(
      AgentRpcConfig.methodGetState,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        return agent.getStateSnapshot().toMap();
      },
    );

    // 设置上下文
    _rpcServer!.register(
      AgentRpcConfig.methodSetContext,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final contextData = params['contextData'] as Map<String, dynamic>;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        await agent.setContext(contextData);
        return {};
      },
    );

    // 获取上下文
    _rpcServer!.register(
      AgentRpcConfig.methodGetContext,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        return {'context': agent.getCurrentContext()};
      },
    );

    // 设置 Provider
    _rpcServer!.register(
      AgentRpcConfig.methodSetProvider,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final providerConfig = params['providerConfig'] as Map<String, dynamic>;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        await agent.setProvider(providerConfig);
        return {};
      },
    );

    // 设置项目
    _rpcServer!.register(
      AgentRpcConfig.methodSetProject,
      (params) async {
        final employeeUuid = params['employeeUuid'] as String;
        final projectData = params['projectData'] as Map<String, dynamic>?;
        final agent = _localAgents[employeeUuid];
        if (agent == null) {
          throw Exception('Agent not found: $employeeUuid');
        }
        await agent.setProject(projectData);
        return {};
      },
    );
  }

  @override
  Future<void> disconnect() async {
    if (_lanClient == null) return;

    await _messageSubscription?.cancel();
    _messageSubscription = null;

    await _lanClient!.disconnect();

    _rpcManager?.dispose();
    _rpcManager = null;

    _rpcServer?.dispose();
    _rpcServer = null;

    // 注意：断线时保留 remoteProxies，重连后可继续使用
    _updateState(DeviceConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await disconnect();

    // 取消所有 Agent 事件订阅
    for (final subscription in _agentEventSubscriptions.values) {
      await subscription.cancel();
    }
    _agentEventSubscriptions.clear();

    // 清理本地代理
    for (final proxy in _localProxies.values) {
      await proxy.dispose();
    }
    _localProxies.clear();

    // 清理远程代理
    for (final proxy in _remoteProxies.values) {
      await proxy.dispose();
    }
    _remoteProxies.clear();

    _localAgents.clear();

    await _stateController.close();
    await _eventController.close();
  }

  // ===== Agent 管理 =====

  @override
  void registerLocalAgent(String employeeId, IAgent agent) {
    if (_localAgents.containsKey(employeeId)) {
      throw StateError('Agent $employeeId 已注册');
    }

    _localAgents[employeeId] = agent;

    // 创建本地代理
    final proxy = AgentProxy.local(
      employeeUuid: employeeId,
      localAgent: agent,
    );
    proxy.attach(); // 增加引用计数
    _localProxies[employeeId] = proxy;

    // 订阅 Agent 事件，广播到 LAN
    final subscription = agent.onEvent.listen((event) {
      _broadcastAgentEvent(employeeId, event);
    });
    _agentEventSubscriptions[employeeId] = subscription;
  }

  /// 广播 Agent 事件到 LAN
  void _broadcastAgentEvent(String employeeId, Map<String, dynamic> event) {
    final lanClient = _lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final type = event['type'] as String?;
    final data = event['data'] as Map<String, dynamic>? ?? {};

    // 根据事件类型构造消息
    LanMessageType msgType;
    switch (type) {
      case 'agentStatusChanged':
        msgType = LanMessageType.agentStatusChanged;
      case 'messageStatusChanged':
        msgType = LanMessageType.agentMessageStatusChanged;
      default:
        return; // 不广播其他类型
    }

    final msg = LanMessage(
      type: msgType,
      fromId: deviceId,
      content: jsonEncode({
        'employeeUuid': employeeId,
        'type': type,
        'data': data,
      }),
      topic: topic,
    );

    lanClient.sendLanMessage(msg);
  }

  @override
  void unregisterLocalAgent(String employeeId) {
    final agent = _localAgents.remove(employeeId);
    if (agent == null) return;

    // 取消事件订阅
    _agentEventSubscriptions[employeeId]?.cancel();
    _agentEventSubscriptions.remove(employeeId);

    // 减少引用计数
    final proxy = _localProxies.remove(employeeId);
    proxy?.detach();
  }

  @override
  AgentProxy getAgent({
    required String deviceId,
    required String employeeId,
  }) {
    // 如果是本地设备，从 localProxies 获取
    if (deviceId == this.deviceId) {
      final proxy = _localProxies[employeeId];
      if (proxy == null) {
        throw StateError('本地 Agent $employeeId 未注册');
      }
      return proxy;
    }

    // 否则从 remoteProxies 创建或获取
    return _getOrCreateRemoteProxy(deviceId, employeeId);
  }

  /// 获取或创建远程代理
  AgentProxy _getOrCreateRemoteProxy(String deviceId, String employeeId) {
    final key = '$deviceId:$employeeId';

    var proxy = _remoteProxies[key];
    if (proxy != null) return proxy;

    // 创建远程代理
    proxy = AgentProxy.remote(
      employeeUuid: employeeId,
      rpcCall: (method, params) => _invokeRemote(deviceId, method, params),
      remoteEventStream: _eventController.stream,
    );

    _remoteProxies[key] = proxy;
    return proxy;
  }

  /// 发起远程 RPC 调用
  Future<Map<String, dynamic>> _invokeRemote(
    String toDeviceId,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    return _rpcManager!.invoke(
      method,
      params,
      toDeviceId: toDeviceId,
    );
  }

  // ===== 设备管理 =====

  @override
  Future<List<LanDeviceInfo>> getOnlineDevices() async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    // 通过 RPC 调用获取设备列表
    try {
      final result = await _rpcManager!.invoke(
        RpcConfig.methodGetOnlineDevices,
        {},
        toDeviceId: 'host', // 发送给主机
      );

      final devices = result['devices'] as List?;
      if (devices == null) return [];

      return devices
          .map((d) => LanDeviceInfo.fromMap(d as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 如果 RPC 方法不存在，返回空列表
      return [];
    }
  }

  // ===== 文件传输 =====

  @override
  Future<String> uploadFile(
    String filePath, {
    void Function(double)? onProgress,
  }) async {
    if (_lanClient == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    final fileId = await _lanClient!.uploadFile(filePath);

    // 监听上传进度
    if (onProgress != null) {
      _monitorProgress(_lanClient!.uploadProgress, onProgress);
    }

    return fileId;
  }

  @override
  Future<void> downloadFile(
    String fileId,
    String savePath, {
    void Function(double)? onProgress,
  }) async {
    if (_lanClient == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    await _lanClient!.downloadFile(fileId, savePath);

    // 监听下载进度
    if (onProgress != null) {
      _monitorProgress(_lanClient!.downloadProgress, onProgress);
    }
  }

  /// 监控进度（简化实现）
  void _monitorProgress(double progress, void Function(double) onProgress) {
    Timer.periodic(const Duration(milliseconds: 100), (timer) {
      onProgress(progress);
      if (progress >= 1.0) {
        timer.cancel();
      }
    });
  }

  // ===== 内部方法 =====

  /// 更新连接状态
  void _updateState(DeviceConnectionState state) {
    _connectionState = state;
    _stateController.add(state);
  }

  /// 发送设备注册信息
  void _sendDeviceRegistration() {
    if (_lanClient == null || !_lanClient!.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.clientInfo,
      fromId: deviceId,
      fromName: deviceName,
      content: jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'topic': topic,
      }),
      fileName: deviceId, // 使用 fileName 字段传递 deviceId
      topic: topic ?? '',
    );

    _lanClient!.sendLanMessage(msg);
  }

  /// 处理收到的消息
  void _handleMessage(LanMessage msg) {
    switch (msg.type) {
      case LanMessageType.rpcRequest:
        _handleRpcRequest(msg);

      case LanMessageType.rpcResponse:
        _handleRpcResponse(msg);

      case LanMessageType.rpcError:
        _handleRpcError(msg);

      case LanMessageType.rpcStreamChunk:
        _handleStreamChunk(msg);

      case LanMessageType.rpcStreamEnd:
        _handleStreamEnd(msg);

      case LanMessageType.agentStatusChanged:
      case LanMessageType.agentMessageStatusChanged:
        _handleAgentEvent(msg);

      case LanMessageType.system:
        _handleSystemMessage(msg);

      default:
        break;
    }
  }

  /// 处理 RPC 请求
  void _handleRpcRequest(LanMessage msg) {
    if (_rpcServer == null) return;

    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? {};
      _rpcServer!.handleRequest(payload);
    } catch (_) {}
  }

  /// 处理 RPC 响应
  void _handleRpcResponse(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleResponse(payload);
    } catch (_) {}
  }

  /// 处理 RPC 错误
  void _handleRpcError(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleError(payload);
    } catch (_) {}
  }

  /// 处理流式 chunk
  void _handleStreamChunk(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleStreamChunk(payload);
    } catch (_) {}
  }

  /// 处理流式结束
  void _handleStreamEnd(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleStreamEnd(payload);
    } catch (_) {}
  }

  /// 处理 Agent 事件（状态变更、消息状态变更等）
  void _handleAgentEvent(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final type = content['type'] as String?;
      final data = content['data'] as Map<String, dynamic>? ?? {};
      final employeeUuid = content['employeeUuid'] as String?;

      _eventController.add({
        'type': type,
        'data': data,
        'employeeUuid': employeeUuid,
        'fromId': msg.fromId,
        'fromDeviceId': msg.fromId,
      });
    } catch (_) {}
  }

  /// 处理系统消息
  void _handleSystemMessage(LanMessage msg) {
    final content = msg.content ?? '';
    
    // 检测被踢下线
    if (content == 'kicked:duplicate_login') {
      _updateState(DeviceConnectionState.disconnected);
      return;
    }
    
    // 检测重连成功
    if (content.contains('重连成功')) {
      _updateState(DeviceConnectionState.connected);
      _sendDeviceRegistration();
    }
  }
}
