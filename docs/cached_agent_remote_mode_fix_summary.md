# CachedAgentProxy 远程模式修复总结

## 修复内容

### 问题1：回复消息后没有通知界面刷新

**修复方案**：添加 `onMessagesChanged` 消息变更通知流

**修改内容**：
1. 新增 `_messagesController` 流控制器
2. 新增 `onMessagesChanged` 流属性
3. 在所有消息变更操作后触发通知：
   - `sendMessage()` - 发送消息后通知
   - `syncWithRemote()` - 同步远程消息后通知
   - `revokeMessage()` - 撤回消息后通知
   - `clearCurrentSession()` - 清空会话后通知

**代码变更**：

```dart
// 1. 添加消息变更流控制器
final StreamController<List<AgentMessage>> _messagesController = 
    StreamController<List<AgentMessage>>.broadcast();

// 2. 暴露消息变更流
Stream<List<AgentMessage>> get onMessagesChanged {
  if (!_needCache) return Stream.empty();
  return _messagesController.stream;
}

// 3. 通知方法
void _notifyMessagesChanged() {
  if (!_needCache || _isDisposed) return;
  _messagesController.add(List.unmodifiable(_cachedMessages));
}

// 4. 在消息变更后调用
Future<void> syncWithRemote() async {
  // ... 同步逻辑 ...
  _notifyMessagesChanged();  // ✅ 通知界面
}

// 5. 清理资源
Future<void> dispose() async {
  if (_needCache) {
    await _messagesController.close();  // ✅ 关闭流
  }
}
```

### 问题2：发送消息后出现重复

**修复方案**：从 `AgentProxy.pendingMessages` 获取消息，避免重复创建

**修改内容**：
1. `sendMessage()` 从 `_proxy.pendingMessages` 获取刚发送的消息
2. 改进 `_mergeMessages()` 优先使用远程消息，智能去重
3. 客户端只需使用 `getSessionMessages()`，不手动合并

**代码变更**：

```dart
// 1. sendMessage 改进
Future<String> sendMessage(MessageInput input) async {
  final messageId = await _proxy.sendMessage(input);
  
  if (_needCache) {
    // ✅ 从 AgentProxy 的待确认队列获取
    final pendingMsg = _proxy.pendingMessages.firstWhere(
      (m) => m.id == messageId,
    );
    
    // 转换并添加到缓存
    final message = AgentMessage(
      id: pendingMsg.id,
      // ... 其他字段 ...
      status: 'pending',  // 标记为待确认
    );
    
    _cachedMessages.add(message);
    _notifyMessagesChanged();  // ✅ 通知界面
  }
  
  return messageId;
}

// 2. _mergeMessages 改进
Future<void> _mergeMessages(List<AgentMessage> remoteMessages) async {
  final mergedMap = <String, AgentMessage>{};
  
  // ✅ 优先添加远程消息（状态更准确）
  for (final remoteMsg in remoteMessages) {
    mergedMap[remoteMsg.id] = remoteMsg;
  }
  
  // ✅ 添加本地待同步消息（仅限远程没有的）
  for (final localMsg in _cachedMessages) {
    if (!mergedMap.containsKey(localMsg.id) && _isPendingSync(localMsg)) {
      mergedMap[localMsg.id] = localMsg;
    }
  }
  
  _cachedMessages = mergedMap.values.toList()..sort(...);
}
```

## 文件变更

### 修改的文件

1. **lib/src/agent/client/cached_agent_proxy.dart**
   - 新增 `_messagesController` 流控制器
   - 新增 `onMessagesChanged` 流属性
   - 新增 `_notifyMessagesChanged()` 方法
   - 修改 `sendMessage()` 从待确认队列获取消息
   - 修改 `_mergeMessages()` 优先使用远程消息
   - 修改 `syncWithRemote()` 添加通知
   - 修改 `revokeMessage()` 添加通知
   - 修改 `clearCurrentSession()` 添加通知
   - 修改 `dispose()` 清理消息流
   - 新增 `getMessagesForceRefresh()` 方法

### 新增的文档

1. **docs/cached_agent_remote_mode_issue.md** - 问题分析文档
2. **docs/cached_agent_proxy_usage_guide.md** - 客户端使用指南
3. **docs/cached_agent_remote_mode_fix_summary.md** - 修复总结（本文档）

### 新增的测试

1. **test/cached_agent_remote_mode_test.dart** - 修复验证测试

## 客户端使用指南

### 核心要点

1. **订阅消息变更**：
   ```dart
   _messagesSubscription = proxy.onMessagesChanged.listen((messages) {
     _messages.assignAll(messages);
   });
   ```

2. **不要手动合并 pendingMessages**：
   ```dart
   // ❌ 错误：会导致重复
   final all = [...messages, ...proxy.pendingMessages];
   
   // ✅ 正确：直接使用
   final messages = await proxy.getSessionMessages();
   ```

3. **发送消息后不需要手动刷新**：
   ```dart
   await proxy.sendMessage(input);
   // ✅ onMessagesChanged 会自动通知
   ```

### 完整示例

```dart
class ChatViewController extends GetxController {
  CachedAgentProxy? _agentProxy;
  StreamSubscription? _messagesSubscription;
  StreamSubscription? _stateSubscription;
  final RxList<AgentMessage> messages = <AgentMessage>[].obs;
  
  @override
  void onInit() {
    super.onInit();
    _initAgentProxy();
  }
  
  @override
  void onClose() {
    _messagesSubscription?.cancel();
    _stateSubscription?.cancel();
    super.onClose();
  }
  
  Future<void> _initAgentProxy() async {
    final proxy = await deviceClient.getOrCreateAgentProxy(employeeId);
    _agentProxy = proxy;
    
    // 订阅状态变更
    _stateSubscription = proxy.onStateChanged.listen((state) {
      // Agent 状态变更处理
    });
    
    // 订阅消息变更（远程模式）
    if (proxy.needCache) {
      _messagesSubscription = proxy.onMessagesChanged.listen((updatedMessages) {
        messages.assignAll(updatedMessages);
      });
    }
    
    // 初始加载
    final messagesData = await proxy.getSessionMessages();
    messages.assignAll(messagesData);
  }
  
  Future<void> sendMessage(String content) async {
    await _agentProxy!.sendMessage(MessageInput(content: content));
    // ✅ 不需要手动刷新，onMessagesChanged 会自动更新
  }
  
  Future<void> revokeMessage(String messageId) async {
    await _agentProxy!.revokeMessage(messageId);
    // ✅ 不需要手动刷新
  }
  
  Future<void> clearSession() async {
    await _agentProxy!.clearCurrentSession();
    // ✅ 不需要手动刷新
  }
}
```

## 测试验证

运行测试：

```bash
cd d:\project\GitHub\wenzagent
dart test test/cached_agent_remote_mode_test.dart
```

测试结果：✅ 所有测试通过（8个测试）

## 兼容性

- ✅ 本地模式：`onMessagesChanged` 返回空流，不影响现有逻辑
- ✅ 远程模式：`onMessagesChanged` 返回有效的消息变更流
- ✅ 向后兼容：现有代码无需修改，但建议使用新 API

## 注意事项

1. **本地模式**：`onMessagesChanged` 返回空流，需要手动加载消息
2. **远程模式**：`onMessagesChanged` 返回有效流，建议订阅自动更新
3. **资源清理**：记得取消订阅，避免内存泄漏
4. **不要合并 pendingMessages**：会导致消息重复

## 下一步建议

1. 更新客户端代码，订阅 `onMessagesChanged` 流
2. 移除手动合并 `pendingMessages` 的逻辑
3. 移除发送消息后手动刷新的代码
4. 测试远程模式下的消息更新流程

## 相关文档

- [问题分析](./cached_agent_remote_mode_issue.md)
- [使用指南](./cached_agent_proxy_usage_guide.md)
- [改进说明](./cached_agent_proxy_improvement.md)
- [问题分析旧版](./cached_agent_proxy_issue_analysis.md)
