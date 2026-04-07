# Proxy 缓存 deviceId 修复方案

## 问题描述

在远程模式下，`CachedAgentProxy` 缓存消息时使用了错误的 `deviceId`，导致消息被缓存到错误的通道。

### 根本原因

1. **MessageStoreService 设计问题**：`MessageStoreService` 在构造时接收一个默认的 `deviceId`，所有消息操作都使用这个默认值。
2. **CachedAgentProxy 使用错误**：远程 `AgentProxy` 应该使用远程设备的 `deviceId` 来缓存消息，但实际使用了本地设备的 `deviceId`。

### 问题场景

```
本地设备: device-local
远程设备: device-remote

1. 用户在 device-local 上创建远程 AgentProxy
2. CachedAgentProxy 使用 device-local 的 deviceId 缓存消息 ❌
3. 消息被存储到 device-local 的存储通道
4. 但查询时使用 device-remote 查询 → 找不到消息 ❌
```

## 解决方案

### 1. 修改 MessageStoreService 接口

为 `addMessage` 和 `updateMessage` 方法添加可选的 `deviceId` 参数：

```dart
/// 消息存储服务接口
abstract class MessageStoreService {
  // ... 其他方法 ...

  /// 添加消息
  Future<AiEmployeeMessageEntity> addMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,  // 新增：可选的 deviceId 参数
  });

  /// 批量添加消息
  Future<void> addMessages(
    List<AiEmployeeMessageEntity> messages, {
    String? deviceId,  // 新增：可选的 deviceId 参数
  });

  /// 更新消息
  Future<void> updateMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,  // 新增：可选的 deviceId 参数
  });

  // ... 其他方法 ...
}
```

### 2. 修改 MessageStoreServiceImpl 实现

使用传入的 `deviceId` 参数，如果未提供则使用默认值：

```dart
@override
Future<AiEmployeeMessageEntity> addMessage(
  AiEmployeeMessageEntity message, {
  String? deviceId,
}) async {
  // 使用传入的 deviceId，如果未提供则使用默认的 _deviceId
  await _store.addWithDeviceId(deviceId ?? _deviceId, message);
  _notifyChange(MessageChangeType.added, message);
  return message;
}

@override
Future<void> updateMessage(
  AiEmployeeMessageEntity message, {
  String? deviceId,
}) async {
  final updated = message.copyWith(
    updateTime: DateTime.now(),
  );
  await _store.updateWithDeviceId(deviceId ?? _deviceId, updated);
  _notifyChange(MessageChangeType.updated, updated);
}
```

### 3. 修改 CachedAgentProxy 使用正确的 deviceId

在缓存消息时传入正确的 `deviceId`：

```dart
class CachedAgentProxy {
  final String _deviceId;  // 这是 proxy 的 deviceId（可能是远程设备的）
  final String _employeeId;
  
  // ... 其他代码 ...

  /// 发送消息
  Future<String> sendMessage(MessageInput input) async {
    final messageId = await _proxy.sendMessage(input);
    
    if (_needCache) {
      final entity = _messageToEntity(localMessage);
      // 使用 _deviceId（远程设备的ID）而不是本地设备的ID
      await _messageStore.addMessage(entity, deviceId: _deviceId);
    }
    
    return messageId;
  }

  /// 更新本地缓存
  Future<void> _updateLocalCache() async {
    if (!_needCache) return;
    
    for (final message in _cachedMessages) {
      final entity = _messageToEntity(message);
      // 使用正确的 deviceId
      await _messageStore.updateMessage(entity, deviceId: _deviceId);
    }
  }
}
```

## 修复前后对比

### 修复前（错误）

```
CachedAgentProxy (远程)
  ├─ _deviceId = "device-remote"
  ├─ _messageStore._deviceId = "device-local"
  └─ addMessage(entity)
      └─ 使用 "device-local" 存储 ❌

消息存储位置: device-local:employeeId
查询位置: device-remote:employeeId
结果: 找不到消息 ❌
```

### 修复后（正确）

```
CachedAgentProxy (远程)
  ├─ _deviceId = "device-remote"
  ├─ _messageStore._deviceId = "device-local"
  └─ addMessage(entity, deviceId: "device-remote")
      └─ 使用 "device-remote" 存储 ✅

消息存储位置: device-remote:employeeId
查询位置: device-remote:employeeId
结果: 正确找到消息 ✅
```

## 影响范围

### 正面影响

1. **远程消息缓存正确**：远程 AgentProxy 的消息现在会缓存到正确的通道。
2. **离线查看正常**：用户可以正确查看远程设备的离线消息。
3. **本地模式不受影响**：本地 AgentProxy 使用默认 deviceId，行为不变。

### 向后兼容

- `deviceId` 参数是可选的，默认行为不变。
- 本地设备的代码不需要修改，使用默认 deviceId。

## 数据存储结构

消息存储使用复合键：`deviceId:messageId`

```dart
// MessageStore 中的键构建
final key = _hiveManager.buildMessageKey(deviceId, uuid);

// 索引构建
final indexKey = _hiveManager.buildSessionMessagesKey(deviceId, employeeId);
```

### 示例

```
本地设备 (device-local):
  - 消息键: device-local:msg-001, device-local:msg-002
  - 索引键: device-local:employee-123

远程设备 (device-remote):
  - 消息键: device-remote:msg-101, device-remote:msg-102
  - 索引键: device-remote:employee-123
```

## 测试建议

### 测试场景1：远程消息缓存

1. 在设备A上创建本地 Agent
2. 在设备B上远程访问该 Agent
3. 发送消息
4. 验证消息缓存到正确的 deviceId 通道
5. 离线后能正确查看消息

### 测试场景2：本地消息持久化

1. 在设备A上创建本地 Agent
2. 发送消息
3. 验证消息缓存到本地 deviceId 通道
4. 重启应用后能正确加载消息

### 测试场景3：多设备切换

1. 在设备A上访问远程设备B的 Agent
2. 切换到访问远程设备C的 Agent
3. 验证两个远程 Agent 的消息分别缓存到各自的通道

## 相关文件

- `lib/src/service/message_store_service.dart` - 消息存储服务接口
- `lib/src/agent/client/cached_agent_proxy.dart` - 缓存代理实现
- `lib/src/persistence/stores/message_store.dart` - 消息存储实现
- `lib/src/device/impl/device_client_impl.dart` - 设备客户端实现

## 总结

通过为 `MessageStoreService` 的添加和更新方法添加可选的 `deviceId` 参数，允许 `CachedAgentProxy` 在缓存远程消息时指定正确的 `deviceId`，从而确保消息被存储到正确的通道，解决了远程模式下消息缓存错误的问题。
