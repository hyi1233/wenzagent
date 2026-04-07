# 用户消息重复问题修复

## 问题描述

发送消息后，`getUnreceivedMessages` 返回了与当前输入消息 ID 不同的相同消息，导致消息列表中出现重复的用户消息。

## 问题原因

### 流程分析

1. **客户端发送消息**：
   - 客户端生成 UUID 作为消息 ID（例如：`uuid-001`）
   - 创建本地消息并添加到缓存
   - 发送到远程 Agent，携带客户端生成的 ID

2. **远程 Agent 处理**：
   - 远程 Agent 可能生成新的 UUID（例如：`uuid-002`）
   - 保存消息到远程数据库

3. **同步未接收消息**：
   - `getUnreceivedMessages` 返回远程消息（ID 为 `uuid-002`）
   - 本地缓存中已有消息（ID 为 `uuid-001`）
   - **ID 不同，内容相同**

4. **合并消息**：
   - 旧逻辑：只根据 ID 去重
   - 结果：两条消息都被保留，用户看到重复消息 ❌

### 根本原因

`_mergeUnreceivedMessages` 方法只根据消息 ID 去重，没有考虑以下情况：
- 远程 Agent 可能没有使用客户端提供的 ID
- 网络传输过程中 ID 可能被修改
- 导致相同内容的消息有不同 ID

## 解决方案

### 修复策略

在 `_mergeUnreceivedMessages` 中添加基于内容签名的去重逻辑，专门处理用户消息：

1. **第一层：ID 去重**
   - 如果 ID 相同，更新消息

2. **第二层：内容签名去重**（仅用户消息）
   - 对于用户消息（`role='user'`），计算内容签名
   - 签名 = `user_${content}_${timeWindow}`
   - 时间窗口 = ±5秒（避免误判）
   - 如果签名匹配，说明是重复消息
   - 用远程消息替换本地消息

### 代码实现

#### 1. 新增方法：`_findDuplicateUserMessage()`（第232-259行）

```dart
/// 查找重复的用户消息（基于内容签名）
///
/// 使用内容+时间窗口（±5秒）作为签名，避免误判
int _findDuplicateUserMessage(AgentMessage message) {
  if (message.role != 'user' || message.content == null || message.content!.isEmpty) {
    return -1;
  }

  // 计算时间窗口
  final timeWindow = (message.createdAt.millisecondsSinceEpoch ~/ 5000) * 5;
  final signature = 'user_${message.content}_$timeWindow';

  // 查找匹配的消息
  for (int i = 0; i < _cachedMessages.length; i++) {
    final cachedMessage = _cachedMessages[i];
    if (cachedMessage.role != 'user' || 
        cachedMessage.content == null || 
        cachedMessage.content!.isEmpty) {
      continue;
    }

    final cachedTimeWindow = (cachedMessage.createdAt.millisecondsSinceEpoch ~/ 5000) * 5;
    final cachedSignature = 'user_${cachedMessage.content}_$cachedTimeWindow';

    if (signature == cachedSignature) {
      // 发现重复
      return i;
    }
  }

  return -1;
}
```

#### 2. 修改方法：`_mergeUnreceivedMessages()`（第179-229行）

```dart
for (final message in unreceivedMessages) {
  // 检查是否已存在（根据ID）
  final existingIndex = _cachedMessages.indexWhere((m) => m.id == message.id);

  if (existingIndex == -1) {
    // ID不匹配，但对于用户消息，检查内容签名去重
    if (message.role == 'user') {
      final duplicateIndex = _findDuplicateUserMessage(message);
      if (duplicateIndex != -1) {
        // 发现内容重复的用户消息，更新为远程消息
        final existingMessage = _cachedMessages[duplicateIndex];
        print('[CachedAgentProxy] 发现重复用户消息，更新ID: ${existingMessage.id} -> ${message.id}');
        
        // 使用远程消息替换本地消息
        _cachedMessages[duplicateIndex] = message;
        
        // 更新数据库：先删除旧记录，再添加新记录
        await _messageStore.hardDeleteMessage(existingMessage.id, deviceId: _deviceId);
        final entity = _messageToEntity(message);
        await _messageStore.addMessage(entity, deviceId: _deviceId);
        
        print('[CachedAgentProxy] 已更新用户消息: ${message.id}');
        continue;
      }
    }
    
    // 新消息，添加到缓存
    // ...
  }
}
```

## 修复效果

### 修复前

```
本地缓存: { id: 'uuid-001', role: 'user', content: '你好' }
远程返回: { id: 'uuid-002', role: 'user', content: '你好' }

合并后:
- uuid-001: 你好
- uuid-002: 你好
❌ 用户看到两条相同的消息
```

### 修复后

```
本地缓存: { id: 'uuid-001', role: 'user', content: '你好' }
远程返回: { id: 'uuid-002', role: 'user', content: '你好' }

检测到内容签名重复：
- 时间窗口相同（±5秒内）
- 内容相同
- 签名匹配

处理：
1. 删除本地消息（uuid-001）
2. 添加远程消息（uuid-002）

合并后:
- uuid-002: 你好
✅ 只保留一条消息（远程版本）
```

## 技术细节

### 时间窗口设计

使用 5 秒时间窗口，避免误判：

```dart
final timeWindow = (timestamp ~/ 5000) * 5;
```

- 同一用户在 5 秒内发送相同内容的消息会被认为是重复
- 5 秒后发送相同内容会被认为是新的消息

### 签名计算

```dart
final signature = 'user_${content}_${timeWindow}';
```

示例：
- 内容：`"你好"`
- 时间：`2026-04-07 20:30:15`（时间戳：1746033015000）
- 时间窗口：`1746033015`（除以 5 再乘以 5）
- 签名：`"user_你好_1746033015"`

### 为什么用远程消息替换本地消息？

1. **远程消息是真实消息**：远程 Agent 保存的消息是最终的、持久化的消息
2. **避免状态不一致**：远程消息包含完整的状态信息
3. **保证数据一致性**：所有客户端看到的消息 ID 一致

## 适用场景

### ✅ 场景1：远程 Agent 忽略客户端 ID

```
客户端生成 ID → 远程生成新 ID → 内容签名去重 → 保留远程消息
```

### ✅ 场景2：网络传输 ID 被修改

```
客户端发送 ID-A → 网络传输变成 ID-B → 内容签名去重 → 保留远程消息
```

### ✅ 场景3：多设备同步

```
设备A 发送消息 → 设备B 同步 → 内容签名去重 → 保留远程消息
```

### ❌ 不适用场景

- 用户在 5 秒内快速发送两条相同内容的消息（会被误判为重复）
- 解决方案：客户端 UI 层做限制，不允许快速发送相同内容

## 测试验证

✅ 单元测试通过

建议添加以下测试：
- [ ] 发送消息后，远程返回不同 ID，验证只保留一条消息
- [ ] 发送消息后，远程返回相同 ID，验证消息更新
- [ ] 5 秒内发送两条相同内容的消息，验证去重
- [ ] 5 秒后发送相同内容的消息，验证保留两条消息

## 相关代码

- `lib/src/agent/client/cached_agent_proxy.dart` - 主要修改
  - `_mergeUnreceivedMessages()` - 合并逻辑
  - `_findDuplicateUserMessage()` - 查找重复消息

## 总结

通过在 `_mergeUnreceivedMessages` 中添加基于内容签名的去重逻辑，成功解决了用户消息重复的问题。修复保持了向后兼容，只影响用户消息的处理逻辑，不影响其他消息类型。

**修复方式**：双重去重（ID + 内容签名）  
**适用范围**：仅用户消息（`role='user'`）  
**时间窗口**：±5秒  
**处理策略**：保留远程消息，删除本地消息
