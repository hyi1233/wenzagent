# CachedAgentProxy 消息加载问题分析

## 问题现象

1. 界面加载消息异常，不能加载到 agent 所有消息
2. 用户发送的消息存在重复的情况

## 问题分析

### 问题1：客户端调用时机问题

**问题代码：**

```dart
// controller.dart 第516-538行
Future<void> sendMessage(String content) async {
  if (_agentProxy != null) {
    _agentProxy!.sendMessage(agent.MessageInput(...));
  }
  
  chatInputController.clear();
  
  // ❌ 问题：立即加载消息，此时远程可能还没同步完成
  await _loadMessages();
  updateView();
}
```

**问题流程：**

```
T0: 用户发送消息 "你好"
T0: CachedAgentProxy.sendMessage() 调用
    - 调用 AgentProxy.sendMessage()
    - 添加到 _cachedMessages（状态: 'completed'）
    - 保存到本地数据库
T0: 立即调用 _loadMessages()
T0: 调用 getSessionMessages()
T0: 调用 syncWithRemote()
T0: 调用 AgentProxy.getSessionMessages()
    - 本地模式：直接从 Agent 获取
    - 远程模式：通过 RPC 获取
T0: 此时可能出现的问题：
    - Agent 可能还在处理消息，回复消息还没生成
    - 或者回复消息生成了但还没持久化
    - 或者网络延迟，远程消息还没同步到缓存
T0: _mergeMessages() 合并消息
T0: 更新视图
    - 可能只显示用户消息，没有 agent 回复
    - 或者显示部分消息（消息列表不完整）
```

### 问题2：消息合并逻辑问题

**当前合并逻辑：**

```dart
// cached_agent_proxy.dart 第194-231行
Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
  final mergedMap = <String, AgentMessage>{};
  
  // 1. 先添加所有本地消息
  for (final localMsg in _cachedMessages) {
    mergedMap[localMsg.id] = localMsg;
  }
  
  // 2. 合并远程消息
  for (final remoteMsg in remoteMessages) {
    if (mergedMap.containsKey(remoteMsg.id)) {
      final localMsg = mergedMap[remoteMsg.id]!;
      if (_isPendingSync(localMsg)) {
        continue;  // 保留本地的待同步消息
      } else {
        mergedMap[remoteMsg.id] = remoteMsg;  // 使用远程消息
      }
    } else {
      mergedMap[remoteMsg.id] = remoteMsg;
    }
  }
}

bool _isPendingSync(AgentMessage message) {
  return message.status == 'pending' || 
         message.metadata?['localOnly'] == true;
}
```

**问题场景：**

1. **用户发送消息（正常情况）：**
   - sendMessage 创建本地消息，状态: 'completed'
   - 添加到 _cachedMessages
   - syncWithRemote 获取远程消息，包含相同 ID 的消息
   - _mergeMessages 发现 ID 冲突，但本地消息不是 pending
   - 使用远程消息替换本地消息
   - **结果：正常，不会重复**

2. **用户发送消息（网络延迟情况）：**
   - sendMessage 创建本地消息，状态: 'completed'
   - 添加到 _cachedMessages 和本地数据库
   - syncWithRemote 获取远程消息，可能不包含这条消息（还没同步）
   - _mergeMessages 没有发现 ID 冲突
   - 保留本地消息
   - 后续定时同步获取到远程消息（包含这条消息）
   - _mergeMessages 发现 ID 冲突，使用远程消息替换
   - **结果：正常，不会重复**

3. **离线消息场景：**
   - 用户离线时发送消息，标记 `localOnly: true`, 状态: 'pending'
   - syncWithRemote 失败（离线）
   - _mergeMessages 保留本地消息
   - 用户上线后，syncWithRemote 成功
   - 如果远程还没有这条消息（真正离线），本地消息继续保留
   - 如果远程已经有这条消息（已同步），_isPendingSync 返回 true，继续保留本地的
   - **问题：如果远程已经有这条消息，应该使用远程的，但现在保留的是本地的 pending 消息**

### 问题3：AgentProxy 的 pendingMessageQueue 机制

AgentProxy 有自己的待确认消息队列：

```dart
// agent_proxy.dart
class AgentProxy {
  final List<PendingMessage> _pendingMessageQueue = [];
  
  Future<String> sendMessage(MessageInput input) async {
    final messageId = await _localAgent.sendMessage(input);
    final pendingMessage = _createPendingMessage(input, messageId);
    _pendingMessageQueue.add(pendingMessage);  // 添加到待确认队列
    return messageId;
  }
  
  Future<List<AgentMessage>> getSessionMessages() async {
    final messages = await _localAgent.getSessionMessages();
    _removeConfirmedMessages(messages);  // 从队列中移除已确认的
    return messages;
  }
}
```

这个机制主要用于跟踪消息发送状态，但 CachedAgentProxy 没有使用这个机制，而是使用自己的 _cachedMessages。

**潜在问题：**
- AgentProxy 和 CachedAgentProxy 有两套消息管理机制
- 可能导致状态不一致

## 解决方案

### 方案1：客户端延迟加载（推荐）

**修改 controller.dart：**

```dart
Future<void> sendMessage(String content) async {
  if (content.trim().isEmpty) return;

  try {
    if (_agentProxy != null) {
      // 发送消息
      _agentProxy!.sendMessage(agent.MessageInput(
        content: content,
        metadata: {'sessionId': sessionId},
      ));
    }

    // 清空输入
    chatInputController.clear();

    // ✅ 不立即加载消息，依赖 Agent 状态变更来触发加载
    // await _loadMessages();  // ❌ 移除立即加载
    // updateView();            // ❌ 移除立即更新
    
    // 消息加载由 _stateSubscription 监听器触发：
    // _stateSubscription = _agentProxy!.onStateChanged.listen((state) {
    //   _agentState = state;
    //   _reloadMessagesDebounced();  // ✅ 这里会触发消息加载
    // });
  } catch (e) {
    AILogger.error('发送消息失败', error: e);
    BotToast.showText(text: '发送失败: $e');
  }
}
```

**优点：**
- 简单直接
- 利用现有的状态监听机制
- 避免过早加载导致的消息不完整

**缺点：**
- 如果 Agent 状态变更不触发，可能导致消息不更新

### 方案2：优化 CachedAgentProxy 的 sendMessage（补充）

**修改 cached_agent_proxy.dart：**

```dart
Future<String> sendMessage(MessageInput input) async {
  final messageId = await _proxy.sendMessage(input);
  
  // 远程模式：不立即添加到缓存，让同步来处理
  if (_needCache) {
    // ✅ 方案A：不添加到缓存
    // 让 syncWithRemote 来加载消息
    // 优点：避免重复，确保消息状态一致
    // 缺点：用户需要等待同步才能看到自己发送的消息
    
    // ✅ 方案B：添加到缓存，但不标记为 pending
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
      status: 'completed',  // ✅ 状态为 completed，不是 pending
    );
    
    _cachedMessages.add(localMessage);
    _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    
    // 异步保存到数据库，不等待
    _messageStore.addMessage(_messageToEntity(localMessage), deviceId: _deviceId);
  }
  
  return messageId;
}
```

**优点：**
- 用户可以立即看到自己发送的消息
- 合并时会被远程消息替换，状态更完整

**缺点：**
- 如果远程消息还没同步，用户看到的可能是本地的消息状态

### 方案3：改进 _mergeMessages 逻辑

**修改 cached_agent_proxy.dart：**

```dart
Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
  if (!_needCache) return;
  
  final mergedMap = <String, AgentMessage>{};
  
  // ✅ 优先添加远程消息（状态更准确）
  for (final remoteMsg in remoteMessages) {
    mergedMap[remoteMsg.id] = remoteMsg;
  }
  
  // ✅ 然后添加本地待同步消息（远程没有的）
  for (final localMsg in _cachedMessages) {
    if (!mergedMap.containsKey(localMsg.id)) {
      // 远程没有，本地有 → 添加本地消息
      if (_isPendingSync(localMsg)) {
        // 真正的待同步消息（离线消息）
        mergedMap[localMsg.id] = localMsg;
      }
    }
    // 如果远程已经有这条消息，直接使用远程的
  }
  
  // 转换为列表并按时间排序
  final mergedMessages = mergedMap.values.toList();
  mergedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  
  _cachedMessages = mergedMessages;
}
```

**优点：**
- 优先使用远程消息，状态更准确
- 只保留真正的离线待同步消息

**缺点：**
- 逻辑更复杂

## 推荐方案

**综合方案：方案1 + 方案2B**

1. **客户端：** 发送消息后不立即加载，依赖状态监听器触发
2. **CachedAgentProxy：** sendMessage 后立即添加到缓存（状态: completed），让用户可以立即看到
3. **CachedAgentProxy：** _mergeMessages 优先使用远程消息

**实现：**

```dart
// controller.dart
Future<void> sendMessage(String content) async {
  if (content.trim().isEmpty) return;

  try {
    if (_agentProxy != null) {
      _agentProxy!.sendMessage(agent.MessageInput(
        content: content,
        metadata: {'sessionId': sessionId},
      ));
    }

    chatInputController.clear();
    
    // ✅ 不立即加载，依赖状态监听器
  } catch (e) {
    AILogger.error('发送消息失败', error: e);
    BotToast.showText(text: '发送失败: $e');
  }
}

// cached_agent_proxy.dart
Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
  if (!_needCache) return;
  
  final mergedMap = <String, AgentMessage>{};
  
  // ✅ 优先添加远程消息
  for (final remoteMsg in remoteMessages) {
    mergedMap[remoteMsg.id] = remoteMsg;
  }
  
  // ✅ 添加本地待同步消息（仅限离线消息）
  for (final localMsg in _cachedMessages) {
    if (!mergedMap.containsKey(localMsg.id) && _isPendingSync(localMsg)) {
      mergedMap[localMsg.id] = localMsg;
    }
  }
  
  final mergedMessages = mergedMap.values.toList();
  mergedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  
  _cachedMessages = mergedMessages;
}
```

## 额外建议

### 1. 改进状态监听

确保 Agent 状态变更时一定会触发消息重新加载：

```dart
// controller.dart
void _subscribeAgentState() {
  if (_agentProxy == null) return;

  _stateSubscription?.cancel();
  _stateSubscription = _agentProxy!.onStateChanged.listen((state) {
    _agentState = state;
    // ✅ 任何状态变更都触发消息重新加载
    _reloadMessagesDebounced();
  });
}
```

### 2. 添加消息加载重试机制

```dart
// controller.dart
Future<void> _loadMessages() async {
  try {
    if (_agentProxy == null) return;

    final messagesData = await _agentProxy!.getSessionMessages();
    
    // ... 处理消息 ...
    
    // ✅ 如果 agent 正在处理，延迟重新加载
    final state = _agentProxy!.getStateSnapshot();
    if (state.status == agent.AgentStatus.processing) {
      Future.delayed(Duration(seconds: 2), () {
        _reloadMessagesDebounced();
      });
    }
  } catch (e, stackTrace) {
    AILogger.error('加载消息失败', error: e, stackTrace: stackTrace);
  }
}
```

### 3. 添加消息去重逻辑

在客户端转换消息时，确保按 ID 去重：

```dart
// controller.dart
Future<void> _loadMessages() async {
  try {
    if (_agentProxy == null) return;

    final messagesData = await _agentProxy!.getSessionMessages();
    
    // ✅ 按 ID 去重
    final messageMap = <String, ChatMessage>{};
    
    for (final m in messagesData) {
      // ... 转换逻辑 ...
      
      final chatMessage = ChatMessage(...);
      messageMap[chatMessage.id] = chatMessage;  // ✅ 相同 ID 会被覆盖
    }
    
    _messages.clear();
    _messages.addAll(messageMap.values);
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    
    // ... 其他处理 ...
  } catch (e, stackTrace) {
    AILogger.error('加载消息失败', error: e, stackTrace: stackTrace);
  }
}
```

## 总结

**问题根源：**
1. 客户端在 sendMessage 后立即加载消息，导致消息不完整
2. CachedAgentProxy 的消息合并逻辑优先级不清晰

**解决方案：**
1. 客户端：发送消息后不立即加载，依赖状态监听器触发
2. CachedAgentProxy：sendMessage 后立即添加到缓存（状态: completed）
3. CachedAgentProxy：_mergeMessages 优先使用远程消息，只保留真正的离线待同步消息

**预期效果：**
- 用户发送消息后可以立即看到自己的消息
- Agent 回复生成后会自动加载并显示
- 不会出现消息重复
- 消息状态准确一致
