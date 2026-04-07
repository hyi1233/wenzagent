# 消息删除逻辑改进说明

## 问题描述

**症状**：同步后，本地消息如果不在远程中，应该被删除，但当前逻辑保留了所有用户消息

**示例日志**：
```
[CachedAgentProxy] 本地消息ID msg_1775537595697_329850866 不在远程消息中
  -> 保留本地待同步消息
```

**问题**：这条消息可能已经被远程删除，但因为判断逻辑不够准确而被错误保留

## 问题根源

### 错误的判断逻辑（修复前）

```dart
bool _shouldKeepLocalMessage(AgentMessage message) {
  // 1. 如果是用户消息，通常应该保留
  if (message.role == 'user') {
    return true;  // ❌ 导致所有用户消息都被保留
  }
  
  // 2. 如果有本地修改标记
  if (message.metadata?['locallyModified'] == true) {
    return true;
  }
  
  return false;
}
```

**问题**：
- 所有用户消息都被无条件保留，即使远程已删除
- 没有考虑消息的创建时间
- 没有考虑消息的状态

### 改进后的判断逻辑

```dart
bool _shouldKeepLocalMessage(AgentMessage message) {
  // 1. 如果消息状态是pending或failed，应该保留（等待重试）
  if (message.status == 'pending' || message.status == 'failed') {
    return true;
  }
  
  // 2. 如果有本地修改标记
  if (message.metadata?['locallyModified'] == true) {
    return true;
  }
  
  // 3. 如果消息非常新（最近5分钟内创建），可能远程还没同步
  final now = DateTime.now();
  final messageTime = message.createdAt;
  final diff = now.difference(messageTime);
  if (diff.inMinutes < 5) {
    return true;
  }
  
  // 4. 默认不保留（远程已删除）
  return false;
}
```

## 消息删除流程

### 完整流程

```
同步远程消息
    ↓
合并本地和远程消息
    ↓
发现本地消息不在远程中
    ↓
判断是否应该保留
    ├─ 状态为pending/failed → 保留（等待重试）
    ├─ 有本地修改标记 → 保留
    ├─ 创建时间 < 5分钟 → 保留（可能远程还没同步）
    └─ 否则 → 删除
    ↓
从数据库中删除已删除的消息
    ↓
更新缓存
```

### 判断规则

| 条件 | 是否保留 | 原因 |
|------|---------|------|
| 状态为pending | ✅ 保留 | 消息还在发送中，需要等待 |
| 状态为failed | ✅ 保留 | 发送失败，可能需要重试 |
| localOnly=true | ✅ 保留 | 还未确认远程已接收 |
| locallyModified=true | ✅ 保留 | 有本地修改，需要同步 |
| 创建时间 < 5分钟 | ✅ 保留 | 可能远程还没同步 |
| 其他情况 | ❌ 删除 | 远程已删除 |

## 代码改进

### 1. 改进消息合并逻辑

```dart
// 2. 处理本地有但远程没有的消息
final deletedMessageIds = <String>[];
for (final localMsg in _cachedMessages) {
  if (!processedIds.contains(localMsg.id)) {
    print('[CachedAgentProxy] 本地消息ID ${localMsg.id} 不在远程消息中');
    print('  - 消息状态: ${localMsg.status}');
    print('  - 消息角色: ${localMsg.role}');
    print('  - 创建时间: ${localMsg.createdAt}');
    
    if (_isLocalPendingMessage(localMsg)) {
      // 本地待同步消息，保留
      mergedMessages.add(localMsg);
      print('  -> 保留本地待同步消息');
    } else if (_shouldKeepLocalMessage(localMsg)) {
      // 需要保留的本地消息
      mergedMessages.add(localMsg);
      print('  -> 保留本地消息（可能远程还没同步）');
    } else {
      // 远程已删除，标记为删除
      deletedMessageIds.add(localMsg.id);
      print('  -> 丢弃本地消息（远程已删除）');
    }
  }
}

// 删除本地数据库中已删除的消息
if (deletedMessageIds.isNotEmpty) {
  print('[CachedAgentProxy] 从本地数据库删除 ${deletedMessageIds.length} 条消息');
  await _deleteMessagesFromDatabase(deletedMessageIds);
}
```

### 2. 添加删除消息方法

```dart
/// 从数据库删除消息
Future<void> _deleteMessagesFromDatabase(List<String> messageIds) async {
  try {
    // 使用更新状态为'deleted'的方式标记删除
    for (final messageId in messageIds) {
      await _messageStore.updateMessageStatus(messageId, 'deleted');
    }
    print('[CachedAgentProxy] 成功标记删除 ${messageIds.length} 条消息');
  } catch (e) {
    print('[CachedAgentProxy] 删除消息失败: $e');
  }
}
```

### 3. 改进日志输出

添加了更详细的日志输出：
- 消息状态
- 消息角色
- 创建时间
- 判断结果

## 测试场景

### 场景1：正常删除

```
本地：消息A（status: sent, 创建时间: 1小时前）
远程：（消息A已删除）

结果：消息A被删除 ✅
日志：丢弃本地消息（远程已删除）
```

### 场景2：保留待同步消息

```
本地：消息B（status: pending, 创建时间: 刚刚）
远程：（消息B还没同步）

结果：消息B被保留 ✅
日志：保留本地待同步消息
```

### 场景3：保留新创建消息

```
本地：消息C（status: sent, 创建时间: 2分钟前）
远程：（消息C还没同步）

结果：消息C被保留 ✅
日志：保留本地消息（可能远程还没同步）
```

### 场景4：删除旧消息

```
本地：消息D（status: sent, 创建时间: 1天前）
远程：（消息D已删除）

结果：消息D被删除 ✅
日志：丢弃本地消息（远程已删除）
```

## 调试建议

### 查看删除日志

```bash
# 查看被删除的消息
grep "丢弃本地消息" logs.txt

# 查看保留的消息
grep "保留本地" logs.txt

# 查看删除统计
grep "从本地数据库删除" logs.txt
```

### 典型日志输出

```
[CachedAgentProxy] 开始合并消息:
  - 本地消息数: 5
  - 远程消息数: 3
  - 本地消息ID: uuid-1, role: user, status: sent
  - 本地消息ID: uuid-2, role: user, status: sent
  - 本地消息ID: uuid-3, role: user, status: pending
  - 本地消息ID: uuid-4, role: assistant, status: sent
  - 本地消息ID: uuid-5, role: user, status: sent
  - 远程消息ID: uuid-1, role: user, status: sent
  - 远程消息ID: uuid-2, role: user, status: sent
  - 远程消息ID: uuid-4, role: assistant, status: sent
  
[CachedAgentProxy] 本地消息ID uuid-3 不在远程消息中
  - 消息状态: pending
  - 消息角色: user
  - 创建时间: 2026-04-07 18:10:00
  -> 保留本地待同步消息
  
[CachedAgentProxy] 本地消息ID uuid-5 不在远程消息中
  - 消息状态: sent
  - 消息角色: user
  - 创建时间: 2026-04-07 10:00:00
  -> 丢弃本地消息（远程已删除）
  
[CachedAgentProxy] 从本地数据库删除 1 条消息
[CachedAgentProxy] 成功标记删除 1 条消息
[CachedAgentProxy] 合并完成，最终消息数: 4
```

## 优势

### 1. 准确性
- ✅ 只保留真正需要保留的消息
- ✅ 正确删除远程已删除的消息
- ✅ 避免误删新创建的消息

### 2. 性能
- ✅ 减少本地缓存的冗余数据
- ✅ 提高查询效率
- ✅ 节省存储空间

### 3. 用户体验
- ✅ 本地和远程数据保持一致
- ✅ 避免显示已删除的消息
- ✅ 离线消息不会丢失

## 注意事项

### 1. 时间窗口设置

当前设置为5分钟，可以根据实际情况调整：
- 网络较慢的环境：可以增加到10分钟
- 网络较好的环境：可以减少到2-3分钟
- 实时性要求高的场景：可以设置为1分钟

### 2. 删除策略

当前使用标记删除（status: 'deleted'），而不是物理删除：
- 优点：可以恢复误删的消息
- 缺点：占用存储空间
- 建议：定期清理状态为'deleted'的旧消息

### 3. 特殊场景

以下场景需要特别注意：
- 离线发送的消息：可能需要更长的保留时间
- 网络异常情况：可能导致消息同步延迟
- 多设备同步：可能需要更复杂的一致性策略

## 总结

这次改进解决了消息删除逻辑不准确的问题：

1. **改进判断逻辑**：基于状态、时间等多维度判断
2. **添加删除功能**：从数据库中删除已删除的消息
3. **增强日志输出**：方便调试和追踪
4. **提高准确性**：只保留真正需要保留的消息

现在系统能够：
- 正确删除远程已删除的消息
- 保留真正需要保留的消息（待同步、新创建）
- 提供详细的日志输出，方便调试
- 保持本地和远程数据的一致性
