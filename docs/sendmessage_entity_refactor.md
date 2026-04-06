# sendMessage 方法 Entity 改造总结

## 改造概述

将 `sendMessage` 方法的参数从 `Map<String, dynamic>` 改造为类型安全的 `MessageInput` Entity。

**改造时间**: 2026-04-07 06:30  
**改造范围**: agent 模块的核心消息发送接口

---

## 改造内容

### 1. 新增 Entity: MessageInput

**文件**: `lib/src/agent/entity/message_input.dart`

```dart
class MessageInput {
  final String content;           // 消息内容（必需）
  final String type;              // 消息类型（默认: text）
  final String? id;               // 消息ID（可选）
  final String? employeeId;       // 目标员工ID（可选）
  final String? role;             // 消息角色（可选）
  final DateTime? createdAt;      // 创建时间（可选）
  final String? toolCallId;       // 工具调用ID（可选）
  final String? toolName;         // 工具名称（可选）
  final Map<String, dynamic>? toolArguments;  // 工具参数（可选）
  final String? toolResult;       // 工具结果（可选）
  final Map<String, dynamic>? metadata;  // 元数据（可选）
}
```

**特性**:
- 类型安全的字段访问
- 提供 `toMap()` 方法用于向后兼容和序列化
- 提供 `fromMap()` 工厂方法用于从旧格式创建
- 提供 `copyWith()` 方法用于不可变更新
- 自动将 metadata 中的字段合并到 Map（保持原有行为）

---

### 2. 接口修改

#### IAgent 接口 (`lib/src/agent/i_agent.dart`)

**修改前**:
```dart
Future<String> sendMessage(Map<String, dynamic> messageData);
```

**修改后**:
```dart
Future<String> sendMessage(MessageInput input);

@Deprecated('Use sendMessage(MessageInput) instead')
Future<String> sendMessageFromMap(Map<String, dynamic> messageData) {
  return sendMessage(MessageInput.fromMap(messageData));
}
```

**向后兼容**:
- 提供了 `sendMessageFromMap` 方法（标记为 @Deprecated）
- 保留旧代码的迁移路径

---

### 3. 实现修改

#### AgentImpl (`lib/src/agent/impl/agent_impl.dart`)

```dart
@override
Future<String> sendMessage(MessageInput input) async {
  // 转换为 Map 以便内部处理
  final messageData = input.toMap();
  
  // 生成消息ID
  final messageId = messageData['id'] as String? ?? 
      'msg_${DateTime.now().millisecondsSinceEpoch}_${Object().hashCode}';
  messageData['id'] = messageId;
  messageData['role'] = 'user';
  messageData['type'] = messageData['type'] as String? ?? 'text';
  messageData['createdAt'] = DateTime.now().toIso8601String();

  // 提交到处理器
  await _processor?.submitMessage(messageId, messageData);
  return messageId;
}

@override
Future<String> sendMessageFromMap(Map<String, dynamic> messageData) {
  return sendMessage(MessageInput.fromMap(messageData));
}
```

---

#### AgentProxy (`lib/src/agent/client/agent_proxy.dart`)

```dart
Future<String> sendMessage(MessageInput input) async {
  if (isLocalMode && _localAgent != null) {
    final messageId = await _localAgent.sendMessage(input);
    final pendingMessage = _createPendingMessage(input, messageId);
    _pendingMessageQueue.add(pendingMessage);
    return messageId;
  }
  
  // RPC 调用：将 MessageInput 转换为 Map
  final messageData = input.toMap();
  final result = await _rpc(AgentRpcConfig.methodSendMessage, {
    'employeeId': employeeId,
    'messageData': messageData,
  });
  
  final messageId = result['messageId'] as String? ?? '';
  if (messageId.isNotEmpty) {
    final pendingMessage = _createPendingMessage(input, messageId);
    _pendingMessageQueue.add(pendingMessage);
  }
  return messageId;
}

PendingMessage _createPendingMessage(MessageInput input, String messageId) {
  return PendingMessage(
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
    sentAt: DateTime.now(),
    status: PendingMessageStatus.pending,
    deviceId: deviceId,
    employeeId: employeeId,
  );
}
```

---

#### AgentClient (`lib/src/agent/client/agent_client.dart`)

```dart
Future<String> sendMessage({
  required String content,
  String? employeeId,
}) async {
  final empId = employeeId ?? _currentEmployeeId;
  if (empId == null) {
    throw Exception('employeeId is required');
  }

  final input = MessageInput(
    content: content,
    employeeId: empId,
  );

  final result = await _rpcCall(
    AgentRpcConfig.methodSendMessage,
    {
      'employeeId': empId,
      'messageData': input.toMap(),
    },
  );

  return result['messageId'] as String;
}
```

---

#### DeviceClientImpl (`lib/src/device/impl/device_client_impl.dart`)

```dart
// RPC 服务端处理
final messageData = params['messageData'] as Map<String, dynamic>;
final input = MessageInput.fromMap(messageData);
final messageId = await agent.sendMessage(input);
return {'messageId': messageId};
```

---

### 4. 测试文件更新

所有测试文件和示例文件都已更新：

- `test_agent_entity_refactor.dart`
- `test_agent_proxy_message_queue.dart`
- `example/agent_proxy_message_queue_example.dart`
- MockAgent 类实现了 `sendMessageFromMap` 方法

**使用示例**:

```dart
// 新方式（推荐）
final messageId = await agentProxy.sendMessage(
  MessageInput(
    content: '你好，这是一条消息',
    type: 'text',
    metadata: {'customField': '自定义数据'},
  ),
);

// 旧方式（向后兼容）
final messageId = await agentProxy.sendMessageFromMap({
  'content': '你好，这是一条消息',
  'type': 'text',
  'customField': '自定义数据',
});
```

---

## 改造优势

### 1. 类型安全

**改造前**:
```dart
await agent.sendMessage({
  'content': '消息内容',
  'typo': 'text',  // 拼写错误，编译器无法检测
});
```

**改造后**:
```dart
await agent.sendMessage(
  MessageInput(
    content: '消息内容',
    type: 'text',  // IDE 自动补全，拼写错误会被检测
  ),
);
```

### 2. IDE 支持

- ✅ 自动补全字段名称
- ✅ 参数类型提示
- ✅ 编译时类型检查
- ✅ 重构支持（重命名字段）

### 3. 文档化

```dart
/// 发送消息的输入数据
///
/// 用于 sendMessage 方法的参数，提供类型安全的消息构建
class MessageInput {
  /// 消息内容
  final String content;
  
  /// 消息类型（默认: text）
  final String type;
  
  // ...
}
```

### 4. 一致性

- 与其他 Entity（AgentMessage、PendingMessage、QueuedMessage）保持一致
- 统一的序列化/反序列化模式
- 统一的命名约定

---

## 向后兼容性

### 保持兼容的设计

1. **sendMessageFromMap 方法**: 标记为 @Deprecated，但仍然可用
2. **toMap() 方法**: MessageInput 提供转换为 Map 的方法
3. **fromMap() 方法**: 从 Map 创建 MessageInput
4. **metadata 字段**: 自定义字段自动合并到 Map

### 迁移路径

**阶段 1**: 混合使用（当前）
```dart
// 新代码使用 Entity
await agent.sendMessage(MessageInput(content: 'test'));

// 旧代码继续使用 Map
await agent.sendMessageFromMap({'content': 'test'});
```

**阶段 2**: 逐步迁移
```dart
// 逐步将旧代码改为 Entity
await agent.sendMessage(MessageInput.fromMap(oldMap));
```

**阶段 3**: 完全迁移
```dart
// 完全使用 Entity
await agent.sendMessage(MessageInput(content: 'test'));
```

---

## 测试结果

### ✅ 所有测试通过

| 测试项 | 状态 |
|-------|------|
| Agent Entity 重构测试 | ✅ 通过 |
| AgentProxy 消息队列测试 | ✅ 通过 |
| AgentProxy 消息队列示例 | ✅ 通过 |
| 代码静态分析 | ✅ 无错误 |

### 测试输出示例

```
【测试 1】AgentProxy 使用 PendingMessage
[AgentProxy] sendMessage isLocalMode: true
[AgentProxy] calling local agent sendMessage
  消息ID: msg_1775514645688
  待确认队列长度: 1
  ✓ AgentProxy 使用 PendingMessage 成功
```

---

## 文件变更清单

### 新增文件

- `lib/src/agent/entity/message_input.dart` - MessageInput Entity 定义

### 修改文件

1. **Entity 导出**:
   - `lib/src/agent/entity/entity.dart` - 添加 MessageInput 导出

2. **接口定义**:
   - `lib/src/agent/i_agent.dart` - 更新 sendMessage 签名

3. **实现类**:
   - `lib/src/agent/impl/agent_impl.dart` - 实现 MessageInput 版本
   - `lib/src/agent/client/agent_proxy.dart` - 使用 MessageInput
   - `lib/src/agent/client/agent_client.dart` - 使用 MessageInput
   - `lib/src/device/impl/device_client_impl.dart` - 使用 MessageInput

4. **测试和示例**:
   - `test_agent_entity_refactor.dart`
   - `test_agent_proxy_message_queue.dart`
   - `example/agent_proxy_message_queue_example.dart`

---

## 注意事项

### 1. RPC 传输

MessageInput 需要通过 `toMap()` 转换为 Map 后才能进行 RPC 传输：

```dart
final messageData = input.toMap();
await _rpc('sendMessage', {'messageData': messageData});
```

### 2. 元数据处理

MessageInput 的 metadata 字段会在 `toMap()` 时自动合并到顶层：

```dart
final input = MessageInput(
  content: 'test',
  metadata: {'customField': 'value'},
);

input.toMap();
// => {
//   'content': 'test',
//   'type': 'text',
//   'customField': 'value',  // 自动合并
// }
```

这保持了原有的自定义字段处理逻辑。

### 3. 必需字段

只有 `content` 是必需字段，其他字段都有合理的默认值：

```dart
// 最小化调用
await agent.sendMessage(MessageInput(content: 'test'));

// 完整调用
await agent.sendMessage(MessageInput(
  content: 'test',
  type: 'text',
  id: 'msg-001',
  employeeId: 'emp-001',
  metadata: {'custom': 'data'},
));
```

---

## 后续工作

1. **监控生产环境**: 观察新接口的使用情况
2. **收集反馈**: 开发者使用体验
3. **优化实现**: 根据实际使用情况优化 MessageInput
4. **文档更新**: 更新 API 文档和使用指南
5. **完全迁移**: 逐步将所有代码迁移到使用 Entity

---

## 总结

✅ **改造成功**

- 类型安全的消息发送接口
- 保持向后兼容性
- IDE 支持完善
- 所有测试通过
- 代码质量提升

**建议**: 可以安全地部署到生产环境，建议逐步将现有代码迁移到使用 MessageInput Entity。
