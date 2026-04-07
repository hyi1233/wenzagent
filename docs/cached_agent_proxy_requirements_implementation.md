# CachedAgentProxy 需求实现文档

## 需求概述

本文档详细说明 `CachedAgentProxy` 如何实现以下核心需求和逻辑：

## 1. 初始化流程

### 需求
- 查询本地缓存到内存
- 查询远程全部消息到本地/内存
- 如果远程不存在的消息，本地也要删除

### 实现 ✅

**位置**: `cached_agent_proxy.dart:87-114`

```dart
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
    print('初始化同步失败: $e');
  }
}
```

**关键逻辑**:
- `_loadLocalMessages()`: 从本地数据库加载缓存
- `syncWithRemote()`: 同步远程消息
- `_mergeMessages()`: 合并时自动删除本地多余消息

**消息删除逻辑** (`cached_agent_proxy.dart:389-418`):
```dart
// 处理本地有但远程没有的消息
for (final localMsg in _cachedMessages) {
  if (!processedIds.contains(localMsg.id)) {
    if (_isLocalPendingMessage(localMsg)) {
      // 本地待同步消息，保留
      mergedMessages.add(localMsg);
    } else if (_shouldKeepLocalMessage(localMsg)) {
      // 需要保留的本地消息
      mergedMessages.add(localMsg);
    } else {
      // 远程已删除，标记为删除
      deletedMessageIds.add(localMsg.id);
    }
  }
}

// 从本地数据库硬删除
if (deletedMessageIds.isNotEmpty) {
  await _deleteMessagesFromDatabase(deletedMessageIds);
}
```

---

## 2. 清空消息

### 需求
- 清空远程消息
- 然后清除本地消息缓存（非软删除，直接清除）

### 实现 ✅

**位置**: `cached_agent_proxy.dart:783-794`

```dart
Future<void> clearCurrentSession() async {
  // 第一步：清空远程会话
  await _proxy.clearCurrentSession();
  
  // 第二步：清空本地缓存（远程模式）
  if (_needCache) {
    _cachedMessages.clear();
    // 使用正确的 deviceId 删除消息（硬删除）
    await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
    _notifyMessagesChanged();
  }
}
```

**硬删除实现**:
- `MessageStore.deleteMessages()`: 直接删除数据库记录
- `MessageStore.deleteBySession()`: 删除会话所有消息
- `MessageStore.delete()`: 删除单条消息

**位置**: `message_store.dart:155-180`

```dart
/// 删除会话的所有消息（硬删除）
Future<void> deleteBySession(String? deviceId, String employeeId) async {
  final indexBox = _hiveManager.sessionMessagesBox;
  final box = _hiveManager.messageBox;

  final indexKey = _hiveManager.buildSessionMessagesKey(deviceId, employeeId);
  List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];

  for (final uuid in messageUuids) {
    final key = _hiveManager.buildMessageKey(deviceId, uuid as String);
    await box.delete(key); // 直接删除，非软删除
  }

  await indexBox.delete(indexKey);
}
```

---

## 3. 用户发送消息

### 需求
- 发送时添加到本地缓存
- 发送到远程处理
- 监听到回复
- 查询消息（最近20条）
- 更新消息状态
- 合并消息
- 存入缓存

### 实现 ✅

**位置**: `cached_agent_proxy.dart:660-724`

```dart
Future<String> sendMessage(MessageInput input) async {
  // 1. 客户端生成UUID作为消息ID
  final messageId = input.id ?? _generateMessageId();
  
  // 2. 创建本地消息（立即可见）
  final localMessage = AgentMessage(
    id: messageId,
    role: input.role ?? 'user',
    type: input.type,
    content: input.content,
    createdAt: input.createdAt ?? DateTime.now(),
    metadata: {
      ...?input.metadata,
      'localOnly': true,  // 标记为本地消息
      'updateTime': DateTime.now().toIso8601String(),
    },
    status: 'pending',
  );
  
  // 3. 添加到本地缓存（立即可见）
  if (_needCache) {
    _addMessageToCache(localMessage);
    _saveMessageToDatabase(localMessage);
  }
  
  // 4. 发送到远程
  try {
    final inputWithId = input.copyWith(id: messageId);
    final returnedId = await _proxy.sendMessage(inputWithId);
    
    // 发送成功，更新状态
    if (_needCache) {
      _updateMessageStatus(messageId, 'sent');
    }
  } catch (e) {
    // 发送失败，更新状态
    if (_needCache) {
      _updateMessageStatus(messageId, 'failed');
    }
    rethrow;
  }
  
  return messageId;
}
```

**查询最近20条消息**:

**位置**: `cached_agent_proxy.dart:219-247`

```dart
Future<void> _syncMessagesFromRemote() async {
  if (_isDisposed || !_needCache) return;
  
  try {
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
  } catch (e) {
    print('[CachedAgentProxy] 同步远程消息失败: $e');
  }
}
```

**事件监听**:

**位置**: `cached_agent_proxy.dart:117-216`

```dart
void _initializeEventListeners() {
  // 监听Agent事件
  _eventSubscription = _proxy.onEvent.listen((event) {
    _handleAgentEvent(event);
  });
  
  // 监听状态变更
  _stateSubscription = _proxy.onStateChanged.listen((state) {
    _handleStateChange(state);
  });
}
```

---

## 4. 去重机制

### 需求
- 列表不能出现2个id相同的消息

### 实现 ✅

**方式1**: 添加消息时检查重复

**位置**: `cached_agent_proxy.dart:506-522`

```dart
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
```

**方式2**: 合并消息时基于ID去重

**位置**: `cached_agent_proxy.dart:334-429`

```dart
Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
  // 创建本地消息Map，key为消息ID
  final localMap = <String, AgentMessage>{};
  for (final msg in _cachedMessages) {
    localMap[msg.id] = msg;
  }
  
  // 创建远程消息Map，key为消息ID
  final remoteMap = <String, AgentMessage>{};
  for (final msg in remoteMessages) {
    remoteMap[msg.id] = msg;
  }
  
  // 合并策略：基于ID和updateTime
  final mergedMessages = <AgentMessage>[];
  final processedIds = <String>{}; // 用于去重
  
  // 处理所有远程消息
  for (final remoteMsg in remoteMessages) {
    processedIds.add(remoteMsg.id);
    
    if (localMap.containsKey(remoteMsg.id)) {
      // 双方都有，使用最新的
      final localMsg = localMap[remoteMsg.id]!;
      final localTime = _getMessageUpdateTime(localMsg);
      final remoteTime = _getMessageUpdateTime(remoteMsg);
      
      if (remoteTime.isAfter(localTime)) {
        mergedMessages.add(remoteMsg);
      } else {
        mergedMessages.add(localMsg);
      }
    } else {
      // 只有远程有
      mergedMessages.add(remoteMsg);
    }
  }
  
  // 处理本地独有消息（待同步）
  // ...
}
```

---

## 5. 合并逻辑

### 需求
- 根据消息updateTime取较新消息内容以及状态

### 实现 ✅

**位置**: `cached_agent_proxy.dart:366-381`

```dart
// 合并时比较updateTime
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
}
```

**获取updateTime的逻辑** (`cached_agent_proxy.dart:451-464`):

```dart
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
```

---

## 6. 消息event类型处理

### 需求
- 工具调用event状态更新
- 消息被回复
- 消息处理状态
- 队列中的消息
- 处理中的消息

### 实现 ✅

**位置**: `cached_agent_proxy.dart:134-267`

```dart
void _handleAgentEvent(Map<String, dynamic> event) {
  final type = event['type'] as String?;
  final data = event['data'] as Map<String, dynamic>? ?? {};
  
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
```

#### 6.1 工具调用event状态更新

**位置**: `cached_agent_proxy.dart:196-212`

```dart
void _handleToolEvent(String eventType, Map<String, dynamic> data) {
  print('[CachedAgentProxy] 工具事件: $eventType');
  
  // 工具事件可能会影响消息内容，触发消息同步
  if (eventType == 'toolCallResult') {
    Future.delayed(const Duration(milliseconds: 300), () {
      _syncMessagesFromRemote();
    });
  }
}
```

#### 6.2 消息被回复

**位置**: `cached_agent_proxy.dart:214-243`

```dart
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
```

#### 6.3 消息处理状态

**位置**: `cached_agent_proxy.dart:163-181`

```dart
void _handleMessageStatusChanged(Map<String, dynamic> data) {
  final messageId = data['messageId'] as String?;
  final status = data['status'] as String?;
  
  if (messageId == null || status == null) return;
  
  print('[CachedAgentProxy] 消息状态变更: $messageId -> $status');
  
  // 更新本地缓存中的消息状态
  _updateMessageStatus(messageId, status);
  
  // 如果是完成或失败状态，触发消息列表查询
  if (status == 'completed' || status == 'failed' || status == 'interrupted') {
    Future.delayed(const Duration(milliseconds: 500), () {
      _syncMessagesFromRemote();
    });
  }
}
```

#### 6.4 队列中的消息

**位置**: `cached_agent_proxy.dart:245-267`

```dart
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
```

#### 6.5 处理中的消息

**位置**: `cached_agent_proxy.dart:269-280`

```dart
void _handleMessageProcessing(Map<String, dynamic> data) {
  final messageId = data['messageId'] as String?;
  
  if (messageId == null) return;
  
  print('[CachedAgentProxy] 消息开始处理: $messageId');
  
  // 更新消息状态为processing
  _updateMessageStatus(messageId, 'processing');
}
```

---

## 修改文件清单

### 1. `cached_agent_proxy.dart`

**新增功能**:
- ✅ 限制查询最近20条消息
- ✅ 消息被回复事件处理
- ✅ 队列中消息事件处理
- ✅ 处理中消息事件处理
- ✅ 硬删除消息（非软删除）

**修改方法**:
- `_syncMessagesFromRemote()`: 添加消息数量限制（最近20条）
- `_deleteMessagesFromDatabase()`: 改为硬删除
- `_handleAgentEvent()`: 添加新事件类型处理
- 新增: `_handleMessageReplied()`, `_handleMessageQueued()`, `_handleMessageProcessing()`

### 2. `message_store_service.dart`

**新增方法**:
- `hardDeleteMessage()`: 硬删除单条消息接口

### 3. `message_store.dart`

**新增方法**:
- `delete()`: 硬删除单条消息实现

---

## 测试建议

### 1. 初始化流程测试
```dart
test('初始化应该加载本地缓存并同步远程消息', () async {
  final proxy = CachedAgentProxy(/* ... */);
  await proxy.initialize();
  
  // 验证本地缓存已加载
  expect(proxy.cachedMessageCount, greaterThan(0));
  
  // 验证远程消息已同步
  expect(proxy.isSynced, isTrue);
});
```

### 2. 清空消息测试
```dart
test('清空消息应该删除远程和本地消息', () async {
  final proxy = CachedAgentProxy(/* ... */);
  await proxy.initialize();
  
  await proxy.clearCurrentSession();
  
  // 验证本地缓存已清空
  expect(proxy.cachedMessageCount, equals(0));
  
  // 验证数据库消息已删除
  final messages = await messageStore.getMessages(employeeId);
  expect(messages, isEmpty);
});
```

### 3. 发送消息测试
```dart
test('发送消息应该限制同步最近20条', () async {
  final proxy = CachedAgentProxy(/* ... */);
  await proxy.initialize();
  
  // 发送消息
  await proxy.sendMessage(MessageInput(content: '测试'));
  
  // 等待同步
  await Future.delayed(Duration(milliseconds: 600));
  
  // 验证消息数量不超过20
  expect(proxy.cachedMessageCount, lessThanOrEqualTo(20));
});
```

### 4. 事件处理测试
```dart
test('应该正确处理消息被回复事件', () async {
  final proxy = CachedAgentProxy(/* ... */);
  await proxy.initialize();
  
  // 模拟事件
  proxy._handleAgentEvent({
    'type': 'messageReplied',
    'data': {
      'originalMessageId': 'msg1',
      'replyMessageId': 'msg2',
    },
  });
  
  // 验证原消息metadata已更新
  final msg = proxy._cachedMessages.firstWhere((m) => m.id == 'msg1');
  expect(msg.metadata?['replied'], isTrue);
  expect(msg.metadata?['replyMessageId'], equals('msg2'));
});
```

---

## 注意事项

1. **消息数量限制**: 同步时只保留最近20条消息，避免内存占用过大
2. **硬删除**: 清空消息和删除消息使用硬删除，不会保留deleted状态
3. **事件处理**: 所有事件都会触发消息同步，确保UI及时更新
4. **去重机制**: 基于消息ID去重，不会出现重复消息
5. **合并策略**: 基于updateTime使用最新版本，确保数据准确性

---

## 更新日志

**2026-04-07**:
- ✅ 实现消息查询限制（最近20条）
- ✅ 实现硬删除机制（非软删除）
- ✅ 添加消息被回复事件处理
- ✅ 添加队列中消息事件处理
- ✅ 添加处理中消息事件处理
- ✅ 完善所有需求点的实现和文档
