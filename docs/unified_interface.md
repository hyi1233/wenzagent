# CachedAgentProxy 接口说明

## 统一接口设计

### 核心方法

```dart
abstract class DeviceClient {
  /// 获取或创建 AgentProxy
  /// 返回统一的 CachedAgentProxy 类型
  Future<CachedAgentProxy> getOrCreateAgentProxy({
    required String employeeId,
    String? deviceId,
  });

  /// 获取已创建的 AgentProxy
  /// 会依次查找本地代理和远程代理
  CachedAgentProxy? getAgentProxy(String employeeId);

  /// 获取所有本地 AgentProxy
  List<CachedAgentProxy> getLocalAgentProxies();
  
  /// 获取所有远程 AgentProxy
  List<CachedAgentProxy> getRemoteAgentProxies();
  
  /// 获取所有 AgentProxy（本地 + 远程）
  List<CachedAgentProxy> getAllAgentProxies();
}
```

### 智能缓存机制

```dart
class CachedAgentProxy {
  late final bool _needCache;
  
  CachedAgentProxy(...) {
    // 自动判断是否需要缓存
    _needCache = !_proxy.isLocalMode;
  }
}
```

- **本地模式**（`isLocalMode = true`）：`needCache = false`
  - 直接透传调用本地 Agent
  - 无额外缓存开销
  
- **远程模式**（`isLocalMode = false`）：`needCache = true`
  - 消息缓存到本地数据库
  - 支持离线查看
  - 定期后台同步

### 使用示例

#### 1. 获取代理

```dart
// 本地代理
final localProxy = await deviceClient.getOrCreateAgentProxy(
  employeeId: 'local-employee-001',
);

// 远程代理
final remoteProxy = await deviceClient.getOrCreateAgentProxy(
  employeeId: 'remote-employee-001',
  deviceId: 'device-002',
);

// 统一类型
print(localProxy.runtimeType);  // CachedAgentProxy
print(remoteProxy.runtimeType); // CachedAgentProxy
```

#### 2. 查找代理

```dart
// getAgentProxy() 会自动查找本地和远程
final proxy = deviceClient.getAgentProxy('employee-001');

if (proxy != null) {
  print('找到代理: ${proxy.employeeId}');
  print('模式: ${proxy.isLocalMode ? "本地" : "远程"}');
  print('缓存: ${proxy.needCache ? "启用" : "不启用"}');
}
```

#### 3. 获取代理列表

```dart
// 所有本地代理
final localProxies = deviceClient.getLocalAgentProxies();
print('本地代理: ${localProxies.length}');

// 所有远程代理
final remoteProxies = deviceClient.getRemoteAgentProxies();
print('远程代理: ${remoteProxies.length}');

// 所有代理
final allProxies = deviceClient.getAllAgentProxies();
print('总代理数: ${allProxies.length}');
```

#### 4. 统一使用方式

```dart
// 无论是本地还是远程，使用方式都一样
for (final proxy in allProxies) {
  // 发送消息
  await proxy.sendMessage(
    MessageInput(content: '你好', type: 'text'),
  );
  
  // 获取消息
  final messages = await proxy.getMessages();
  print('${proxy.employeeId}: ${messages.length} 条消息');
  
  // 远程模式特有功能
  if (proxy.needCache) {
    print('缓存: ${proxy.cachedMessageCount} 条');
    print('同步: ${proxy.isSynced}');
  }
}
```

#### 5. 离线查看（仅远程模式）

```dart
// 在线时同步消息
await remoteProxy.syncWithRemote();

// 断开连接
await deviceClient.disconnect();

// 离线时仍可查看缓存的消息
final messages = await remoteProxy.getMessages();
print('离线查看: ${messages.length} 条消息');
```

### 关键优势

1. **统一接口**：所有方法返回 `CachedAgentProxy`，无需区分类型
2. **自动判断**：系统自动决定是否启用缓存
3. **透明使用**：用户无需关心缓存细节
4. **类型安全**：编译时类型检查，避免运行时错误
5. **易于维护**：代码简洁，逻辑清晰

### 注意事项

- `getAgentProxy()` 会依次查找本地和远程代理
- 本地代理优先查找（性能更好）
- 所有代理都返回统一的 `CachedAgentProxy` 类型
- 通过 `isLocalMode` 和 `needCache` 区分行为
