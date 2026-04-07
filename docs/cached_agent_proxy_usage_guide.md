# CachedAgentProxy 使用指南

## 问题解决

### 问题描述

界面打开后，只显示了用户的消息，没有显示assistant的回复消息。

### 问题原因

1. **消息同步时机不对**：界面打开时立即返回缓存，后台异步同步，如果界面没有正确监听消息变更，会导致assistant消息不显示
2. **消息合并逻辑问题**：本地消息的 `localOnly` 标记可能导致合并时优先使用本地旧消息
3. **缺少主动同步机制**：发送消息后没有主动同步获取assistant回复

### 解决方案

#### 1. 改进消息同步策略

**修改前**：
```dart
// 只在必要时才同步
if (_shouldSync()) {
  syncWithRemote().catchError((e) {
    print('后台同步失败: $e');
  });
}
```

**修改后**：
```dart
// 每次getMessages都触发后台同步，确保获取最新的assistant消息
syncWithRemote().catchError((e) {
  print('后台同步失败: $e');
});
```

#### 2. 发送消息后主动同步

```dart
// 发送成功后，延迟同步获取assistant的回复
Future.delayed(const Duration(milliseconds: 500), () {
  syncWithRemote().catchError((e) {
    print('发送后同步失败: $e');
  });
});
```

#### 3. 简化消息状态判断

**修改前**：
```dart
bool _isLocalPendingMessage(AgentMessage message) {
  if (message.status == 'pending') return true;
  if (message.metadata?['localOnly'] == true) return true;
  if (message.metadata?['updateTime'] == null) return true;  // ❌ 可能误判
  return false;
}
```

**修改后**：
```dart
bool _isLocalPendingMessage(AgentMessage message) {
  // 只判断真正需要重试的消息
  if (message.status == 'pending' || message.status == 'failed') {
    return true;
  }
  // 只判断真正未确认的消息
  if (message.metadata?['localOnly'] == true) {
    return true;
  }
  return false;
}
```

## 正确的使用方式

### 1. 初始化

```dart
final proxy = CachedAgentProxy(
  proxy: agentProxy,
  messageStore: messageStore,
  deviceId: deviceId,
  employeeId: employeeId,
);

// 初始化会加载本地缓存并同步一次远程消息
await proxy.initialize();
```

### 2. 监听消息变更

```dart
// 方式1：监听消息流（推荐）
proxy.onMessagesChanged.listen((messages) {
  print('消息已更新: ${messages.length} 条');
  // 更新UI
  updateMessageList(messages);
});

// 方式2：监听状态变化并主动同步
proxy.onStateChanged.listen((state) {
  print('Agent状态: ${state.status}');
  
  // 当Agent从processing变为idle时，同步获取最新消息
  if (state.status == AgentStatus.idle) {
    proxy.syncOnStateChange().then((_) {
      print('同步完成');
    });
  }
});
```

### 3. 发送消息

```dart
// 发送消息会自动：
// 1. 生成本地消息（立即可见）
// 2. 发送到远程
// 3. 更新消息状态
// 4. 延迟500ms同步获取assistant回复
final messageId = await proxy.sendMessage(
  MessageInput(content: '你好'),
);
```

### 4. 获取消息

```dart
// 方式1：快速加载（先返回缓存，后台同步）
final messages = await proxy.getMessages();

// 方式2：强制刷新（等待同步完成）
final freshMessages = await proxy.getMessagesForceRefresh();

// 方式3：状态变化时同步
proxy.onStateChanged.listen((state) {
  if (state.status == AgentStatus.idle) {
    proxy.syncOnStateChange();
  }
});
```

## 完整示例

### Flutter Widget 示例

```dart
class ChatPage extends StatefulWidget {
  final CachedAgentProxy proxy;
  
  const ChatPage({super.key, required this.proxy});
  
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  List<AgentMessage> _messages = [];
  StreamSubscription? _messageSubscription;
  StreamSubscription? _stateSubscription;
  
  @override
  void initState() {
    super.initState();
    _initialize();
  }
  
  Future<void> _initialize() async {
    // 1. 监听消息变更
    _messageSubscription = widget.proxy.onMessagesChanged.listen((messages) {
      setState(() {
        _messages = messages;
      });
    });
    
    // 2. 监听状态变化
    _stateSubscription = widget.proxy.onStateChanged.listen((state) {
      // Agent处理完成后，主动同步获取最新消息
      if (state.status == AgentStatus.idle) {
        widget.proxy.syncOnStateChange();
      }
    });
    
    // 3. 加载初始消息
    final messages = await widget.proxy.getMessages();
    setState(() {
      _messages = messages;
    });
  }
  
  Future<void> _sendMessage(String content) async {
    try {
      // 发送消息会自动同步
      await widget.proxy.sendMessage(
        MessageInput(content: content),
      );
    } catch (e) {
      // 处理发送失败
      print('发送失败: $e');
    }
  }
  
  @override
  void dispose() {
    _messageSubscription?.cancel();
    _stateSubscription?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        return ListTile(
          title: Text(message.content ?? ''),
          subtitle: Text(message.role),
        );
      },
    );
  }
}
```

## 核心改进总结

### 1. 客户端生成UUID
- ✅ 避免依赖远程ID生成
- ✅ 确保消息ID唯一性
- ✅ 立即可见，无需等待

### 2. 智能消息合并
- ✅ 基于ID和updateTime的智能合并
- ✅ 优先使用最新版本
- ✅ 保留本地待同步消息

### 3. 主动同步机制
- ✅ 发送消息后主动同步（延迟500ms）
- ✅ 状态变化时主动同步
- ✅ 每次获取消息都触发后台同步

### 4. 完善的通知机制
- ✅ `onMessagesChanged` 流通知界面更新
- ✅ `onStateChanged` 流通知Agent状态变化
- ✅ `syncOnStateChange()` 方法用于状态变化时同步

## 注意事项

1. **必须监听 `onMessagesChanged`**：后台同步完成后会通过此流通知界面更新
2. **建议监听 `onStateChanged`**：Agent状态变化时主动同步获取最新消息
3. **避免频繁同步**：虽然每次 `getMessages()` 都会触发后台同步，但有同步锁机制防止并发
4. **离线可用**：即使同步失败，也能显示本地缓存的消息

## 调试建议

如果遇到消息不显示的问题，请检查：

1. 是否正确调用了 `initialize()`
2. 是否正确监听了 `onMessagesChanged` 流
3. 是否正确监听了 `onStateChanged` 流
4. 检查同步日志：`syncWithRemote()` 和 `_mergeMessages()` 的输出
5. 检查消息合并结果：打印 `_cachedMessages` 的长度和内容
