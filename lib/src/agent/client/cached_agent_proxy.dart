import 'dart:async';
import 'dart:convert';

import 'agent_proxy.dart';
import '../entity/entity.dart';
import '../agent_state.dart';
import '../tool/agent_tool.dart';
import '../../persistence/entities/message_entity.dart';
import '../../service/message_store_service.dart';

/// 缓存状态
enum CacheState {
  /// 空闲
  idle,
  
  /// 加载中
  loading,
  
  /// 同步中
  syncing,
  
  /// 错误
  error,
}

/// 带缓存的AgentProxy包装器
///
/// **核心设计**：
/// - 本地模式（isLocalMode=true）：直接透传调用，不缓存（本地Agent已有持久化）
/// - 远程模式（isLocalMode=false）：启用缓存机制，支持离线查看
///
/// **远程模式缓存策略**：
/// 1. 立即显示本地缓存消息（快速响应，支持离线查看）
/// 2. 后台异步加载远程最新消息（实时同步）
/// 3. 智能合并本地和远程消息（避免重复）
/// 4. 更新本地缓存（保持最新状态）
class CachedAgentProxy {
  final AgentProxy _proxy;
  final MessageStoreService _messageStore;
  final String _deviceId;
  final String _employeeId;
  
  /// 是否需要缓存（仅远程模式需要）
  late final bool _needCache;
  
  /// 缓存状态（仅远程模式使用）
  CacheState _cacheState = CacheState.idle;
  final StreamController<CacheState> _cacheStateController = 
      StreamController<CacheState>.broadcast();
  
  /// 消息变更通知流（仅远程模式使用）
  final StreamController<List<AgentMessage>> _messagesController = 
      StreamController<List<AgentMessage>>.broadcast();
  
  /// 消息缓存（仅远程模式使用）
  List<AgentMessage> _cachedMessages = [];
  DateTime? _lastSyncTime;
  
  /// 是否已释放
  bool _isDisposed = false;
  
  CachedAgentProxy({
    required AgentProxy proxy,
    required MessageStoreService messageStore,
    required String deviceId,
    required String employeeId,
  }) : _proxy = proxy,
       _messageStore = messageStore,
       _deviceId = deviceId,
       _employeeId = employeeId {
    // 关键：只在远程模式下启用缓存
    _needCache = !_proxy.isLocalMode;
  }
  
  // ===== 核心方法 =====
  
  /// 初始化
  Future<void> initialize() async {
    if (_isDisposed) return;
    
    // 本地模式不需要初始化缓存
    if (!_needCache) {
      return;
    }
    
    // 远程模式：加载本地缓存并同步一次远程消息
    _updateCacheState(CacheState.loading);
    
    try {
      // 1. 从本地缓存加载消息（支持离线查看）
      await _loadLocalMessages();
      
      // 2. 同步一次远程消息（确保启动时有最新数据）
      await syncWithRemote();
      
      _updateCacheState(CacheState.idle);
    } catch (e) {
      _updateCacheState(CacheState.error);
      // 同步失败不影响本地缓存使用
      print('初始化同步失败: $e');
    }
  }
  
  /// 获取消息
  ///
  /// **核心逻辑**：
  /// 1. 打开界面时，先返回本地缓存（快速响应，支持离线查看）
  /// 2. 然后主动查询远程消息（确保数据最新）
  /// 3. 监听到远程消息更新后，自动同步到本地缓存
  ///
  /// - 本地模式：直接从Agent获取（Agent已有持久化）
  /// - 远程模式：返回缓存 + 主动查询远程消息
  Future<List<AgentMessage>> getMessages({
    bool forceRefresh = false,
    int? limit,
    int? offset,
  }) async {
    if (_isDisposed) return [];
    
    // 本地模式：直接透传
    if (!_needCache) {
      final messages = await _proxy.getSessionMessages();
      // 应用分页
      if (offset != null && offset > 0) {
        return messages.skip(offset).toList();
      }
      if (limit != null && limit > 0) {
        return messages.take(limit).toList();
      }
      return messages;
    }
    
    // 远程模式：
    // 1. 先返回本地缓存（快速响应）
    var messages = _cachedMessages;
    
    // 2. 主动查询远程消息（后台同步）
    // 无论是否有缓存，都主动查询确保数据最新
    if (forceRefresh) {
      // 强制刷新：等待同步完成再返回
      await syncWithRemote();
      messages = _cachedMessages;
    } else {
      // 非强制：先返回缓存，后台同步更新
      // 不等待同步完成，用户立即看到缓存数据
      syncWithRemote().catchError((e) {
        print('同步远程消息失败: $e');
      });
    }
    
    // 应用分页
    if (offset != null && offset > 0) {
      messages = messages.skip(offset).toList();
    }
    if (limit != null && limit > 0) {
      messages = messages.take(limit).toList();
    }
    
    return messages;
  }
  
  /// 同步远程消息（仅远程模式有效）
  Future<void> syncWithRemote() async {
    if (_isDisposed) return;
    
    // 本地模式不需要同步
    if (!_needCache) {
      return;
    }
    
    _updateCacheState(CacheState.syncing);
    
    try {
      // 1. 获取远程消息
      final remoteMessages = await _proxy.getSessionMessages();
      
      // 2. 合并消息
      await _mergeMessages(remoteMessages);
      
      // 3. 更新本地缓存
      await _updateLocalCache();
      
      _lastSyncTime = DateTime.now();
      _updateCacheState(CacheState.idle);
      
      // 4. 通知界面消息已更新
      _notifyMessagesChanged();
    } catch (e) {
      _updateCacheState(CacheState.error);
      // 同步失败不影响本地缓存使用
      print('同步远程消息失败: $e');
    }
  }
  
  // ===== 内部方法（仅远程模式使用） =====
  
  /// 从本地缓存加载消息
  Future<void> _loadLocalMessages() async {
    if (!_needCache) return;
    
    try {
      final messageEntities = await _messageStore.getMessagesWithDeviceId(
        _deviceId,
        _employeeId,
      );
      
      _cachedMessages = messageEntities.map(_entityToMessage).toList();
      print('从本地缓存加载 ${_cachedMessages.length} 条消息');
    } catch (e) {
      print('加载本地缓存失败: $e');
      _cachedMessages = [];
    }
  }
  
  /// 合并本地和远程消息
  Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
    if (!_needCache) return;
    
    // 使用 Map 按 ID 去重，保留最新的消息
    final mergedMap = <String, AgentMessage>{};
    
    // 1. 优先添加远程消息（状态更准确、已持久化）
    for (final remoteMsg in remoteMessages) {
      mergedMap[remoteMsg.id] = remoteMsg;
    }
    
    // 2. 添加本地待同步消息（仅限远程没有的）
    for (final localMsg in _cachedMessages) {
      if (!mergedMap.containsKey(localMsg.id)) {
        // 远程没有这个消息ID
        if (_isPendingSync(localMsg)) {
          // 是待同步消息，保留本地的
          mergedMap[localMsg.id] = localMsg;
        }
        // 否则丢弃（本地已确认但远程没有的旧消息）
      }
      // 如果远程已有该消息，直接使用远程的（已在 mergedMap 中）
    }
    
    // 3. 转换为列表并按时间排序
    final mergedMessages = mergedMap.values.toList();
    mergedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    
    _cachedMessages = mergedMessages;
  }
  
  /// 更新本地缓存
  Future<void> _updateLocalCache() async {
    if (!_needCache) return;
    
    try {
      for (final message in _cachedMessages) {
        final entity = _messageToEntity(message);
        await _messageStore.updateMessage(entity, deviceId: _deviceId);
      }
    } catch (e) {
      print('更新本地缓存失败: $e');
    }
  }
  
  /// 检查消息是否待同步
  bool _isPendingSync(AgentMessage message) {
    return message.status == 'pending' || 
           message.metadata?['localOnly'] == true;
  }
  
  /// 更新缓存状态
  void _updateCacheState(CacheState state) {
    if (!_needCache) return;
    
    _cacheState = state;
    _cacheStateController.add(state);
  }
  
  /// 通知消息变更
  void _notifyMessagesChanged() {
    if (!_needCache || _isDisposed) return;
    
    _messagesController.add(List.unmodifiable(_cachedMessages));
  }
  
  // ===== 转换方法 =====
  
  AgentMessage _entityToMessage(AiEmployeeMessageEntity entity) {
    return AgentMessage(
      id: entity.uuid,
      role: entity.role,
      type: entity.type,
      content: entity.content,
      createdAt: entity.createTime,
      toolCallId: entity.toolCallId,
      toolName: entity.toolName,
      toolArguments: entity.toolArguments != null 
          ? jsonDecode(entity.toolArguments!) as Map<String, dynamic>
          : null,
      toolResult: entity.toolResult,
      toolCalls: entity.toolCalls != null 
          ? (jsonDecode(entity.toolCalls!) as List)
              .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
              .toList()
          : null,
      status: entity.processingStatus,
    );
  }
  
  AiEmployeeMessageEntity _messageToEntity(AgentMessage message) {
    return AiEmployeeMessageEntity(
      uuid: message.id,
      employeeId: _employeeId,
      role: message.role,
      type: message.type,
      content: message.content,
      toolCallId: message.toolCallId,
      toolName: message.toolName,
      toolArguments: message.toolArguments != null 
          ? jsonEncode(message.toolArguments) 
          : null,
      toolResult: message.toolResult,
      toolCalls: message.toolCalls != null 
          ? jsonEncode(message.toolCalls!.map((tc) => tc.toMap()).toList())
          : null,
      processingStatus: message.status ?? 'none',
      createTime: message.createdAt,
      updateTime: DateTime.now(),
    );
  }
  
  // ===== 代理方法（智能透传） =====
  
  /// 发送消息
  Future<String> sendMessage(MessageInput input) async {
    final messageId = await _proxy.sendMessage(input);
    
    // 远程模式：从 AgentProxy 的待确认队列获取消息，避免重复创建
    if (_needCache) {
      try {
        // 从 AgentProxy 的待确认队列获取刚发送的消息
        final pendingMsg = _proxy.pendingMessages.firstWhere(
          (m) => m.id == messageId,
          orElse: () => throw Exception('Pending message not found: $messageId'),
        );
        
        // 转换为 AgentMessage 并添加到缓存
        final message = AgentMessage(
          id: pendingMsg.id,
          role: pendingMsg.role,
          type: pendingMsg.type,
          content: pendingMsg.content,
          createdAt: pendingMsg.createdAt,
          toolCallId: pendingMsg.toolCallId,
          toolName: pendingMsg.toolName,
          toolArguments: pendingMsg.toolArguments,
          toolResult: pendingMsg.toolResult,
          toolCalls: pendingMsg.toolCalls,
          metadata: pendingMsg.metadata,
          status: 'pending',  // 标记为待确认状态
        );
        
        _cachedMessages.add(message);
        _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        
        // 通知界面消息已更新
        _notifyMessagesChanged();
        
        // 异步保存到数据库，不等待
        final entity = _messageToEntity(message);
        _messageStore.addMessage(entity, deviceId: _deviceId).then((_) {
          // 保存成功
        }).catchError((e) {
          print('保存消息到本地数据库失败: $e');
        });
      } catch (e) {
        print('从待确认队列获取消息失败: $e');
        // 如果获取失败，仍然创建本地消息（降级处理）
        final localMessage = AgentMessage(
          id: messageId,
          role: input.role ?? 'user',
          type: input.type,
          content: input.content,
          createdAt: input.createdAt ?? DateTime.now(),
          toolCallId: input.toolCallId,
          toolName: input.toolName,
          toolArguments: input.toolArguments,
          toolResult: input.toolResult,
          metadata: input.metadata,
          status: 'pending',
        );
        
        _cachedMessages.add(localMessage);
        _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _notifyMessagesChanged();
        
        final entity = _messageToEntity(localMessage);
        _messageStore.addMessage(entity, deviceId: _deviceId).then((_) {
          // 保存成功
        }).catchError((e) {
          print('保存消息到本地数据库失败: $e');
        });
      }
    }
    
    return messageId;
  }
  
  /// 获取消息（别名方法）
  Future<List<AgentMessage>> getSessionMessages() => getMessages();
  
  /// 获取消息（强制刷新）
  ///
  /// 立即同步远程消息并返回最新数据
  Future<List<AgentMessage>> getMessagesForceRefresh() async {
    if (!_needCache) {
      return await _proxy.getSessionMessages();
    }
    
    await syncWithRemote();
    return _cachedMessages;
  }
  
  /// 中断当前处理
  Future<void> interrupt() => _proxy.interrupt();
  
  /// 撤回消息
  Future<void> revokeMessage(String messageId) async {
    await _proxy.revokeMessage(messageId);
    
    // 远程模式：从缓存中移除并通知
    if (_needCache) {
      _cachedMessages.removeWhere((m) => m.id == messageId);
      _notifyMessagesChanged();
    }
  }
  
  /// 获取当前权限请求
  AgentPermissionRequest? getPendingPermissionRequest() =>
      _proxy.getPendingPermissionRequest();
  
  /// 获取当前权限请求（异步版本）
  Future<AgentPermissionRequest?> getPendingPermissionRequestAsync() =>
      _proxy.getPendingPermissionRequestAsync();
  
  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    await _proxy.clearCurrentSession();
    
    // 远程模式：清空缓存并通知
    if (_needCache) {
      _cachedMessages.clear();
      await _messageStore.deleteMessages(_employeeId);
      _notifyMessagesChanged();
    }
  }
  
  /// 设置上下文
  Future<void> setContext(Map<String, dynamic> contextData) =>
      _proxy.setContext(contextData);
  
  /// 获取当前上下文
  Map<String, dynamic>? getCurrentContext() => _proxy.getCurrentContext();
  
  /// 设置Provider配置
  Future<void> setProvider(ProviderConfig providerConfig) =>
      _proxy.setProvider(providerConfig);
  
  /// 获取Provider配置
  ProviderConfig? getProviderConfig() => _proxy.getProviderConfig();
  
  /// 设置项目
  Future<void> setProject(ProjectData? projectData) =>
      _proxy.setProject(projectData);
  
  /// 获取当前项目UUID
  String? getCurrentProjectUuid() => _proxy.getCurrentProjectUuid();
  
  /// 注册工具
  void registerTool(AgentTool tool) => _proxy.registerTool(tool);
  
  /// 注册多个工具
  void registerTools(List<AgentTool> tools) => _proxy.registerTools(tools);
  
  /// 注销工具
  void unregisterTool(String name) => _proxy.unregisterTool(name);
  
  /// 获取已注册的工具
  List<Map<String, dynamic>> getRegisteredTools() => _proxy.getRegisteredTools();
  
  /// 响应权限请求
  Future<void> respondToPermission(String requestId, PermissionDecision decision) =>
      _proxy.respondToPermission(requestId, decision);
  
  /// 获取状态快照
  AgentStateSnapshot getStateSnapshot() => _proxy.getStateSnapshot();
  
  /// 获取状态快照（异步版本）
  Future<AgentStateSnapshot> getStateSnapshotAsync() =>
      _proxy.getStateSnapshotAsync();
  
  // ===== 基础属性 =====
  
  String get employeeId => _employeeId;
  String get deviceId => _deviceId;
  bool get isLocalMode => _proxy.isLocalMode;
  AgentStatus get status => _proxy.status;
  bool get isAlive => _proxy.isAlive;
  bool get isSending => _proxy.isSending;
  Stream<AgentStateSnapshot> get onStateChanged => _proxy.onStateChanged;
  
  // ===== 缓存相关属性（仅远程模式有效） =====
  
  /// 缓存状态流
  Stream<CacheState> get onCacheStateChanged {
    if (!_needCache) {
      // 本地模式返回空流
      return Stream.empty();
    }
    return _cacheStateController.stream;
  }
  
  /// 消息变更流（仅远程模式有效）
  ///
  /// 当消息缓存更新时，会通过此流通知监听者
  /// 包括：发送消息、同步远程消息、撤回消息等操作
  Stream<List<AgentMessage>> get onMessagesChanged {
    if (!_needCache) {
      // 本地模式返回空流
      return Stream.empty();
    }
    return _messagesController.stream;
  }
  
  /// 当前缓存状态
  CacheState get cacheState => _needCache ? _cacheState : CacheState.idle;
  
  /// 缓存消息数量
  int get cachedMessageCount => _needCache ? _cachedMessages.length : 0;
  
  /// 最后同步时间
  DateTime? get lastSyncTime => _needCache ? _lastSyncTime : null;
  
  /// 是否已同步
  bool get isSynced => _needCache && _lastSyncTime != null;
  
  /// 是否启用缓存
  bool get needCache => _needCache;
  
  // ===== 清理方法 =====
  
  /// 清除缓存
  Future<void> clearCache() async {
    if (!_needCache) return;
    
    _cachedMessages.clear();
    _lastSyncTime = null;
    await _messageStore.deleteMessages(_employeeId);
  }
  
  /// 释放资源
  Future<void> dispose() async {
    _isDisposed = true;
    
    if (_needCache) {
      await _cacheStateController.close();
      await _messagesController.close();
    }
  }
}
