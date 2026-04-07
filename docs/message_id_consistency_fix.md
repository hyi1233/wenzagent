# 消息ID一致性修复

## 问题描述

用户发送消息后，`getUnreceivedMessages` 返回了与当前输入消息 ID 不一样的相同消息，导致消息重复显示。

## 问题根源

### 完整的消息流程

1. **客户端发送消息**
   - `CachedAgentProxy.sendMessage` 生成 `messageId`
   - 创建本地消息，使用该 ID
   - 发送到 `AgentProxy`，传递 `inputWithId`

2. **AgentProxy 处理**
   - 检查 `input.id`，如果没有就生成 UUID
   - 创建 `inputWithId`，确保消息有 ID
   - 通过 RPC 发送到远程

3. **AgentImpl 处理**
   - 获取客户端提供的 ID
   - 强制使用客户端 ID
   - 调用 `_processor?.submitMessage(finalMessageId, messageData)`

4. **LangChainChatAdapter 处理** ❌ **问题所在**
   - 创建 `ChatMessage.humanText(userContent)`
   - 调用 `memoryManager.addMessage(...)` **但没有传递消息 ID**
   - `addMessage` 内部调用 `MessageWrapper.create(message)` **自动生成新的 UUID**
   - 导致持久化的消息 ID 与客户端发送的 ID 不一致

5. **getUnreceivedMessages 返回**
   - 返回的消息使用自动生成的 UUID
   - 客户端期望的是原始的 `messageId`
   - 造成 ID 不匹配

### 问题代码

**session_memory_manager.dart (修改前)**
```dart
void addMessage(String deviceId, ChatMessage message) {
  messagesMap.putIfAbsent(deviceId, () => []).add(
    MessageWrapper.create(message),  // ❌ 每次都生成新的UUID！
  );
}
```

**langchain_chat_adapter.dart (修改前)**
```dart
// 添加用户消息到历史
final userMessage = ChatMessage.humanText(userContent);
memoryManager.addMessage(
  currentEmployeeUuid!,
  deviceId ?? 'default',
  userMessage,
);  // ❌ 没有传递消息ID
```

## 解决方案

### 核心原则

**每个环节都要确保消息 ID 没有变化**，而不是使用内容签名去重。

### 修改详情

#### 1. 修改 `SessionHistory.addMessage` 方法

**文件**: `lib/src/agent/adapter/session_memory_manager.dart`

```dart
/// 添加消息到指定设备
///
/// [messageId] 可选的消息ID，如果不提供则自动生成
void addMessage(String deviceId, ChatMessage message, {String? messageId}) {
  if (messageId != null) {
    // 使用提供的消息ID
    messagesMap.putIfAbsent(deviceId, () => []).add(
      MessageWrapper(
        uuid: messageId,
        message: message,
        createdAt: DateTime.now(),
      ),
    );
  } else {
    // 自动生成新的UUID
    messagesMap.putIfAbsent(deviceId, () => []).add(
      MessageWrapper.create(message),
    );
  }
}
```

#### 2. 修改 `SessionMemoryManager.addMessage` 方法

**文件**: `lib/src/agent/adapter/session_memory_manager.dart`

```dart
void addMessage(String employeeId, String deviceId, ChatMessage message, {String? messageId}) {
  final session = _sessions[employeeId];
  if (session != null) {
    session.addMessage(deviceId, message, messageId: messageId);
  }
}
```

#### 3. 修改 `LangChainChatAdapter.streamMessage` 方法

**文件**: `lib/src/agent/adapter/langchain_chat_adapter.dart`

```dart
// 添加用户消息到历史
// 🔑 关键：使用客户端提供的消息ID，而不是生成新的UUID
final userMessage = ChatMessage.humanText(userContent);
final userMessageId = messageData['id'] as String?;
if (userMessageId != null) {
  print('[LangChainChatAdapter] 使用客户端提供的消息ID: $userMessageId');
  memoryManager.addMessage(
    currentEmployeeUuid!,
    deviceId ?? 'default',
    userMessage,
    messageId: userMessageId,  // ✅ 传递消息ID
  );
} else {
  print('[LangChainChatAdapter] 没有提供消息ID，自动生成');
  memoryManager.addMessage(
    currentEmployeeUuid!,
    deviceId ?? 'default',
    userMessage,
  );
}
```

#### 4. 修改持久化逻辑，同时设置 `uuid` 和 `id` 字段

**文件**: `lib/src/agent/adapter/persistent_chat_adapter.dart`

```dart
// ✅ 使用 MessageWrapper 的稳定 UUID
// 🔑 同时设置 'uuid' 和 'id' 字段，确保数据库存储和查询一致
final map = <String, dynamic>{
  'uuid': wrapper.uuid,
  'id': wrapper.uuid,
  'role': type == 'human' ? 'user' : type == 'ai' ? 'assistant' : type,
  'content': content,
  'createdAt': wrapper.createdAt.toIso8601String(),
};
```

**文件**: `lib/src/agent/adapter/langchain_chat_adapter.dart`

```dart
// ✅ 使用 MessageWrapper 的稳定 UUID，而不是每次生成新 ID
// 🔑 同时设置 'uuid' 和 'id' 字段，确保数据库存储和查询一致
final map = <String, dynamic>{
  'uuid': wrapper.uuid,
  'id': wrapper.uuid,
  'role': type == 'human' ? 'user' : type == 'ai' ? 'assistant' : type,
  'content': content,
  'createdAt': wrapper.createdAt.toIso8601String(),
};
```

## 修复后的消息流程

```
客户端发送消息
  ↓
CachedAgentProxy: 生成 messageId (uuid-aaa)
  ↓
AgentProxy: 传递 inputWithId (id: uuid-aaa)
  ↓
AgentImpl: 使用客户端 ID (finalMessageId: uuid-aaa)
  ↓
LangChainChatAdapter: 从 messageData 提取 ID
  ↓
memoryManager.addMessage(..., messageId: uuid-aaa)
  ↓
MessageWrapper(uuid: uuid-aaa, ...) ✅
  ↓
持久化: {'uuid': uuid-aaa, 'id': uuid-aaa, ...}
  ↓
getUnreceivedMessages: 返回消息 ID = uuid-aaa ✅
  ↓
客户端: ID 匹配，无重复
```

## 撤销的内容签名去重逻辑

之前为了避免消息重复，添加了基于内容签名的去重逻辑，但这不是正确的解决方案。现在已经撤销：

- ❌ 删除 `_findDuplicateUserMessage()` 方法
- ❌ 删除内容签名去重逻辑
- ✅ 使用消息 ID 一致性保证

## 测试验证

### 测试用例

1. ✅ 权限请求缓存测试（`test/permission_request_test.dart`）
2. ✅ 消息去重测试（`test/message_deduplication_test.dart`）

### 测试结果

```
✅ 所有测试通过
✅ 无 lint 错误
✅ 消息 ID 在整个流程中保持一致
```

## 相关问题修复

此修复同时解决了以下问题：

1. ✅ 权限请求不显示（远程模式）
2. ✅ 消息 ID 不一致导致重复
3. ✅ 客户端重启后状态恢复
4. ✅ 网络中断重连后状态恢复

## 关键要点

1. **消息 ID 必须在生成时就确定**，并在整个流程中保持不变
2. **不要使用内容签名去重**，应该在源头保证 ID 一致性
3. **持久化时同时设置 `uuid` 和 `id` 字段**，避免字段不一致
4. **每个环节都要验证消息 ID**，确保没有变化

## 文件修改列表

| 文件 | 修改内容 |
|------|---------|
| `lib/src/agent/adapter/session_memory_manager.dart` | 添加 `messageId` 参数支持 |
| `lib/src/agent/adapter/langchain_chat_adapter.dart` | 从 `messageData` 提取并传递消息 ID |
| `lib/src/agent/adapter/persistent_chat_adapter.dart` | 同时设置 `uuid` 和 `id` 字段 |
| `lib/src/agent/client/cached_agent_proxy.dart` | 撤销内容签名去重逻辑 |
| `test/message_deduplication_test.dart` | 测试用例（保留） |

## 总结

通过在消息处理的每个环节确保消息 ID 的一致性，从根本上解决了消息重复的问题。这比使用内容签名去重更加可靠和正确。
