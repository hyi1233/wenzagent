# UUID格式验证问题修复

## 问题描述

**错误信息**：
```
Invalid argument(s): 消息ID必须是有效的UUID格式: msg_1775556095730_2c508454
```

**原因**：
1. `CachedAgentProxy._generateMessageId()` 生成的ID格式为 `msg_timestamp_uuid`，不是标准UUID格式
2. `AgentProxy` 添加了严格的UUID格式验证，导致抛出异常

## 标准UUID格式

标准UUID格式：`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

示例：`550e8400-e29b-41d4-a716-446655440000`

## 修复方案

### 1. 修改ID生成方法

**修复前**：
```dart
String _generateMessageId() {
  return 'msg_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 8)}';
}
```

生成ID示例：`msg_1775556095730_2c508454` ❌ 不是标准UUID

**修复后**：
```dart
String _generateMessageId() {
  return const Uuid().v4();
}
```

生成ID示例：`550e8400-e29b-41d4-a716-446655440000` ✅ 标准UUID格式

### 2. 调整验证逻辑

**修复前**：
```dart
// 严格验证所有消息ID
if (!_isValidUUID(messageId)) {
  throw ArgumentError('消息ID必须是有效的UUID格式: $messageId');
}
```

**修复后**：
```dart
// 只验证客户端生成的ID，允许用户自定义ID格式
if (input.id == null && !_isValidUUID(messageId)) {
  print('[AgentProxy] ⚠️ Warning: Generated message ID is not valid UUID format: $messageId');
  // 不抛出异常，继续使用
}
```

### 3. 验证规则

| 场景 | 是否验证 | 说明 |
|------|---------|------|
| 客户端自动生成ID | ✅ 验证 | 应该生成标准UUID格式 |
| 用户提供自定义ID | ❌ 不验证 | 允许自定义格式（如数据库ID） |
| Agent返回的ID | ⚠️ 警告 | 检测ID是否被修改 |

## 优势

### 使用标准UUID的优势

1. **全局唯一性**：UUID v4提供极高的唯一性保证
2. **业界标准**：符合RFC 4122标准
3. **系统兼容**：与各种系统和数据库兼容
4. **调试友好**：标准格式易于识别和追踪

### 灵活验证的优势

1. **向后兼容**：允许用户使用现有的ID格式
2. **灵活性**：支持多种ID生成策略
3. **容错性**：即使格式不标准也能继续工作
4. **调试友好**：警告而不是抛出异常

## 使用建议

### 推荐：使用标准UUID

```dart
// ✅ 推荐：让系统自动生成标准UUID
await proxy.sendMessage(
  MessageInput(content: '你好'),
);
```

### 允许：使用自定义ID

```dart
// ✅ 允许：提供自定义ID（如数据库ID）
await proxy.sendMessage(
  MessageInput(
    content: '你好',
    id: 'custom_id_123',  // 自定义ID格式
  ),
);
```

### 不推荐：使用非标准格式的自动生成ID

```dart
// ❌ 不推荐：手动生成非标准格式ID
final customId = 'msg_${DateTime.now().millisecondsSinceEpoch}';
await proxy.sendMessage(
  MessageInput(
    content: '你好',
    id: customId,  // 非标准格式，会有警告
  ),
);
```

## 验证方法

### 检查UUID格式

```dart
bool _isValidUUID(String uuid) {
  final uuidRegExp = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  return uuidRegExp.hasMatch(uuid);
}
```

### 测试用例

```dart
void testUUIDFormat() {
  // 标准UUID - 应该通过验证
  assert(_isValidUUID('550e8400-e29b-41d4-a716-446655440000'));
  
  // 非标准格式 - 应该失败
  assert(!_isValidUUID('msg_1775556095730_2c508454'));
  assert(!_isValidUUID('custom_id_123'));
}
```

## 相关改进

1. ✅ **统一ID生成**：所有自动生成的ID都使用标准UUID格式
2. ✅ **灵活验证**：只验证客户端生成的ID，允许用户自定义
3. ✅ **警告而非异常**：格式不标准时记录警告，不中断流程
4. ✅ **调试友好**：详细的日志记录，方便追踪ID问题

## 总结

这次修复解决了UUID格式验证过严的问题：

1. **生成标准UUID**：确保所有自动生成的ID符合标准格式
2. **灵活验证策略**：只验证客户端生成的ID，允许用户自定义
3. **改进错误处理**：警告而非异常，提高容错性
4. **保持一致性**：与业界标准保持一致，提高兼容性

现在系统可以：
- 自动生成标准UUID格式的消息ID
- 允许用户提供自定义格式的ID
- 验证客户端生成的ID格式
- 警告非标准格式，但不中断流程
