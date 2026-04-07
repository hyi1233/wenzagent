# 工具调用事件广播修复方案

## 问题分析

在远程模式下，工具调用事件（`toolCallStart` 和 `toolCallResult`）没有通过LAN网络广播，导致界面无法收到这些事件，从而无法刷新显示工具调用的进度和结果。

### 根本原因

1. **事件过滤机制**：`_broadcastAgentEvent` 方法只广播 `agentStatusChanged` 和 `messageStatusChanged` 事件，其他事件类型（包括工具调用事件）会直接返回，不会广播。

2. **缺少LAN消息类型**：`LanMessageType` 枚举中没有定义工具调用相关的消息类型。

3. **消息处理器缺失**：`_handleMessage` 方法中也没有处理工具调用事件的逻辑。

## 解决方案

### 1. 添加工具调用事件的LAN消息类型

在 `lib/src/entity/lan_message.dart` 中添加两个新的消息类型：

```dart
/// LAN 消息类型枚举
enum LanMessageType {
  // ... 其他类型 ...

  /// Agent 消息状态变更
  agentMessageStatusChanged,

  /// Agent 工具调用开始
  toolCallStart,

  /// Agent 工具调用结果
  toolCallResult,

  /// Agent 权限请求变更
  agentPermissionChanged,

  // ... 其他类型 ...
}
```

### 2. 修改广播逻辑

在 `lib/src/device/impl/device_client_impl.dart` 中修改 `_broadcastAgentEvent` 方法：

```dart
/// 广播 Agent 事件
void _broadcastAgentEvent(String employeeId, Map<String, dynamic> event) {
  final lanClient = _lanClient;
  if (lanClient == null || !lanClient.isConnected) return;

  final type = event['type'] as String?;
  final data = event['data'] as Map<String, dynamic>? ?? {};

  LanMessageType msgType;
  switch (type) {
    case 'agentStatusChanged':
      msgType = LanMessageType.agentStatusChanged;
    case 'messageStatusChanged':
      msgType = LanMessageType.agentMessageStatusChanged;
    case 'toolCallStart':  // 新增
      msgType = LanMessageType.toolCallStart;
    case 'toolCallResult':  // 新增
      msgType = LanMessageType.toolCallResult;
    default:
      return;
  }

  final msg = LanMessage(
    type: msgType,
    fromId: deviceId,
    content: jsonEncode({
      'employeeId': employeeId,
      'type': type,
      'data': data,
    }),
    topic: topic,
  );

  lanClient.sendLanMessage(msg);
}
```

### 3. 修改消息处理器

在 `_handleMessage` 方法中添加对工具调用事件的处理：

```dart
void _handleMessage(LanMessage msg) {
  // ... 其他处理 ...

  switch (msg.type) {
    // ... 其他case ...
    case LanMessageType.agentStatusChanged:
    case LanMessageType.agentMessageStatusChanged:
    case LanMessageType.toolCallStart:      // 新增
    case LanMessageType.toolCallResult:     // 新增
      _handleAgentEvent(msg);
    // ... 其他case ...
  }
}
```

## 事件流路径

### 修复前（工具调用事件丢失）

```
远程 LangChainChatAdapter.streamMessage()
    ↓
yield StreamResponse.toolCallStart()
    ↓
_toolEventCallback?.call({'type': 'toolCallStart', ...})
    ↓
_eventController.add({'type': 'toolCallStart', ...})
    ↓
_broadcastAgentEvent() → 过滤掉toolCallStart事件 ❌
    ↓
LAN网络广播 → 无工具调用事件 ❌
    ↓
本地界面监听onEvent流 → 收不到工具调用事件 ❌
```

### 修复后（工具调用事件正常传递）

```
远程 LangChainChatAdapter.streamMessage()
    ↓
yield StreamResponse.toolCallStart()
    ↓
_toolEventCallback?.call({'type': 'toolCallStart', ...})
    ↓
_eventController.add({'type': 'toolCallStart', ...})
    ↓
_broadcastAgentEvent() → 处理toolCallStart事件 ✅
    ↓
LAN网络广播 → 发送工具调用事件 ✅
    ↓
本地设备接收 → _handleMessage() → _handleAgentEvent()
    ↓
本地界面监听onEvent流 → 收到工具调用事件 ✅
```

## 数据格式

工具调用事件的数据格式：

### toolCallStart

```json
{
  "type": "toolCallStart",
  "employeeId": "employee-uuid",
  "data": {
    "toolCallId": "call-123",
    "name": "search",
    "arguments": "{\"query\": \"example\"}"
  }
}
```

### toolCallResult

```json
{
  "type": "toolCallResult",
  "employeeId": "employee-uuid",
  "data": {
    "toolCallId": "call-123",
    "name": "search",
    "result": "搜索结果...",
    "isError": false
  }
}
```

## 影响范围

### 正面影响

1. **界面可以正确显示工具调用进度**：远程设备的工具调用事件可以正确传递到界面。
2. **保持事件流一致性**：所有Agent事件（状态、消息、工具调用）都能通过LAN网络广播。
3. **向后兼容**：不影响现有的事件处理逻辑。

### 需要注意的点

1. **网络流量增加**：工具调用事件现在会通过网络广播，增加少量网络流量。
2. **事件处理顺序**：确保工具调用事件的处理不会阻塞其他事件的处理。

## 测试建议

### 测试场景1：远程工具调用显示

1. 在设备A上创建一个Agent并执行带工具调用的消息
2. 在设备B上远程访问该Agent
3. 验证设备B的界面能正确显示工具调用的开始和结果

### 测试场景2：多设备同步

1. 在设备A上执行工具调用
2. 验证其他在线设备能收到工具调用事件
3. 验证工具调用事件不会重复处理

### 测试场景3：离线场景

1. 设备A执行工具调用
2. 设备B离线
3. 设备B重新上线后，验证能正确同步工具调用历史

## 相关文件

- `lib/src/entity/lan_message.dart` - LAN消息类型定义
- `lib/src/device/impl/device_client_impl.dart` - 设备客户端实现
- `lib/src/agent/client/agent_proxy.dart` - Agent代理接口
- `lib/src/agent/impl/agent_impl.dart` - Agent实现

## 总结

通过添加工具调用事件的LAN消息类型支持，修复了远程模式下工具调用事件无法广播的问题。现在，工具调用事件可以正确地通过网络传递到所有相关设备，界面可以实时显示工具调用的进度和结果。
