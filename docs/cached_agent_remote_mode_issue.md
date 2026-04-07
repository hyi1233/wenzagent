# CachedAgentProxy 远程模式问题分析

## 问题概述

用户反馈两个问题：
1. **回复消息后，没有通知界面刷新消息列表**
2. **客户端发送消息后，列表出现了2条相同的发送消息**

---

## 问题1：回复消息后没有通知界面刷新

### 根本原因

`CachedAgentProxy` 缺少消息变更通知机制。

**当前流程：**

```
远程Agent处理完成 
  ↓
AgentProxy 通过 onStateChanged 通知状态变更
  ↓
客户端调用 getSessionMessages()
  ↓
CachedAgentProxy.getMessages() 执行
  ↓
立即返回 _cachedMessages（旧数据）
  ↓
后台执行 syncWithRemote()
  ↓
更新 _cachedMessages
  ↓
❌ 没有通知界面
```

**问题代码：**

```dart:lib/src/agent/client/cached_agent_proxy.dart:139-145
// 非强制：先返回缓存，后台同步更新
// 不等待同步完成，用户立即看到缓存数据
syncWithRemote().catchError((e) {
  print('同步远程消息失败: $e');
});
```

后台同步完成后，`_cachedMessages` 已更新，但界面无法感知。

### 解决方案

**添加消息变更通知流：**

```dart
class CachedAgentProxy {
  // 消息变更通知流
  final StreamController<List<AgentMessage>> _messagesController = 
      StreamController<List<AgentMessage>>.broadcast();
  
  /// 消息变更流（仅远程模式有效）
  Stream<List<AgentMessage>> get onMessagesChanged {
    if (!_needCache) {
      return Stream.empty();
    }
    return _messagesController.stream;
  }
  
  Future<void> syncWithRemote() async {
    // ... 同步逻辑 ...
    
    // ✅ 同步完成后通知界面
    _messagesController.add(_cachedMessages);
  }
}
```

**客户端监听：**

```dart
// 客户端代码
void _subscribeMessages() {
  _messagesSubscription = _agentProxy!.onMessagesChanged.listen((messages) {
    // 消息缓存已更新，刷新界面
    _updateMessagesList(messages);
  });
}
```

---

## 问题2：发送消息后出现重复

### 根本原因

客户端同时从两个来源获取消息，导致重复：

1. **AgentProxy.pendingMessages** - 待确认消息队列
2. **CachedAgentProxy._cachedMessages** - 缓存的消息列表

**消息添加流程：**

```dart
// 1. AgentProxy.sendMessage() - 第一次添加
Future<String> sendMessage(MessageInput input) async {
  final messageId = const Uuid().v4();
  
  // ... RPC 调用 ...
  
  // ✅ 添加到待确认队列
  final pendingMessage = _createPendingMessage(inputWithId, messageId);
  _pendingMessageQueue.add(pendingMessage);  // 【第一次】
  
  return messageId;
}

// 2. CachedAgentProxy.sendMessage() - 第二次添加
Future<String> sendMessage(MessageInput input) async {
  final messageId = await _proxy.sendMessage(input);  // 已添加到队列
  
  if (_needCache) {
    // ✅ 又添加到缓存
    final localMessage = AgentMessage(id: messageId, ...);
    _cachedMessages.add(localMessage);  // 【第二次】
    
    // ✅ 还保存到数据库
    await _messageStore.addMessage(entity, deviceId: _deviceId);  // 【第三次】
  }
  
  return messageId;
}
```

**客户端合并逻辑：**

```dart
// 客户端可能的逻辑
void _loadMessages() async {
  final messages = await _agentProxy!.getSessionMessages();
  
  // ❌ 可能又合并了待确认消息
  final pending = _agentProxy!.pendingMessages;
  final allMessages = [...messages, ...pending];  // 导致重复
  
  // ...
}
```

### 解决方案

#### 方案A：CachedAgentProxy 统一管理（推荐）

**核心思想**：远程模式下，客户端只使用 `CachedAgentProxy._cachedMessages`，不使用 `AgentProxy.pendingMessages`。

**修改 CachedAgentProxy：**

```dart
Future<String> sendMessage(MessageInput input) async {
  // 远程模式下，不在 CachedAgentProxy 添加消息
  // 让 AgentProxy 添加到 pendingMessages，然后通过 getSessionMessages() 获取
  
  final messageId = await _proxy.sendMessage(input);
  
  // ❌ 不再添加到 _cachedMessages
  // if (_needCache) {
  //   _cachedMessages.add(localMessage);
  // }
  
  // ✅ 等待同步从远程获取（或者从 pendingMessages 获取）
  if (_needCache) {
    // 立即从 pendingMessages 获取刚发送的消息
    final pendingMsg = _proxy.pendingMessages.lastWhere(
      (m) => m.id == messageId,
      orElse: () => throw Exception('Pending message not found'),
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
      metadata: pendingMsg.metadata,
      status: 'pending',  // 标记为待确认
    );
    
    _cachedMessages.add(message);
    _messagesController.add(_cachedMessages);  // 通知界面
  }
  
  return messageId;
}

Future<List<AgentMessage>> getSessionMessages() async {
  if (!_needCache) {
    return await _proxy.getSessionMessages();
  }
  
  // 远程模式：合并 pending 和远程消息
  final remoteMessages = await _proxy.getSessionMessages();
  
  // ✅ 从缓存中移除已确认的消息
  final confirmedIds = remoteMessages.map((m) => m.id).toSet();
  _cachedMessages.removeWhere((m) => 
    confirmedIds.contains(m.id) && m.status != 'pending'
  );
  
  // ✅ 合并远程消息
  for (final remoteMsg in remoteMessages) {
    final index = _cachedMessages.indexWhere((m) => m.id == remoteMsg.id);
    if (index >= 0) {
      // 已存在，更新为远程消息
      _cachedMessages[index] = remoteMsg;
    } else {
      // 不存在，添加
      _cachedMessages.add(remoteMsg);
    }
  }
  
  // 按时间排序
  _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  
  // ✅ 通知界面
  _messagesController.add(_cachedMessages);
  
  return _cachedMessages;
}
```

**客户端修改：**

```dart
// ✅ 只使用 getSessionMessages()，不使用 pendingMessages
Future<void> _loadMessages() async {
  final messages = await _agentProxy!.getSessionMessages();
  
  // ❌ 不要合并 pendingMessages
  // final pending = _agentProxy!.pendingMessages;
  // messages = [...messages, ...pending];
  
  _messages.assignAll(messages);
  updateView();
}
```

#### 方案B：改进合并逻辑

**修改 `_mergeMessages` 去重逻辑：**

```dart
Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
  if (!_needCache) return;
  
  final mergedMap = <String, AgentMessage>{};
  
  // ✅ 1. 优先使用远程消息（状态更准确）
  for (final remoteMsg in remoteMessages) {
    mergedMap[remoteMsg.id] = remoteMsg;
  }
  
  // ✅ 2. 添加本地待确认消息（远程可能还没有）
  for (final localMsg in _cachedMessages) {
    if (!mergedMap.containsKey(localMsg.id)) {
      // 远程没有这个消息ID，可能是刚发送的
      // 检查是否在待确认队列中
      final isPending = _proxy.pendingMessageIds.contains(localMsg.id);
      if (isPending) {
        // 保留本地的待确认消息
        mergedMap[localMsg.id] = localMsg;
      }
    }
  }
  
  final mergedMessages = mergedMap.values.toList();
  mergedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  
  _cachedMessages = mergedMessages;
}
```

---

## 完整解决方案

### 1. 添加消息变更通知

```dart
// lib/src/agent/client/cached_agent_proxy.dart

class CachedAgentProxy {
  // 消息变更通知流
  final StreamController<List<AgentMessage>> _messagesController = 
      StreamController<List<AgentMessage>>.broadcast();
  
  /// 消息变更流（仅远程模式有效）
  Stream<List<AgentMessage>> get onMessagesChanged {
    if (!_needCache) {
      return Stream.empty();
    }
    return _messagesController.stream;
  }
  
  Future<void> syncWithRemote() async {
    if (!_needCache) return;
    
    _updateCacheState(CacheState.syncing);
    
    try {
      final remoteMessages = await _proxy.getSessionMessages();
      await _mergeMessages(remoteMessages);
      await _updateLocalCache();
      
      _lastSyncTime = DateTime.now();
      _updateCacheState(CacheState.idle);
      
      // ✅ 通知界面消息已更新
      _messagesController.add(_cachedMessages);
    } catch (e) {
      _updateCacheState(CacheState.error);
      print('同步远程消息失败: $e');
    }
  }
  
  Future<void> dispose() async {
    _isDisposed = true;
    
    if (_needCache) {
      await _cacheStateController.close();
      await _messagesController.close();  // ✅ 清理消息流
    }
  }
}
```

### 2. 避免消息重复

```dart
// lib/src/agent/client/cached_agent_proxy.dart

Future<String> sendMessage(MessageInput input) async {
  final messageId = await _proxy.sendMessage(input);
  
  // 远程模式：从 pendingMessages 获取刚发送的消息
  if (_needCache) {
    // ✅ 从 AgentProxy 的待确认队列获取
    final pendingMsg = _proxy.pendingMessages.lastWhere(
      (m) => m.id == messageId,
      orElse: () => throw Exception('Pending message not found: $messageId'),
    );
    
    // ✅ 转换并添加到缓存
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
      metadata: pendingMsg.metadata,
      status: 'pending',
    );
    
    _cachedMessages.add(message);
    _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    
    // ✅ 通知界面
    _messagesController.add(_cachedMessages);
    
    // 异步保存到数据库
    final entity = _messageToEntity(message);
    _messageStore.addMessage(entity, deviceId: _deviceId).catchError((e) {
      print('保存消息到本地数据库失败: $e');
    });
  }
  
  return messageId;
}

Future<List<AgentMessage>> getSessionMessages() async {
  if (!_needCache) {
    return await _proxy.getSessionMessages();
  }
  
  // 远程模式：从远程获取并合并
  final remoteMessages = await _proxy.getSessionMessages();
  
  // ✅ 更新缓存中的消息状态
  for (final remoteMsg in remoteMessages) {
    final index = _cachedMessages.indexWhere((m) => m.id == remoteMsg.id);
    if (index >= 0) {
      // 更新为远程消息（状态更准确）
      _cachedMessages[index] = remoteMsg;
    } else {
      // 添加新消息
      _cachedMessages.add(remoteMsg);
    }
  }
  
  // 按时间排序
  _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  
  // ✅ 通知界面
  _messagesController.add(_cachedMessages);
  
  return _cachedMessages;
}
```

### 3. 客户端使用示例

```dart
// 客户端代码示例

class ChatViewController {
  CachedAgentProxy? _agentProxy;
  StreamSubscription? _messagesSubscription;
  StreamSubscription? _stateSubscription;
  
  void _subscribeAgentChanges() {
    if (_agentProxy == null) return;
    
    // ✅ 监听状态变更
    _stateSubscription = _agentProxy!.onStateChanged.listen((state) {
      _agentState = state;
      // 状态变更时也可能需要重新加载消息
      if (state.status == AgentStatus.idle) {
        _loadMessages();
      }
    });
    
    // ✅ 监听消息缓存变更
    _messagesSubscription = _agentProxy!.onMessagesChanged.listen((messages) {
      _updateMessagesList(messages);
    });
  }
  
  Future<void> sendMessage(String content) async {
    if (_agentProxy == null) return;
    
    try {
      await _agentProxy!.sendMessage(
        MessageInput(
          content: content,
          type: 'text',
        ),
      );
      
      // ✅ 不需要立即调用 _loadMessages()
      // sendMessage 会触发 onMessagesChanged 通知
      // 远程回复会触发 onStateChanged 通知
      
    } catch (e) {
      print('发送消息失败: $e');
    }
  }
  
  Future<void> _loadMessages() async {
    if (_agentProxy == null) return;
    
    final messages = await _agentProxy!.getSessionMessages();
    _updateMessagesList(messages);
  }
  
  void _updateMessagesList(List<AgentMessage> messages) {
    _messages.assignAll(messages);
    updateView();
  }
  
  void dispose() {
    _messagesSubscription?.cancel();
    _stateSubscription?.cancel();
  }
}
```

---

## 总结

### 问题1：回复消息后没有通知

**原因**：后台同步完成后，缓存已更新，但没有通知界面。

**解决**：添加 `onMessagesChanged` 流，同步完成后通知界面。

### 问题2：发送消息后出现重复

**原因**：客户端同时从 `AgentProxy.pendingMessages` 和 `CachedAgentProxy._cachedMessages` 获取消息，导致重复。

**解决**：
1. CachedAgentProxy 从 AgentProxy.pendingMessages 获取刚发送的消息，避免重复创建
2. 客户端只使用 `getSessionMessages()`，不手动合并 `pendingMessages`

### 核心改进

1. **添加消息变更通知**：`onMessagesChanged` 流
2. **统一消息来源**：客户端只从 `CachedAgentProxy` 获取消息
3. **智能合并**：根据 ID 去重，优先使用远程消息状态
4. **状态管理**：待确认消息标记为 `status: 'pending'`

### 预期效果

- ✅ 用户发送消息后立即在界面显示
- ✅ Agent 回复后自动更新界面
- ✅ 不会出现消息重复
- ✅ 消息状态准确一致
- ✅ 支持离线查看
