# AgentProxy 消息队列功能说明

## 概述

AgentProxy 现在包含一个消息队列功能，用于存储已发送但未被查询确认的**完整消息内容**。这个功能可以帮助前端直接渲染待确认的消息，提供更好的用户体验。

## 功能说明

### 消息队列的作用

当通过 AgentProxy 发送消息时，消息会进入 Agent 内部的处理队列。为了方便前端立即显示用户发送的消息（而无需等待 `getSessionMessages()` 返回），AgentProxy 维护了一个待确认消息队列，存储完整的消息内容。

- **发送消息时**：完整消息内容被添加到待确认队列
- **查询消息列表时**：如果返回的消息ID在待确认队列中，则从队列中移除
- **前端渲染**：可以直接使用待确认队列中的消息内容进行渲染

### 使用场景

1. **即时消息显示**：前端可以立即显示用户发送的消息，无需等待持久化
2. **消息状态监控**：了解有多少消息已发送但还未被查询确认
3. **调试辅助**：跟踪消息的发送和确认状态
4. **可靠性保证**：确保消息被正确处理和持久化

## API 说明

### 公共属性

```dart
/// 待确认消息队列长度
int get pendingMessageQueueLength

/// 待确认消息列表（只读副本，包含完整消息内容）
List<Map<String, dynamic>> get pendingMessages

/// 待确认消息ID列表（只读副本）
List<String> get pendingMessageIds
```

### 使用示例

#### 基本使用

```dart
// 创建 AgentProxy
final agentProxy = AgentProxy.local(
  employeeId: 'emp-001',
  deviceId: 'dev-001',
  localAgent: localAgent,
);

// 发送消息
final messageId = await agentProxy.sendMessage({
  'content': '你好',
  'type': 'text',
});

// 检查待确认队列
print('待确认消息数量: ${agentProxy.pendingMessageQueueLength}');
print('待确认消息ID: ${agentProxy.pendingMessageIds}');
print('待确认消息内容:');
for (final msg in agentProxy.pendingMessages) {
  print('  - ${msg['content']}');
}
// 输出: 待确认消息数量: 1
//       待确认消息ID: [msg_xxx]
//       待确认消息内容:
//         - 你好

// 查询消息列表（此时消息已被持久化）
final messages = await agentProxy.getSessionMessages();

// 再次检查队列（已清空）
print('待确认消息数量: ${agentProxy.pendingMessageQueueLength}');
// 输出: 待确认消息数量: 0
```

#### 前端即时渲染（推荐用法）

```dart
// Flutter Widget 示例
class MessageListWidget extends StatelessWidget {
  final AgentProxy agentProxy;

  const MessageListWidget({required this.agentProxy});

  @override
  Widget build(BuildContext context) {
    // 获取已持久化的消息
    final persistedMessages = await agentProxy.getSessionMessages();

    // 获取待确认的消息
    final pendingMessages = agentProxy.pendingMessages;

    // 合并显示：持久化消息 + 待确认消息
    return ListView.builder(
      itemCount: persistedMessages.length + pendingMessages.length,
      itemBuilder: (context, index) {
        if (index < persistedMessages.length) {
          // 已持久化的消息
          final msg = persistedMessages[index];
          return MessageTile(
            content: msg['content'],
            status: '已发送',
          );
        } else {
          // 待确认的消息
          final pendingIndex = index - persistedMessages.length;
          final msg = pendingMessages[pendingIndex];
          return MessageTile(
            content: msg['content'],
            status: '发送中...', // 显示不同的状态
            isPending: true,
          );
        }
      },
    );
  }
}
```

#### 监控消息状态

```dart
// 定期检查待确认消息
Timer.periodic(Duration(seconds: 5), (timer) async {
  final pendingCount = agentProxy.pendingMessageQueueLength;
  if (pendingCount > 0) {
    print('有 $pendingCount 条消息待确认');
    print('消息ID: ${agentProxy.pendingMessageIds}');
  }
});
```

#### 远程模式使用

```dart
// 创建远程 AgentProxy
final agentProxy = AgentProxy.remote(
  employeeId: 'emp-001',
  deviceId: 'dev-001',
  rpcCall: (method, params) async {
    // 实现 RPC 调用
    return await remoteCall(method, params);
  },
);

// 发送消息
final messageId = await agentProxy.sendMessage({
  'content': '远程消息',
});

// 检查队列
print('待确认消息数量: ${agentProxy.pendingMessageQueueLength}');

// 查询消息列表
final messages = await agentProxy.getSessionMessages();
// 返回的消息会自动从队列中移除
```

## 工作原理

### 本地模式

```
1. 调用 sendMessage()
   └─> AgentProxy 创建消息副本
   └─> 添加必要字段（id, createdAt, role）
   └─> 将完整消息内容添加到待确认队列
   └─> 调用本地 Agent 的 sendMessage()
       └─> 消息进入处理队列

2. 调用 getSessionMessages()
   └─> 调用本地 Agent 的 getSessionMessages()
   └─> 返回持久化的消息列表
   └─> AgentProxy 检查返回的消息ID
   └─> 从待确认队列中移除已返回的消息
```

### 远程模式

```
1. 调用 sendMessage()
   └─> AgentProxy 创建消息副本
   └─> 添加必要字段（id, createdAt, role）
   └─> 将完整消息内容添加到待确认队列
   └─> 通过 RPC 调用远程 Agent
       └─> 远程 Agent 处理消息

2. 调用 getSessionMessages()
   └─> 通过 RPC 调用远程 Agent
   └─> 返回持久化的消息列表
   └─> AgentProxy 检查返回的消息ID
   └─> 从待确认队列中移除已返回的消息
```

### 消息内容保证

发送消息时，AgentProxy 会确保消息包含以下字段：

```dart
{
  'id': 'msg_xxx',           // 消息唯一ID
  'content': '消息内容',      // 原始消息内容
  'role': 'user',            // 角色（默认为 user）
  'type': 'text',            // 消息类型（保留原始值）
  'createdAt': '2026-04-07T...', // 创建时间（ISO8601格式）
  ...其他自定义字段...         // 所有自定义字段都会保留
}
```

## 注意事项

1. **消息内容完整性**：待确认队列存储的是完整的消息内容，包括所有原始字段和自动添加的字段

2. **消息ID生成**：如果在 `messageData` 中提供了 `id` 字段，将使用该ID；否则会自动生成一个唯一ID

3. **队列清理**：当调用 `getSessionMessages()` 时，所有返回的消息ID都会从待确认队列中移除

4. **线程安全**：待确认队列在 Dart 的单线程模型下是安全的，不需要额外的锁机制

5. **性能影响**：队列操作是轻量级的，对性能影响可以忽略不计

6. **消息撤回**：如果调用 `revokeMessage()` 撤回消息，该消息仍会保留在待确认队列中，直到下次调用 `getSessionMessages()`

7. **自定义字段**：所有自定义字段都会被保留在待确认队列中，前端可以直接使用

8. **前端渲染**：建议在渲染时区分"已持久化"和"待确认"的消息，提供不同的视觉反馈

## 相关方法

- `sendMessage(messageData)` - 发送消息并返回消息ID
- `getSessionMessages()` - 获取会话消息列表，并清理待确认队列
- `revokeMessage(messageId)` - 撤回消息
- `clearCurrentSession()` - 清空当前会话（不会清理待确认队列）

## 示例场景

### 场景1：Flutter 消息列表渲染（推荐）

```dart
class MessageListWidget extends StatefulWidget {
  final AgentProxy agentProxy;

  const MessageListWidget({required this.agentProxy});

  @override
  _MessageListWidgetState createState() => _MessageListWidgetState();
}

class _MessageListWidgetState extends State<MessageListWidget> {
  List<Map<String, dynamic>> _persistedMessages = [];

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    final messages = await widget.agentProxy.getSessionMessages();
    setState(() {
      _persistedMessages = messages;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pendingMessages = widget.agentProxy.pendingMessages;
    final allMessages = [..._persistedMessages, ...pendingMessages];

    return ListView.builder(
      itemCount: allMessages.length,
      itemBuilder: (context, index) {
        final msg = allMessages[index];
        final isPending = index >= _persistedMessages.length;

        return ListTile(
          title: Text(msg['content'] ?? ''),
          subtitle: Text(
            isPending ? '发送中...' : '已发送',
            style: TextStyle(
              color: isPending ? Colors.orange : Colors.green,
            ),
          ),
          trailing: isPending
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.check_circle, color: Colors.green),
        );
      },
    );
  }
}
```

### 场景2：实时消息状态更新

```dart
// 使用 StreamBuilder 实时显示消息状态
class RealtimeMessageList extends StatelessWidget {
  final AgentProxy agentProxy;

  const RealtimeMessageList({required this.agentProxy});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: agentProxy.onStateChanged,
      builder: (context, snapshot) {
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: agentProxy.getSessionMessages(),
          builder: (context, persistedSnapshot) {
            final persisted = persistedSnapshot.data ?? [];
            final pending = agentProxy.pendingMessages;

            return ListView(
              children: [
                // 已持久化的消息
                ...persisted.map((msg) => MessageTile(
                  message: msg,
                  status: MessageStatus.sent,
                )),

                // 待确认的消息
                ...pending.map((msg) => MessageTile(
                  message: msg,
                  status: MessageStatus.pending,
                )),
              ],
            );
          },
        );
      },
    );
  }
}

enum MessageStatus { pending, sent, failed }

class MessageTile extends StatelessWidget {
  final Map<String, dynamic> message;
  final MessageStatus status;

  const MessageTile({
    required this.message,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message['content'] ?? ''),
                if (status == MessageStatus.pending)
                  Text(
                    '发送中...',
                    style: TextStyle(color: Colors.orange, fontSize: 12),
                  ),
              ],
            ),
          ),
          if (status == MessageStatus.pending)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}
```

### 场景3：批量发送和渲染

```dart
// 批量发送消息，立即显示
Future<void> sendBatchMessages(AgentProxy agentProxy) async {
  final messages = [
    '消息 1',
    '消息 2',
    '消息 3',
  ];

  for (final content in messages) {
    await agentProxy.sendMessage({'content': content});
    // 发送后立即可以在 pendingMessages 中看到
    print('待确认: ${agentProxy.pendingMessageQueueLength}');
  }

  // 所有消息都在待确认队列中，前端可以立即渲染
  for (final msg in agentProxy.pendingMessages) {
    print('待确认消息: ${msg['content']}');
  }
}
```

### 场景4：自定义字段渲染

```dart
// 发送包含自定义字段的消息
await agentProxy.sendMessage({
  'content': '查看这个文件',
  'type': 'file',
  'fileName': 'document.pdf',
  'fileSize': '2.5MB',
  'customData': {'key': 'value'},
});

// 渲染时可以访问所有自定义字段
final pendingMsgs = agentProxy.pendingMessages;
for (final msg in pendingMsgs) {
  if (msg['type'] == 'file') {
    print('文件名: ${msg['fileName']}');
    print('大小: ${msg['fileSize']}');
  }
}
```

## 总结

AgentProxy 的消息队列功能提供了一种简单而有效的方式来存储和跟踪消息的完整内容。通过这个功能，你可以：

- **即时显示消息**：前端无需等待持久化完成即可显示用户发送的消息
- **更好的用户体验**：提供"发送中"状态反馈，让用户知道消息正在处理
- **完整消息内容**：保留所有原始字段和自定义数据，方便前端渲染
- **自动管理队列**：消息确认后自动从队列中移除，无需手动清理
- **统一接口**：本地模式和远程模式使用方式完全一致

### 前端集成建议

1. **消息合并显示**：将 `getSessionMessages()` 返回的持久化消息与 `pendingMessages` 合并显示
2. **状态区分**：使用不同的视觉样式区分"已发送"和"发送中"状态
3. **自动刷新**：监听 `onStateChanged` 流，在状态变化时刷新消息列表
4. **错误处理**：如果消息发送失败，可以从待确认队列中移除并显示错误提示

### 性能优化

- 队列操作是 \(O(n)\) 复杂度，其中 n 是队列长度
- 对于大多数应用场景，性能影响可以忽略不计
- 如果队列长度超过预期，可以考虑限制队列大小或定期清理

这个功能让前端能够提供更流畅的消息发送体验，是现代即时通讯应用的标配功能！
