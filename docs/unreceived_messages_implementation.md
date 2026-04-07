# 未接收消息机制实现文档

## 概述

本次实现完成了未接收消息机制，支持设备跟踪消息接收状态，避免重复接收已处理的消息。

## 核心功能

### 1. 消息接收状态跟踪

在 `AgentImpl` 中添加了消息接收状态跟踪机制：

```dart
/// 消息接收状态跟踪
/// Map<messageId, Map<receiverDeviceId, updateTime>>
final Map<String, Map<String, DateTime>> _messageReceiveStatus = {};
```

- 记录每个设备接收了哪些消息
- 记录接收时的消息更新时间
- 当消息状态更新时，自动更新 updateTime，使设备可以重新接收

### 2. 未接收消息查询

```dart
Future<List<AgentMessage>> getUnreceivedMessages({
  required String receiverDeviceId,
}) async {
  // 1. 获取所有消息
  // 2. 过滤出该设备未接收的消息
  // 3. 检查消息是否已更新（updateTime比接收时间更新）
}
```

**查询逻辑**：
- 消息未被任何设备接收过 → 未接收消息
- 该设备未接收过此消息 → 未接收消息
- 消息已更新（updateTime > 接收时间）→ 未接收消息

### 3. 标记消息为已接收

```dart
Future<void> markMessagesAsReceived({
  required String receiverDeviceId,
  required List<MessageReceiveInfo> messageReceiveList,
}) async {
  // 记录消息接收状态
  // Map<messageId, Map<receiverDeviceId, updateTime>>
}
```

## 客户端实现

### CachedAgentProxy 初始化流程

```dart
Future<void> initialize() async {
  if (!_needCache) {
    // 本地模式：只加载本地缓存
    await _loadLocalMessagesByUserCount();
    return;
  }

  // 远程模式
  // 1. 加载本地缓存（按用户消息计数）
  await _loadLocalMessagesByUserCount();

  // 2. 同步远程消息
  if (_cachedMessages.isEmpty) {
    // 本地缓存为空，使用基础同步方法
    await _syncMessagesFromRemoteBasic();
  } else {
    // 本地缓存不为空，使用未接收消息机制
    await _syncMessagesFromRemote();
  }
}
```

### 基础同步方法

用于初始化时本地缓存为空的情况：

```dart
Future<void> _syncMessagesFromRemoteBasic() async {
  // 1. 查询远程消息（按用户消息计数）
  final remoteMessages = await _proxy.getSessionMessagesByUserCount(
    userMessageLimit: 20,
  );

  // 2. 清空本地缓存
  // 3. 将远程消息存入缓存
  // 4. 标记消息为已接收
}
```

### 未接收消息同步方法

用于后续同步：

```dart
Future<void> _syncMessagesFromRemote() async {
  // 1. 查询远程未接收消息
  final unreceivedMessages = await _proxy.getUnreceivedMessages(
    receiverDeviceId: _deviceId,
  );

  // 2. 合并消息（去重，根据updateTime更新）
  await _mergeUnreceivedMessages(unreceivedMessages);

  // 3. 更新接收状态
  await _markMessagesAsReceived(unreceivedMessages);
}
```

## 消息更新时间机制

### 数据库层面

当消息状态更新时，自动更新 `updateTime`：

```dart
// message_store.dart
Future<void> updateStatus(String? deviceId, String uuid, String status, {String? error}) async {
  final msg = await find(deviceId, uuid);
  if (msg != null) {
    final updated = msg.copyWith(
      processingStatus: status,
      processingError: error,
      updateTime: DateTime.now(), // ✅ 自动更新
    );
    await updateWithDeviceId(deviceId, updated);
  }
}
```

### 消息转换

将 `updateTime` 放入消息的 `metadata` 中：

```dart
// cached_agent_proxy.dart
AgentMessage _entityToMessage(AiEmployeeMessageEntity entity) {
  return AgentMessage(
    id: entity.uuid,
    role: entity.role,
    type: entity.type,
    content: entity.content,
    createdAt: entity.createTime,
    status: entity.processingStatus,
    metadata: {'updateTime': entity.updateTime.toIso8601String()}, // ✅ 存入metadata
  );
}
```

### 获取更新时间

从 `metadata` 中获取 `updateTime`：

```dart
// agent_impl.dart
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

## 新增RPC方法

### 1. getSessionMessagesPaged

分页获取会话消息：

```dart
Future<List<AgentMessage>> getSessionMessagesPaged({
  int pageSize = 20,
  int offset = 0,
})
```

### 2. getUnreceivedMessages

获取未接收消息：

```dart
Future<List<AgentMessage>> getUnreceivedMessages({
  required String receiverDeviceId,
})
```

### 3. markMessagesAsReceived

标记消息为已接收：

```dart
Future<void> markMessagesAsReceived({
  required String receiverDeviceId,
  required List<MessageReceiveInfo> messageReceiveList,
})
```

## 数据结构

### MessageReceiveInfo

```dart
class MessageReceiveInfo {
  final String messageId;
  final DateTime updateTime;

  const MessageReceiveInfo({
    required this.messageId,
    required this.updateTime,
  });
}
```

### GetUnreceivedMessagesRequest

```dart
class GetUnreceivedMessagesRequest {
  final String employeeId;
  final String receiverDeviceId;
}
```

### MarkMessagesAsReceivedRequest

```dart
class MarkMessagesAsReceivedRequest {
  final String employeeId;
  final String receiverDeviceId;
  final List<MessageReceiveInfo> messageReceiveList;
}
```

### GetSessionMessagesPagedRequest

```dart
class GetSessionMessagesPagedRequest {
  final String employeeId;
  final int pageSize;
  final int offset;
}
```

## 工作流程

### 初始化流程（远程模式）

```
1. 加载本地缓存（按用户消息计数）
   ↓
2. 检查缓存是否为空
   ↓
   ├─ 为空 → 基础同步
   │         - 查询最近20条用户消息时间段内的所有消息
   │         - 清空本地缓存
   │         - 存入缓存
   │         - 标记为已接收
   │
   └─ 不为空 → 未接收消息同步
              - 查询未接收消息
              - 合并消息（去重，更新）
              - 标记为已接收
```

### 消息更新流程

```
1. 消息状态变更（如：processing → completed）
   ↓
2. 数据库更新 updateTime
   ↓
3. 客户端查询未接收消息时
   ↓
4. 发现 updateTime > 接收时间
   ↓
5. 返回该消息给客户端
```

### 设备接收流程

```
1. 设备A查询未接收消息
   ↓
2. 返回消息列表
   ↓
3. 设备A标记消息为已接收
   ↓
4. 记录接收状态：messageId → deviceId → updateTime
   ↓
5. 设备A再次查询时，不返回已接收消息（除非消息已更新）
```

## 优势

1. **避免重复接收**：设备不会重复接收已处理的消息
2. **支持消息更新**：当消息状态更新时，设备可以重新接收
3. **高效同步**：只同步未接收的消息，减少网络传输
4. **离线支持**：本地缓存支持离线查看
5. **多设备支持**：每个设备独立跟踪接收状态

## 测试

所有测试用例均已通过：

- `test/new_requirements_test.dart`：基础请求类测试
- `test/unreceived_messages_test.dart`：未接收消息机制测试

测试覆盖：
- 请求类序列化/反序列化
- 消息更新时间跟踪
- 未接收消息查询逻辑
- 标记消息为已接收逻辑
