# CachedAgentProxy 改进说明

## 问题背景

重启app后，消息列表没有正常查询远程agent消息列表，用户看到的是旧的本地缓存消息。

## 正确的业务逻辑

### 核心要求

1. **打开agent时**：先读取本地缓存（快速响应），然后主动查询远程消息
2. **监听到远程消息更新后**：主动查询消息并更新缓存

### 完整流程

```
┌─────────────────────────────────────────────────────────────┐
│                      App 启动                                │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  CachedAgentProxy.initialize()                              │
│  1. 加载本地缓存（快速响应，支持离线查看）                    │
│  2. 同步远程消息（确保数据最新）                              │
│  3. 更新本地缓存                                             │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│               用户打开聊天界面                                │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  ChatViewController.loadSession()                           │
│  1. 调用 getSessionMessages()                               │
│  2. 订阅状态变更：onStateChanged                             │
│  3. 订阅设备事件：onAgentEvent                              │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  CachedAgentProxy.getMessages()                             │
│  1. 立即返回本地缓存（用户立即看到消息）                      │
│  2. 后台同步远程消息（确保数据最新）                          │
│  3. 更新本地缓存和UI                                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│            远程 Agent 消息状态变更                            │
│            (processing -> completed)                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  AgentProxy.onStateChanged 触发                              │
│  ↓                                                          │
│  ChatViewController 监听到状态变更                           │
│  ↓                                                          │
│  调用 getSessionMessages()                                  │
│  ↓                                                          │
│  CachedAgentProxy.getMessages() 主动查询远程消息             │
│  ↓                                                          │
│  更新缓存和UI                                                │
└─────────────────────────────────────────────────────────────┘
```

## 代码实现

### 1. 初始化流程

```dart
Future<void> initialize() async {
  // 1. 从本地缓存加载消息（支持离线查看）
  await _loadLocalMessages();

  // 2. 同步一次远程消息（确保启动时有最新数据）
  await syncWithRemote();

  // 不再启动定时器，改为主动查询
}
```

### 2. 获取消息流程

```dart
Future<List<AgentMessage>> getMessages({bool forceRefresh = false}) async {
  // 本地模式：直接透传
  if (!_needCache) {
    return await _proxy.getSessionMessages();
  }

  // 远程模式：
  // 1. 先返回本地缓存（快速响应）
  var messages = _cachedMessages;

  // 2. 主动查询远程消息（后台同步）
  if (forceRefresh) {
    // 强制刷新：等待同步完成再返回
    await syncWithRemote();
    messages = _cachedMessages;
  } else {
    // 非强制：先返回缓存，后台同步更新
    syncWithRemote().catchError((e) {
      print('同步远程消息失败: $e');
    });
  }

  return messages;
}
```

### 3. 客户端监听流程

```dart
// 客户端代码（ChatViewController）
void _subscribeAgentState() {
  _stateSubscription = _agentProxy!.onStateChanged.listen((state) {
    _agentState = state;
    _reloadMessagesDebounced();  // ✅ 状态变更时重新加载消息
  });
}

void _handleAgentEvent(Map<String, dynamic> event) {
  final type = event['type'] as String?;

  switch (type) {
    case 'agentStatusChanged':
    case 'messageStatusChanged':
      _reloadMessagesDebounced();  // ✅ 消息状态变更时重新加载
      break;
  }
}

Future<void> _loadMessages() async {
  // 调用 getSessionMessages() 会触发主动查询
  final messagesData = await _agentProxy!.getSessionMessages();
  // 更新UI...
}
```

## 核心改进

### 移除定时器同步

- ❌ 删除 `_syncTimer` 和 `_syncInterval`
- ❌ 删除 `_startBackgroundSync()` 方法
- ❌ 删除构造函数的 `syncInterval` 参数

### 改为主动查询

**初始化时**：
- ✅ 加载本地缓存（快速响应）
- ✅ 立即同步一次远程消息

**打开界面时**：
- ✅ 立即返回本地缓存（用户立即看到消息）
- ✅ 后台主动查询远程消息（确保数据最新）
- ✅ 更新缓存和UI

**远程消息更新时**：
- ✅ 通过 `onStateChanged` 流通知客户端
- ✅ 客户端自动调用 `getSessionMessages()`
- ✅ 触发主动查询，更新缓存和UI

### 保留本地缓存

- ✅ 启动时加载本地缓存（快速响应）
- ✅ 同步后更新本地缓存
- ✅ 同步失败不影响本地缓存使用（离线可用）

## 使用场景

### 场景1：正常在线

1. 重启app → `initialize()` 同步最新消息
2. 打开界面 → 立即看到缓存，后台同步最新消息
3. 远程消息更新 → 自动同步到界面 ✅

### 场景2：离线使用

1. 重启app → `initialize()` 同步失败
2. 打开界面 → 显示本地缓存（离线可用）✅
3. 恢复网络后 → 下次打开界面自动同步 ✅

### 场景3：远程Agent处理消息

1. 用户发送消息 → Agent 开始处理
2. Agent 状态变为 `processing` → 客户端收到通知
3. Agent 处理完成，状态变为 `idle` → 客户端收到通知
4. 客户端自动调用 `getSessionMessages()` → 获取最新消息 ✅

## 优势对比

| 特性 | 定时同步（旧） | 主动查询（新） |
|------|---------------|---------------|
| 启动时同步 | ❌ 延迟30秒 | ✅ 立即同步 |
| 打开界面响应 | ❌ 等待同步 | ✅ 立即显示缓存 |
| 打开界面同步 | ❌ 只在不空时同步 | ✅ 每次都后台同步 |
| 远程更新同步 | ⚠️ 等待定时器 | ✅ 立即同步 |
| 离线可用 | ✅ 支持 | ✅ 支持 |
| 实时性 | ❌ 延迟最多30秒 | ✅ 立即更新 |
| 资源消耗 | ⚠️ 定时占用 | ✅ 按需同步 |

## 代码变更

### 删除的代码
- `Timer? _syncTimer`
- `final Duration _syncInterval`
- `Duration? syncInterval` 构造函数参数
- `_startBackgroundSync()` 方法
- `_syncTimer?.cancel()` 清理逻辑

### 修改的逻辑
- `initialize()`：启动时立即同步
- `getMessages()`：返回缓存 + 主动查询

## 测试验证

所有测试用例通过 ✅：
- ✅ 根据 ID 去重 - 远程消息覆盖本地消息
- ✅ 根据 ID 去重 - 保留待同步的本地消息
- ✅ 合并不同 ID 的消息
- ✅ 按时间排序 - 时间戳乱序
- ✅ 完整场景 - 混合去重和排序

## 总结

从**定时同步模式**改为**主动查询模式**：

### 核心逻辑

1. ✅ 打开agent时：先读取缓存，然后主动查询远程
2. ✅ 监听到远程消息更新：主动查询消息

### 实现优势

- ✅ 解决重启app后消息不更新的问题
- ✅ 提高响应速度，立即显示缓存
- ✅ 提高实时性，打开界面就同步
- ✅ 监听远程更新，自动同步最新消息
- ✅ 保留离线查看能力
- ✅ 减少不必要的资源占用
