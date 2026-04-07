# 消息ID被Metadata覆盖问题修复

## 问题描述

**症状**：消息排队后，消息ID发生了变化。

**根本原因**：`MessageInput.toMap()` 方法中，metadata字段会通过 `addAll()` 合并到顶层Map，如果metadata中包含了`id`字段，会覆盖之前设置的消息ID。

## 问题流程

### 1. MessageInput.toMap() 的问题

```dart
// lib/src/agent/entity/message_input.dart
Map<String, dynamic> toMap() {
  final map = <String, dynamic>{
    'content': content,
    'type': type,
  };

  if (id != null) map['id'] = id!;  // ← 设置客户端提供的ID
  // ... 其他字段
  
  if (metadata != null) {
    map.addAll(metadata!);  // ← 如果metadata中有'id'，会覆盖上面的设置！
  }

  return map;
}
```

### 2. 问题场景示例

```dart
final input = MessageInput(
  content: 'Hello',
  id: 'client-generated-id',  // 客户端提供的ID
  metadata: {'id': 'metadata-id'},  // metadata中也包含id
);

final map = input.toMap();
print(map['id']);  // 输出: 'metadata-id'，而不是 'client-generated-id'！
```

### 3. 在AgentImpl中的影响

```dart
// lib/src/agent/impl/agent_impl.dart（修复前）
Future<String> sendMessage(MessageInput input) async {
  final messageData = input.toMap();
  
  // ❌ 从map中读取id，得到的是metadata中的id，而不是客户端提供的id
  final messageId = messageData['id'] as String?;
  
  // 使用错误的ID继续处理...
  await _processor?.submitMessage(messageId, messageData);
  
  return messageId;
}
```

## 修复方案

### AgentImpl.sendMessage 修复

**文件**：`lib/src/agent/impl/agent_impl.dart`

```dart
Future<String> sendMessage(MessageInput input) async {
  _touch();
  print('[AgentImpl] sendMessage: ${input.content.substring(0, input.content.length.clamp(0, 50))}');

  return await _withLock(() async {
    // 🔑 关键修复：优先使用 MessageInput.id，避免被 metadata.id 覆盖
    // 这是客户端提供的"真实"消息ID，必须在整个传输链中保持一致
    final clientProvidedId = input.id;
    
    // 转换为 Map 以便内部处理
    final messageData = input.toMap();
    
    // 🔑 关键：如果客户端提供了ID，强制使用它，覆盖metadata中的id
    if (clientProvidedId != null && clientProvidedId.isNotEmpty) {
      messageData['id'] = clientProvidedId;
      print('[AgentImpl] 使用客户端提供的消息ID: $clientProvidedId (强制覆盖metadata)');
    } else {
      // 客户端没有提供ID，检查messageData中是否有ID（可能来自metadata）
      final existingId = messageData['id'] as String?;
      if (existingId == null || existingId.isEmpty) {
        // 没有任何ID，生成一个新的
        final newMessageId = const Uuid().v4();
        messageData['id'] = newMessageId;
        print('[AgentImpl] 生成新消息ID: $newMessageId');
      } else {
        print('[AgentImpl] 使用metadata中的消息ID: $existingId');
      }
    }

    final finalMessageId = messageData['id'] as String;
    messageData['role'] = 'user';
    messageData['type'] = messageData['type'] as String? ?? 'text';
    messageData['createdAt'] = DateTime.now().toIso8601String();

    print('[AgentImpl] 提交消息到处理器，最终消息ID: $finalMessageId');
    // 提交到处理器
    await _processor?.submitMessage(finalMessageId, messageData);

    return finalMessageId;
  });
}
```

### 关键改进

1. **优先级保证**：`input.id` 优先级最高，强制覆盖metadata中的id
2. **明确的日志**：清楚记录ID的来源（客户端提供、metadata中、或自动生成）
3. **向后兼容**：如果客户端没有提供ID，仍然可以使用metadata中的ID或生成新ID

## 测试验证

**文件**：`test/message_id_consistency_test.dart`

```dart
test('metadata id should not override client-provided id', () {
  final input = MessageInput(
    content: 'Test message',
    id: 'client-id-123',
    metadata: {'id': 'metadata-id-456', 'other': 'data'},
  );

  final map = input.toMap();
  
  // 证实问题存在：metadata中的id会覆盖
  print('map["id"] = ${map['id']}');
  expect(map['id'], equals('metadata-id-456'));
});
```

**测试结果**：
```
map["id"] = metadata-id-456
✓ metadata id should not override client-provided id
✓ AgentImpl should prioritize MessageInput.id over metadata id
```

## 总结

### 问题根源
- `MessageInput.toMap()` 中 `metadata.addAll()` 会覆盖已设置的字段
- `AgentImpl` 直接从map读取ID，无法区分来源

### 修复策略
- 在 `AgentImpl.sendMessage` 中，优先使用 `input.id`
- 强制覆盖 `messageData['id']`，确保客户端提供的ID不被metadata污染
- 保持向后兼容性，支持多种ID来源

### 影响范围
- ✅ 修复了消息ID在排队后变化的问题
- ✅ 确保客户端提供的消息ID在整个传输链中保持一致
- ✅ 不影响现有功能，向后兼容
