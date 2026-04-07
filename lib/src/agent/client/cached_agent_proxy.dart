import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

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
  
  /// 同步锁
  Completer<void>? _syncCompleter;

  /// 事件订阅
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  StreamSubscription<AgentStateSnapshot>? _stateSubscription;
  
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
      
      // 3. 初始化事件监听
      _initializeEventListeners();
      
      _updateCacheState(CacheState.idle);
    } catch (e) {
      _updateCacheState(CacheState.error);
      // 同步失败不影响本地缓存使用
      print('初始化同步失败: $e');
    }
  }
  
  /// 初始化事件监听
  void _initializeEventListeners() {
    if (!_needCache) return;
    
    print('[CachedAgentProxy] 初始化事件监听...');
    
    // 监听Agent事件
    _eventSubscription = _proxy.onEvent.listen((event) {
      _handleAgentEvent(event);
    });
    
    // 监听状态变更
    _stateSubscription = _proxy.onStateChanged.listen((state) {
      _handleStateChange(state);
    });
  }
  
  /// 处理Agent事件
  void _handleAgentEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final data = event['data'] as Map<String, dynamic>? ?? {};
    final employeeId = event['employeeId'] as String?;
    
    // 只处理当前员工的事件
    if (employeeId != null && employeeId != _employeeId) {
      return;
    }
    
    print('[CachedAgentProxy] 收到事件: $type');
    
    switch (type) {
      case 'messageStatusChanged':
        _handleMessageStatusChanged(data);
        break;
      case 'agentStatusChanged':
        _handleAgentStatusChanged(data);
        break;
      case 'toolCallStart':
      case 'toolCallResult':
        if (type != null) {
          _handleToolEvent(type, data);
        }
        break;
      case 'messageReplied':
        _handleMessageReplied(data);
        break;
      case 'messageQueued':
        _handleMessageQueued(data);
        break;
      case 'messageProcessing':
        _handleMessageProcessing(data);
        break;
    }
  }
  
  /// 处理消息状态变更事件
  void _handleMessageStatusChanged(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;
    final status = data['status'] as String?;
    
    if (messageId == null || status == null) return;
    
    print('[CachedAgentProxy] 消息状态变更: $messageId -> $status');
    
    // 更新本地缓存中的消息状态
    _updateMessageStatus(messageId, status);
    
    // 如果是完成或失败状态，触发消息列表查询
    if (status == 'completed' || status == 'failed' || status == 'interrupted') {
      // 延迟查询，确保远程消息已持久化
      Future.delayed(const Duration(milliseconds: 500), () {
        _syncMessagesFromRemote();
      });
    }
  }
  
  /// 处理Agent状态变更事件
  void _handleAgentStatusChanged(Map<String, dynamic> data) {
    final status = data['status'] as String?;
    print('[CachedAgentProxy] Agent状态变更: $status');
    
    // 如果是空闲状态，可能意味着消息处理完成
    if (status == 'idle') {
      // 触发消息同步
      _syncMessagesFromRemote();
    }
  }
  
  /// 处理工具事件
  void _handleToolEvent(String eventType, Map<String, dynamic> data) {
    print('[CachedAgentProxy] 工具事件: $eventType');
    
    // 工具事件可能会影响消息内容，触发消息同步
    if (eventType == 'toolCallResult') {
      Future.delayed(const Duration(milliseconds: 300), () {
        _syncMessagesFromRemote();
      });
    }
  }
  
  /// 处理消息被回复事件
  void _handleMessageReplied(Map<String, dynamic> data) {
    final originalMessageId = data['originalMessageId'] as String?;
    final replyMessageId = data['replyMessageId'] as String?;
    
    if (originalMessageId == null || replyMessageId == null) return;
    
    print('[CachedAgentProxy] 消息被回复: $originalMessageId -> $replyMessageId');
    
    // 更新原消息的metadata，添加回复信息
    final index = _cachedMessages.indexWhere((m) => m.id == originalMessageId);
    if (index != -1) {
      final message = _cachedMessages[index];
      final updatedMessage = message.copyWith(
        metadata: {
          ...?message.metadata,
          'replyMessageId': replyMessageId,
          'replied': true,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _cachedMessages[index] = updatedMessage;
      _notifyMessagesChanged();
      _updateMessageInDatabase(updatedMessage);
    }
    
    // 同步消息列表以获取最新的回复内容
    Future.delayed(const Duration(milliseconds: 300), () {
      _syncMessagesFromRemote();
    });
  }
  
  /// 处理队列中消息事件
  void _handleMessageQueued(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;
    final queuePosition = data['queuePosition'] as int?;
    
    if (messageId == null) return;
    
    print('[CachedAgentProxy] 消息进入队列: $messageId, 位置: $queuePosition');
    
    // 更新消息状态为queued
    final index = _cachedMessages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      final message = _cachedMessages[index];
      final updatedMessage = message.copyWith(
        status: 'queued',
        metadata: {
          ...?message.metadata,
          'queuePosition': queuePosition,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _cachedMessages[index] = updatedMessage;
      _notifyMessagesChanged();
      _updateMessageInDatabase(updatedMessage);
    }
  }
  
  /// 处理消息处理中事件
  void _handleMessageProcessing(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;
    
    if (messageId == null) return;
    
    print('[CachedAgentProxy] 消息开始处理: $messageId');
    
    // 更新消息状态为processing
    _updateMessageStatus(messageId, 'processing');
  }
  
  /// 处理状态变更
  void _handleStateChange(AgentStateSnapshot state) {
    print('[CachedAgentProxy] 状态变更: ${state.status}');
    
    // 根据状态决定是否触发消息同步
    if (state.status == AgentStatus.idle) {
      // Agent空闲时，同步消息
      _syncMessagesFromRemote();
    }
  }
  
  /// 从远程同步消息
  Future<void> _syncMessagesFromRemote() async {
    if (_isDisposed || !_needCache) return;
    
    try {
      print('[CachedAgentProxy] 开始从远程同步消息...');
      
      // 1. 查询远程消息列表
      final allRemoteMessages = await _proxy.getSessionMessages();
      
      // 2. 限制只保留最近20条消息（按时间倒序取前20条）
      allRemoteMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final remoteMessages = allRemoteMessages.take(20).toList();
      remoteMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      
      // 3. 根据ID合并消息，取最新更新消息
      await _mergeMessages(remoteMessages);
      
      // 4. 更新本地缓存
      await _updateLocalCache();
      
      // 5. 通知界面
      _notifyMessagesChanged();
      
      print('[CachedAgentProxy] 消息同步完成，共 ${_cachedMessages.length} 条消息');
    } catch (e) {
      print('[CachedAgentProxy] 同步远程消息失败: $e');
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
      return _applyPagination(messages, limit, offset);
    }
    
    // 远程模式：
    if (forceRefresh) {
      // 强制刷新：立即同步远程消息
      await syncWithRemote();
    } else {
      // 非强制：先返回缓存，后台同步
      // 每次都触发后台同步，确保获取最新的assistant消息
      syncWithRemote().catchError((e) {
        print('[CachedAgentProxy] 后台同步失败: $e');
      });
    }
    
    return _applyPagination(_cachedMessages, limit, offset);
  }
  
  /// 同步远程消息（仅远程模式有效）
  Future<void> syncWithRemote() async {
    if (_isDisposed) return;
    
    // 本地模式不需要同步
    if (!_needCache) {
      return;
    }
    
    // 防止并发同步
    if (_syncCompleter != null) {
      return _syncCompleter!.future;
    }
    
    _syncCompleter = Completer<void>();
    _updateCacheState(CacheState.syncing);
    
    try {
      // 调用统一的同步逻辑
      await _syncMessagesFromRemote();
      
      _lastSyncTime = DateTime.now();
      _updateCacheState(CacheState.idle);
      
      _syncCompleter!.complete();
    } catch (e) {
      _updateCacheState(CacheState.error);
      _syncCompleter!.completeError(e);
    } finally {
      _syncCompleter = null;
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
  
  /// 合并本地和远程消息（基于ID和updateTime）
  Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
    if (!_needCache) return;
    
    print('[CachedAgentProxy] 开始合并消息:');
    print('  - 本地消息数: ${_cachedMessages.length}');
    print('  - 远程消息数: ${remoteMessages.length}');
    
    // 创建本地消息Map，key为消息ID
    final localMap = <String, AgentMessage>{};
    for (final msg in _cachedMessages) {
      localMap[msg.id] = msg;
      print('  - 本地消息ID: ${msg.id}, role: ${msg.role}, status: ${msg.status}');
    }
    
    // 创建远程消息Map，key为消息ID
    final remoteMap = <String, AgentMessage>{};
    for (final msg in remoteMessages) {
      remoteMap[msg.id] = msg;
      print('  - 远程消息ID: ${msg.id}, role: ${msg.role}, status: ${msg.status}');
    }
    
    // 合并策略：基于ID和updateTime
    final mergedMessages = <AgentMessage>[];
    final processedIds = <String>{};
    
    // 1. 处理所有远程消息（优先使用远程的）
    for (final remoteMsg in remoteMessages) {
      processedIds.add(remoteMsg.id);
      
      if (localMap.containsKey(remoteMsg.id)) {
        // 双方都有，使用最新的（基于updateTime）
        final localMsg = localMap[remoteMsg.id]!;
        final localTime = _getMessageUpdateTime(localMsg);
        final remoteTime = _getMessageUpdateTime(remoteMsg);
        
        print('[CachedAgentProxy] 消息ID ${remoteMsg.id} 同时存在于本地和远程');
        print('  - 本地updateTime: $localTime');
        print('  - 远程updateTime: $remoteTime');
        
        if (remoteTime.isAfter(localTime)) {
          // 远程更新，使用远程的
          mergedMessages.add(remoteMsg);
          print('  -> 使用远程消息（更新）');
        } else {
          // 本地更新或相同，使用本地的
          mergedMessages.add(localMsg);
          print('  -> 使用本地消息（更新或相同）');
        }
      } else {
        // 只有远程有，添加远程的
        mergedMessages.add(remoteMsg);
        print('[CachedAgentProxy] 添加远程消息（本地没有）: ${remoteMsg.id}');
      }
    }
    
    // 2. 处理本地有但远程没有的消息
    final deletedMessageIds = <String>[];
    for (final localMsg in _cachedMessages) {
      if (!processedIds.contains(localMsg.id)) {
        print('[CachedAgentProxy] 本地消息ID ${localMsg.id} 不在远程消息中');
        print('  - 消息状态: ${localMsg.status}');
        print('  - 消息角色: ${localMsg.role}');
        print('  - 创建时间: ${localMsg.createdAt}');
        
        if (_isLocalPendingMessage(localMsg)) {
          // 本地待同步消息，保留
          mergedMessages.add(localMsg);
          print('  -> 保留本地待同步消息');
        } else if (_shouldKeepLocalMessage(localMsg)) {
          // 需要保留的本地消息
          mergedMessages.add(localMsg);
          print('  -> 保留本地消息（可能远程还没同步）');
        } else {
          // 远程已删除，标记为删除
          deletedMessageIds.add(localMsg.id);
          print('  -> 丢弃本地消息（远程已删除）');
        }
      }
    }
    
    // 删除本地数据库中已删除的消息
    if (deletedMessageIds.isNotEmpty) {
      print('[CachedAgentProxy] 从本地数据库删除 ${deletedMessageIds.length} 条消息');
      await _deleteMessagesFromDatabase(deletedMessageIds);
    }
    
    // 3. 按时间排序
    mergedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    
    print('[CachedAgentProxy] 合并完成，最终消息数: ${mergedMessages.length}');
    for (final msg in mergedMessages) {
      print('  - 最终消息ID: ${msg.id}, role: ${msg.role}');
    }
    
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
  
  /// 生成消息ID（标准UUID格式）
  String _generateMessageId() {
    return const Uuid().v4();
  }
  
  /// 获取消息的更新时间
  DateTime _getMessageUpdateTime(AgentMessage message) {
    // 优先使用metadata中的updateTime
    if (message.metadata?['updateTime'] != null) {
      final updateTime = message.metadata!['updateTime'];
      if (updateTime is String) {
        return DateTime.parse(updateTime);
      } else if (updateTime is DateTime) {
        return updateTime;
      }
    }
    
    // 其次使用createdAt
    return message.createdAt;
  }
  
  /// 判断是否是本地待同步消息
  bool _isLocalPendingMessage(AgentMessage message) {
    // 1. 状态为pending或failed（发送中或失败，需要重试）
    if (message.status == 'pending' || message.status == 'failed') {
      return true;
    }
    
    // 2. metadata标记为localOnly（还未确认远程已接收）
    if (message.metadata?['localOnly'] == true) {
      return true;
    }
    
    return false;
  }
  
  /// 判断是否应该保留本地消息（当远程没有时）
  bool _shouldKeepLocalMessage(AgentMessage message) {
    // 1. 如果消息状态是pending或failed，应该保留（等待重试）
    if (message.status == 'pending' || message.status == 'failed') {
      return true;
    }
    
    // 2. 如果有本地修改标记
    if (message.metadata?['locallyModified'] == true) {
      return true;
    }
    
    // 3. 如果消息非常新（最近5分钟内创建），可能远程还没同步
    final now = DateTime.now();
    final messageTime = message.createdAt;
    final diff = now.difference(messageTime);
    if (diff.inMinutes < 5) {
      return true;
    }
    
    // 4. 默认不保留（远程已删除）
    return false;
  }
  
  /// 添加消息到缓存
  void _addMessageToCache(AgentMessage message) {
    // 检查是否已存在
    final existingIndex = _cachedMessages.indexWhere((m) => m.id == message.id);
    if (existingIndex != -1) {
      // 已存在，更新
      _cachedMessages[existingIndex] = message;
    } else {
      // 不存在，添加
      _cachedMessages.add(message);
    }
    
    // 排序
    _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    
    // 通知
    _notifyMessagesChanged();
  }
  
  /// 更新消息状态
  void _updateMessageStatus(String messageId, String status) {
    final index = _cachedMessages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      final message = _cachedMessages[index];
      final updatedMessage = message.copyWith(
        status: status,
        metadata: {
          ...?message.metadata,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _cachedMessages[index] = updatedMessage;
      _notifyMessagesChanged();
      _updateMessageInDatabase(updatedMessage);
    }
  }
  
  /// 保存消息到数据库
  Future<void> _saveMessageToDatabase(AgentMessage message) async {
    try {
      final entity = _messageToEntity(message);
      await _messageStore.addMessage(entity, deviceId: _deviceId);
    } catch (e) {
      print('保存消息到数据库失败: $e');
    }
  }
  
  /// 更新数据库中的消息
  Future<void> _updateMessageInDatabase(AgentMessage message) async {
    try {
      final entity = _messageToEntity(message);
      await _messageStore.updateMessage(entity, deviceId: _deviceId);
    } catch (e) {
      print('更新数据库消息失败: $e');
    }
  }
  
  /// 从数据库删除消息（硬删除）
  Future<void> _deleteMessagesFromDatabase(List<String> messageIds) async {
    try {
      // 使用硬删除，直接从数据库删除消息
      for (final messageId in messageIds) {
        await _messageStore.hardDeleteMessage(messageId, deviceId: _deviceId);
      }
      print('[CachedAgentProxy] 成功删除 ${messageIds.length} 条消息');
    } catch (e) {
      print('[CachedAgentProxy] 删除消息失败: $e');
    }
  }
  
  /// 应用分页
  List<AgentMessage> _applyPagination(
    List<AgentMessage> messages, 
    int? limit, 
    int? offset,
  ) {
    var result = messages;
    
    if (offset != null && offset > 0) {
      result = result.skip(offset).toList();
    }
    
    if (limit != null && limit > 0) {
      result = result.take(limit).toList();
    }
    
    return result;
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
      metadata: {'updateTime': entity.updateTime.toIso8601String()},
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
      updateTime: _getMessageUpdateTime(message),
    );
  }
  
  // ===== 代理方法（智能透传） =====
  
  /// 发送消息（优化版：事件驱动）
  Future<String> sendMessage(MessageInput input) async {
    // 1. 客户端生成UUID作为消息ID
    final messageId = input.id ?? _generateMessageId();
    print('[CachedAgentProxy] 客户端生成消息ID: $messageId');
    
    // 2. 创建本地消息（立即可见）
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
      metadata: {
        ...?input.metadata,
        'localOnly': true,  // 标记为本地消息
        'updateTime': DateTime.now().toIso8601String(),
      },
      status: 'pending',
    );
    
    print('[CachedAgentProxy] 创建本地消息: ID=${localMessage.id}, role=${localMessage.role}');
    
    // 3. 添加到本地缓存（立即可见）
    if (_needCache) {
      _addMessageToCache(localMessage);
      // 异步保存到数据库
      _saveMessageToDatabase(localMessage);
    }
    
    // 4. 发送到远程（异步）
    try {
      // 传递生成的messageId，确保远程使用相同的ID
      final inputWithId = input.copyWith(id: messageId);
      print('[CachedAgentProxy] 发送消息到远程: ID=$messageId');
      
      final returnedId = await _proxy.sendMessage(inputWithId);
      
      print('[CachedAgentProxy] AgentProxy返回的消息ID: $returnedId');
      
      // 🔑 验证返回的ID是否一致
      if (returnedId != messageId) {
        print('[CachedAgentProxy] ⚠️ 严重错误：AgentProxy返回了不同的ID！期望: $messageId, 实际: $returnedId');
        // 强制使用客户端生成的ID
      }
      
      // 发送成功，更新状态
      if (_needCache) {
        _updateMessageStatus(messageId, 'sent');
        print('[CachedAgentProxy] 消息状态更新为sent: ID=$messageId');
      }
    } catch (e) {
      // 发送失败，更新状态
      if (_needCache) {
        _updateMessageStatus(messageId, 'failed');
        print('[CachedAgentProxy] 消息发送失败: ID=$messageId, error: $e');
      }
      rethrow;
    }
    
    return messageId;
  }
  
  /// 获取消息（别名方法）
  Future<List<AgentMessage>> getSessionMessages() => getMessages();
  
  /// 获取消息（强制刷新）
  ///
  /// 立即同步远程消息并返回最新数据
  /// 建议在以下场景使用：
  /// - 监听到Agent状态变化时（processing -> idle）
  /// - 收到消息状态变更通知时
  /// - 需要确保数据最新时
  Future<List<AgentMessage>> getMessagesForceRefresh() async {
    if (!_needCache) {
      return await _proxy.getSessionMessages();
    }
    
    await syncWithRemote();
    return _cachedMessages;
  }
  
  /// 主动同步远程消息（用于监听状态变化时调用）
  ///
  /// 建议在监听 `onStateChanged` 流时调用此方法：
  /// ```dart
  /// proxy.onStateChanged.listen((state) {
  ///   if (state.status == AgentStatus.idle) {
  ///     proxy.syncOnStateChange();
  ///   }
  /// });
  /// ```
  Future<void> syncOnStateChange() async {
    if (!_needCache) return;
    await syncWithRemote();
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
    // 第一步：清空远程会话
    await _proxy.clearCurrentSession();
    
    // 第二步：清空本地缓存（远程模式）
    if (_needCache) {
      _cachedMessages.clear();
      // 使用正确的 deviceId 删除消息
      await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
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
    // 使用正确的 deviceId 删除消息
    await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
  }
  
  /// 释放资源
  Future<void> dispose() async {
    _isDisposed = true;
    
    // 取消事件订阅
    await _eventSubscription?.cancel();
    await _stateSubscription?.cancel();
    
    if (_needCache) {
      await _cacheStateController.close();
      await _messagesController.close();
    }
  }
}
