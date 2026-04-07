# CachedAgentProxy 缓存方案设计文档

## 核心问题

**AgentProxy 没有缓存到本地，导致离线状态无法查看远程设备的回复消息。**

## 解决方案

通过 `CachedAgentProxy` 包装 `AgentProxy`，根据模式自动决定是否启用缓存：

### 智能缓存策略

```dart
class CachedAgentProxy {
  final AgentProxy _proxy;
  late final bool _needCache;
  
  CachedAgentProxy(...) {
    // 关键：只在远程模式下启用缓存
    _needCache = !_proxy.isLocalMode;
  }
}
```

- **本地模式**（`isLocalMode = true`）：直接透传，不缓存
  - 本地 Agent 已有持久化机制（PersistentChatAdapter）
  - 无需额外缓存

- **远程模式**（`isLocalMode = false`）：启用缓存
  - 消息缓存到本地数据库
  - 支持离线查看
  - 定期后台同步

## 使用方式

### 对用户完全透明

```dart
// 用户代码无需关心缓存细节
final proxy = await deviceClient.getOrCreateAgentProxy(
  employeeId: employee.uuid,
);

// 系统自动判断：
// - 本地模式 → 不启用缓存
// - 远程模式 → 自动启用缓存

// 获取消息（自动选择最优方式）
final messages = await proxy.getMessages();
```

### 检查模式

```dart
if (proxy.isLocalMode) {
  print('本地模式，直接访问本地Agent');
} else {
  print('远程模式，使用缓存支持离线查看');
  print('缓存消息数: ${proxy.cachedMessageCount}');
  print('是否已同步: ${proxy.isSynced}');
}
```

## 远程模式缓存流程

```
用户打开聊天窗口
    ↓
立即从本地缓存加载消息（快速响应）
    ↓
后台启动定时同步（默认30秒一次）
    ↓
同步远程最新消息
    ↓
智能合并本地和远程消息
    ↓
更新本地缓存
```

### 离线查看

```dart
// 在线时同步消息
await proxy.syncWithRemote();

// 断开连接
await deviceClient.disconnect();

// 离线时仍可查看缓存的消息
final messages = await proxy.getMessages();
```

## API 变化

### DeviceClient 接口

```dart
abstract class DeviceClient {
  // 返回类型从 AgentProxy 改为 CachedAgentProxy
  Future<CachedAgentProxy> getOrCreateAgentProxy({
    required String employeeId,
    String? deviceId,
  });
  
  CachedAgentProxy? getAgentProxy(String employeeId);
  List<CachedAgentProxy> getLocalAgentProxies();
}
```

### CachedAgentProxy 方法

所有 `AgentProxy` 的方法都可通过 `CachedAgentProxy` 调用：

- `sendMessage()` - 发送消息
- `getMessages()` - 获取消息
- `interrupt()` - 中断处理
- `revokeMessage()` - 撤回消息
- 等等...

### 缓存相关方法（仅远程模式有效）

```dart
// 同步远程消息
await proxy.syncWithRemote();

// 清除缓存
await proxy.clearCache();

// 监听缓存状态
proxy.onCacheStateChanged.listen((state) {
  print('缓存状态: $state');
});

// 缓存相关属性
print('是否启用缓存: ${proxy.needCache}');
print('缓存消息数: ${proxy.cachedMessageCount}');
print('最后同步时间: ${proxy.lastSyncTime}');
print('是否已同步: ${proxy.isSynced}');
```

## 关键优势

1. **自动化**：系统自动判断是否需要缓存，用户无需关心
2. **透明化**：对用户完全透明，无需修改现有代码
3. **高效性**：本地模式无额外开销，远程模式支持离线查看
4. **一致性**：统一接口，本地和远程使用方式相同

## 实现细节

### CachedAgentProxy 结构

```
CachedAgentProxy
├── AgentProxy (被包装对象)
│   ├── 本地模式: AgentProxy.local (直接调用 IAgent)
│   └── 远程模式: AgentProxy.remote (通过 RPC 调用)
├── MessageStoreService (消息存储服务)
├── 缓存状态管理
│   ├── CacheState (idle/loading/syncing/error)
│   └── 后台同步定时器
└── 消息缓存
    ├── 内存缓存 (_cachedMessages)
    └── 持久化存储 (通过 MessageStoreService)
```

### 消息合并策略

1. **远程有，本地没有** → 添加到本地
2. **本地有，远程没有** → 保留本地（可能是未同步的消息）
3. **双方都有** → 使用最新的（比较时间戳）

## 测试验证

```dart
// 本地模式测试
final proxy = await deviceClient.getOrCreateAgentProxy(
  employeeId: localEmployeeId,
);
expect(proxy.isLocalMode, isTrue);
expect(proxy.needCache, isFalse);  // 不启用缓存

// 远程模式测试
final proxy = await deviceClient.getOrCreateAgentProxy(
  employeeId: remoteEmployeeId,
  deviceId: 'other-device',
);
expect(proxy.isLocalMode, isFalse);
expect(proxy.needCache, isTrue);  // 启用缓存
```

## 总结

这个方案通过智能判断，实现了：

- ✅ 本地模式无额外开销
- ✅ 远程模式支持离线查看
- ✅ 对用户完全透明
- ✅ 无需修改现有业务代码
- ✅ 统一的使用体验
