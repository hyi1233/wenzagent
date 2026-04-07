# 清空会话逻辑修复总结

## 问题描述

清空会话时，没有真正删除本地缓存消息或远程消息。

## 问题根源

`MessageStoreService.deleteMessages()` 方法不支持传递 `deviceId` 参数，导致无法正确删除指定设备的消息。

### 调用链分析

**本地模式**：
```
CachedAgentProxy.clearCurrentSession()
  ↓
AgentProxy.clearCurrentSession()
  ↓
AgentImpl.clearCurrentSession()
  ↓
PersistentChatAdapter.clearCurrentSession()
  ↓
deleteMessagesCallback(employeeId)
  ↓
MessageStoreServiceImpl.deleteMessages(employeeId)  // ❌ 缺少 deviceId 参数
  ↓
MessageStore.deleteBySession(_deviceId, employeeId)  // ❌ 使用错误的 deviceId
```

**远程模式**：
```
CachedAgentProxy.clearCurrentSession()
  ↓ (第一步)
AgentProxy.clearCurrentSession()  // RPC 调用远程清空
  ↓ (第二步)
MessageStoreServiceImpl.deleteMessages(_employeeId)  // ❌ 缺少 deviceId 参数
```

### 关键问题

1. **CachedAgentProxy** 有自己的 `_deviceId` 成员变量
2. **CachedAgentProxy** 在保存消息时传递了 `deviceId`：
   - `_messageStore.addMessage(entity, deviceId: _deviceId)`
   - `_messageStore.updateMessage(entity, deviceId: _deviceId)`
3. **但在删除时没有传递 `deviceId`**：
   - `_messageStore.deleteMessages(_employeeId)` ❌

4. **MessageStoreServiceImpl** 使用构造函数时的 `_deviceId`，可能与消息存储时的 `deviceId` 不一致

## 修复方案

### 1. 修改 `MessageStoreService` 接口

```dart
/// 删除会话的所有消息
///
/// [deviceId] 设备ID，为null时使用实例默认deviceId
/// [employeeId] 员工ID
Future<void> deleteMessages(String employeeId, {String? deviceId});
```

### 2. 修改 `MessageStoreServiceImpl` 实现

```dart
@override
Future<void> deleteMessages(String employeeId, {String? deviceId}) async {
  await _store.deleteBySession(deviceId ?? _deviceId, employeeId);
}
```

### 3. 修改 `CachedAgentProxy.clearCurrentSession()`

```dart
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
```

### 4. 修改 `CachedAgentProxy.clearCache()`

```dart
/// 清除缓存
Future<void> clearCache() async {
  if (!_needCache) return;
  
  _cachedMessages.clear();
  _lastSyncTime = null;
  // 使用正确的 deviceId 删除消息
  await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
}
```

## 正确的清空逻辑

### 本地模式

```
CachedAgentProxy.clearCurrentSession()
  ↓ (透传)
AgentProxy.clearCurrentSession()
  ↓
AgentImpl.clearCurrentSession()
  ↓
PersistentChatAdapter.clearCurrentSession()
  ↓
1. 清空内存：memoryManager.clearSession()
2. 清空数据库：deleteMessagesCallback(employeeId)
  ↓
MessageStoreServiceImpl.deleteMessages(employeeId)
  ↓
MessageStore.deleteBySession(deviceId, employeeId)
  ↓
删除 Hive 中的消息实体和索引
```

### 远程模式

```
CachedAgentProxy.clearCurrentSession()
  ↓
第一步：清空远程会话
  AgentProxy.clearCurrentSession()
    ↓
  RPC 调用远程 Agent.clearCurrentSession()
  ↓
第二步：清空本地缓存
  _cachedMessages.clear()
  _messageStore.deleteMessages(_employeeId, deviceId: _deviceId)
    ↓
  MessageStore.deleteBySession(_deviceId, _employeeId)
    ↓
  删除本地 Hive 缓存
  ↓
第三步：通知UI更新
  _notifyMessagesChanged()
```

## 验证要点

### 1. 本地模式验证

- ✅ 内存消息被清空
- ✅ Hive 数据库消息被删除
- ✅ 索引被删除

### 2. 远程模式验证

- ✅ 远程 Agent 会话被清空
- ✅ 本地缓存被清空
- ✅ 本地 Hive 数据库被删除
- ✅ UI 收到更新通知

## 测试建议

```dart
test('清空会话 - 远程模式', () async {
  // 1. 创建远程 AgentProxy
  final proxy = AgentProxy.remote(...);
  
  // 2. 包装为 CachedAgentProxy
  final cachedProxy = CachedAgentProxy(
    proxy: proxy,
    messageStore: messageStore,
    deviceId: 'test-device',
    employeeId: 'test-employee',
  );
  
  // 3. 发送消息
  await cachedProxy.sendMessage(MessageInput(content: 'test'));
  
  // 4. 验证本地缓存有消息
  final messagesBefore = await cachedProxy.getMessages();
  expect(messagesBefore.length, greaterThan(0));
  
  // 5. 清空会话
  await cachedProxy.clearCurrentSession();
  
  // 6. 验证本地缓存已清空
  final messagesAfter = await cachedProxy.getMessages();
  expect(messagesAfter.length, equals(0));
  
  // 7. 验证数据库已清空
  final dbMessages = await messageStore.getMessages('test-employee');
  expect(dbMessages.length, equals(0));
});
```

## 相关文件

- `lib/src/service/message_store_service.dart` - 消息存储服务接口
- `lib/src/persistence/stores/message_store.dart` - Hive 存储实现
- `lib/src/agent/client/cached_agent_proxy.dart` - 缓存代理
- `lib/src/agent/client/agent_proxy.dart` - Agent 代理
- `lib/src/agent/impl/agent_impl.dart` - Agent 实现
- `lib/src/agent/adapter/persistent_chat_adapter.dart` - 持久化适配器

## 修复日期

2026-04-07
