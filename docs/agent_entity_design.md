# Agent/Proxy Entity 设计方案

## 一、现状分析

### 1.1 当前 Map 存储对象统计

| 位置 | 变量名 | 类型 | 用途 | 是否需要 Entity |
|------|--------|------|------|----------------|
| `AgentProxy` | `_pendingMessageQueue` | `List<Map<String, dynamic>>` | 待确认消息队列 | ✅ 需要 |
| `AgentImpl` | `_pendingPermissions` | `Map<String, Completer>` | 权限请求 Completer | ❌ 不需要（运行时对象） |
| `AgentImpl` | `_pendingPermissionRequests` | `Map<String, AgentPermissionRequest>` | 权限请求信息 | ✅ 已有 `AgentPermissionRequest` |
| `TrackedMessage` | `messageData` | `Map<String, dynamic>` | 消息数据 | ✅ 需要统一 |
| `MessageQueueItem` | `messageData` | `Map<String, dynamic>` | 消息队列项数据 | ✅ 需要统一 |
| `MessageWrapper` | `message` | `ChatMessage` | LangChain 消息 | ✅ 已有 |
| `SessionHistory` | `messagesMap` | `Map<String, List<MessageWrapper>>` | 会话消息历史 | ✅ 已有 |
| `ProviderConfig` | 多个字段 | `Map<String, dynamic>` | 模型配置 | ✅ 已有 |

### 1.2 主要问题

1. **消息数据结构不统一**
   - `TrackedMessage` 使用 `Map<String, dynamic>` 存储消息
   - `MessageQueueItem` 使用 `Map<String, dynamic>` 存储消息
   - `AgentProxy._pendingMessageQueue` 使用 `Map<String, dynamic>` 存储消息
   - 缺乏统一的消息模型

2. **类型安全性不足**
   - 使用 `Map<String, dynamic>` 导致类型不安全
   - 容易出现字段拼写错误
   - IDE 自动补全支持差

3. **字段一致性无法保证**
   - 不同位置的 Map 可能有不同的字段
   - 缺乏字段约束和验证

## 二、设计方案

### 2.1 核心设计原则

1. **类型安全**：使用强类型 Entity 替代 `Map<String, dynamic>`
2. **不可变性**：Entity 类设计为不可变（immutable）
3. **序列化支持**：提供 `toMap()` 和 `fromMap()` 方法
4. **向后兼容**：支持从旧的 Map 格式迁移
5. **领域驱动**：Entity 类应反映业务领域概念

### 2.2 Entity 层次结构

```
lib/src/agent/entity/
├── agent_message.dart          # 消息基类
├── agent_message_types.dart    # 消息类型定义
├── pending_message.dart        # 待确认消息
├── queued_message.dart         # 队列消息
└── permission_request.dart     # 权限请求（已存在）
```

### 2.3 核心 Entity 设计

#### 2.3.1 AgentMessage - 统一消息基类

```dart
/// Agent 消息基类
///
/// 所有 Agent 相关消息的统一基类，提供标准字段和序列化方法
class AgentMessage {
  /// 消息唯一ID
  final String id;

  /// 消息角色 (user/assistant/system/tool)
  final String role;

  /// 消息类型 (text/functionCall/functionResult)
  final String type;

  /// 消息内容
  final String? content;

  /// 创建时间
  final DateTime createdAt;

  /// 工具调用ID（可选）
  final String? toolCallId;

  /// 工具名称（可选）
  final String? toolName;

  /// 工具参数（可选）
  final Map<String, dynamic>? toolArguments;

  /// 工具结果（可选）
  final String? toolResult;

  /// 工具调用列表（可选，用于多条工具调用）
  final List<ToolCall>? toolCalls;

  /// 元数据（可选，用于存储自定义字段）
  final Map<String, dynamic>? metadata;

  const AgentMessage({
    required this.id,
    this.role = 'user',
    this.type = 'text',
    this.content,
    required this.createdAt,
    this.toolCallId,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolCalls,
    this.metadata,
  });

  /// 从 Map 创建
  factory AgentMessage.fromMap(Map<String, dynamic> map) {
    return AgentMessage(
      id: map['id'] as String,
      role: map['role'] as String? ?? 'user',
      type: map['type'] as String? ?? 'text',
      content: map['content'] as String?,
      createdAt: map['createdAt'] is DateTime
          ? map['createdAt'] as DateTime
          : DateTime.parse(map['createdAt'] as String),
      toolCallId: map['toolCallId'] as String?,
      toolName: map['toolName'] as String?,
      toolArguments: map['toolArguments'] as Map<String, dynamic>?,
      toolResult: map['toolResult'] as String?,
      toolCalls: map['toolCalls'] != null
          ? (map['toolCalls'] as List)
              .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
              .toList()
          : null,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'role': role,
      'type': type,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      if (toolCallId != null) 'toolCallId': toolCallId,
      if (toolName != null) 'toolName': toolName,
      if (toolArguments != null) 'toolArguments': toolArguments,
      if (toolResult != null) 'toolResult': toolResult,
      if (toolCalls != null)
        'toolCalls': toolCalls!.map((tc) => tc.toMap()).toList(),
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// 复制并修改
  AgentMessage copyWith({
    String? id,
    String? role,
    String? type,
    String? content,
    DateTime? createdAt,
    String? toolCallId,
    String? toolName,
    Map<String, dynamic>? toolArguments,
    String? toolResult,
    List<ToolCall>? toolCalls,
    Map<String, dynamic>? metadata,
  }) {
    return AgentMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      toolArguments: toolArguments ?? this.toolArguments,
      toolResult: toolResult ?? this.toolResult,
      toolCalls: toolCalls ?? this.toolCalls,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// 工具调用
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory ToolCall.fromMap(Map<String, dynamic> map) {
    return ToolCall(
      id: map['id'] as String,
      name: map['name'] as String,
      arguments: map['arguments'] as Map<String, dynamic>,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'arguments': arguments,
    };
  }
}
```

#### 2.3.2 PendingMessage - 待确认消息

```dart
/// 待确认消息
///
/// 存储在 AgentProxy 的待确认队列中
/// 包含完整的消息内容和前端渲染所需的所有字段
class PendingMessage extends AgentMessage {
  /// 发送时间（用于前端显示）
  final DateTime sentAt;

  /// 消息状态
  final PendingMessageStatus status;

  /// 设备ID（可选，用于多设备场景）
  final String? deviceId;

  /// 员工ID（可选，用于多员工场景）
  final String? employeeId;

  const PendingMessage({
    required super.id,
    super.role,
    super.type,
    super.content,
    required super.createdAt,
    super.toolCallId,
    super.toolName,
    super.toolArguments,
    super.toolResult,
    super.toolCalls,
    super.metadata,
    required this.sentAt,
    this.status = PendingMessageStatus.pending,
    this.deviceId,
    this.employeeId,
  });

  /// 从 Map 创建（兼容旧格式）
  factory PendingMessage.fromMap(Map<String, dynamic> map) {
    return PendingMessage(
      id: map['id'] as String,
      role: map['role'] as String? ?? 'user',
      type: map['type'] as String? ?? 'text',
      content: map['content'] as String?,
      createdAt: _parseDateTime(map['createdAt']),
      toolCallId: map['toolCallId'] as String?,
      toolName: map['toolName'] as String?,
      toolArguments: map['toolArguments'] as Map<String, dynamic>?,
      toolResult: map['toolResult'] as String?,
      toolCalls: map['toolCalls'] != null
          ? (map['toolCalls'] as List)
              .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
              .toList()
          : null,
      metadata: map['metadata'] as Map<String, dynamic>?,
      sentAt: _parseDateTime(map['sentAt'] ?? map['createdAt']),
      status: PendingMessageStatus.values.firstWhere(
        (e) => e.name == (map['status'] as String? ?? 'pending'),
        orElse: () => PendingMessageStatus.pending,
      ),
      deviceId: map['deviceId'] as String?,
      employeeId: map['employeeId'] as String?,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    final map = super.toMap();
    return {
      ...map,
      'sentAt': sentAt.toIso8601String(),
      'status': status.name,
      if (deviceId != null) 'deviceId': deviceId,
      if (employeeId != null) 'employeeId': employeeId,
    };
  }

  @override
  PendingMessage copyWith({
    String? id,
    String? role,
    String? type,
    String? content,
    DateTime? createdAt,
    String? toolCallId,
    String? toolName,
    Map<String, dynamic>? toolArguments,
    String? toolResult,
    List<ToolCall>? toolCalls,
    Map<String, dynamic>? metadata,
    DateTime? sentAt,
    PendingMessageStatus? status,
    String? deviceId,
    String? employeeId,
  }) {
    return PendingMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      toolArguments: toolArguments ?? this.toolArguments,
      toolResult: toolResult ?? this.toolResult,
      toolCalls: toolCalls ?? this.toolCalls,
      metadata: metadata ?? this.metadata,
      sentAt: sentAt ?? this.sentAt,
      status: status ?? this.status,
      deviceId: deviceId ?? this.deviceId,
      employeeId: employeeId ?? this.employeeId,
    );
  }

  static DateTime _parseDateTime(dynamic value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.parse(value);
    return DateTime.now();
  }
}

/// 待确认消息状态
enum PendingMessageStatus {
  pending,    // 待确认
  confirmed,  // 已确认
  failed,     // 发送失败
}
```

#### 2.3.3 QueuedMessage - 队列消息

```dart
/// 队列消息
///
/// 用于 MessageQueueItem 和 TrackedMessage
/// 包含消息处理状态信息
class QueuedMessage extends AgentMessage {
  /// 消息处理状态
  final MessageProcessingStatus processingStatus;

  /// 处理错误信息（如果有）
  final String? processingError;

  /// 入队时间
  final DateTime enqueuedAt;

  /// 开始处理时间（可选）
  final DateTime? startedAt;

  /// 完成时间（可选）
  final DateTime? completedAt;

  const QueuedMessage({
    required super.id,
    super.role,
    super.type,
    super.content,
    required super.createdAt,
    super.toolCallId,
    super.toolName,
    super.toolArguments,
    super.toolResult,
    super.toolCalls,
    super.metadata,
    this.processingStatus = MessageProcessingStatus.queued,
    this.processingError,
    required this.enqueuedAt,
    this.startedAt,
    this.completedAt,
  });

  /// 从 Map 创建
  factory QueuedMessage.fromMap(Map<String, dynamic> map) {
    return QueuedMessage(
      id: map['id'] as String,
      role: map['role'] as String? ?? 'user',
      type: map['type'] as String? ?? 'text',
      content: map['content'] as String?,
      createdAt: _parseDateTime(map['createdAt']),
      toolCallId: map['toolCallId'] as String?,
      toolName: map['toolName'] as String?,
      toolArguments: map['toolArguments'] as Map<String, dynamic>?,
      toolResult: map['toolResult'] as String?,
      toolCalls: map['toolCalls'] != null
          ? (map['toolCalls'] as List)
              .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
              .toList()
          : null,
      metadata: map['metadata'] as Map<String, dynamic>?,
      processingStatus: MessageProcessingStatus.values.firstWhere(
        (e) => e.name == (map['processingStatus'] as String? ?? 'queued'),
        orElse: () => MessageProcessingStatus.queued,
      ),
      processingError: map['processingError'] as String?,
      enqueuedAt: _parseDateTime(map['enqueuedAt'] ?? map['createdAt']),
      startedAt: map['startedAt'] != null
          ? _parseDateTime(map['startedAt'])
          : null,
      completedAt: map['completedAt'] != null
          ? _parseDateTime(map['completedAt'])
          : null,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    final map = super.toMap();
    return {
      ...map,
      'processingStatus': processingStatus.name,
      if (processingError != null) 'processingError': processingError,
      'enqueuedAt': enqueuedAt.toIso8601String(),
      if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
      if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    };
  }

  /// 更新处理状态
  QueuedMessage updateStatus(
    MessageProcessingStatus status, {
    String? error,
  }) {
    return copyWith(
      processingStatus: status,
      processingError: error,
      startedAt: status == MessageProcessingStatus.processing
          ? DateTime.now()
          : startedAt,
      completedAt: status == MessageProcessingStatus.completed ||
              status == MessageProcessingStatus.failed ||
              status == MessageProcessingStatus.interrupted
          ? DateTime.now()
          : completedAt,
    );
  }

  static DateTime _parseDateTime(dynamic value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.parse(value);
    return DateTime.now();
  }
}

/// 消息处理状态
enum MessageProcessingStatus {
  none,          // 无状态
  queued,        // 排队中
  processing,    // 处理中
  completed,     // 已完成
  failed,        // 失败
  interrupted,   // 被中断
  revoked,       // 已撤回
}
```

## 三、重构计划

### 3.1 重构步骤

#### 第一阶段：创建 Entity 类

1. 创建 `lib/src/agent/entity/` 目录
2. 实现 `AgentMessage` 基类
3. 实现 `PendingMessage` 类
4. 实现 `QueuedMessage` 类
5. 添加单元测试

#### 第二阶段：重构现有代码

1. **重构 AgentProxy._pendingMessageQueue**
   ```dart
   // 之前
   final List<Map<String, dynamic>> _pendingMessageQueue = [];

   // 之后
   final List<PendingMessage> _pendingMessageQueue = [];
   ```

2. **重构 MessageQueueItem**
   ```dart
   // 之前
   class MessageQueueItem {
     final String messageId;
     final Map<String, dynamic> messageData;
     final Completer<void>? completer;
   }

   // 之后
   class MessageQueueItem {
     final QueuedMessage message;
     final Completer<void>? completer;

     String get messageId => message.id;
   }
   ```

3. **重构 TrackedMessage**
   ```dart
   // 之前
   class TrackedMessage {
     final String messageId;
     final Map<String, dynamic> messageData;
     AgentMessageStatus status;
   }

   // 之后
   class TrackedMessage {
     final QueuedMessage message;

     String get messageId => message.id;
     MessageProcessingStatus get status => message.processingStatus;

     void updateStatus(MessageProcessingStatus status) {
       message = message.updateStatus(status);
     }
   }
   ```

#### 第三阶段：提供兼容层

为了平滑迁移，提供转换工具：

```dart
/// Map 扩展方法
extension AgentMessageMapExtension on Map<String, dynamic> {
  /// 转换为 AgentMessage
  AgentMessage toAgentMessage() => AgentMessage.fromMap(this);

  /// 转换为 PendingMessage
  PendingMessage toPendingMessage() => PendingMessage.fromMap(this);

  /// 转换为 QueuedMessage
  QueuedMessage toQueuedMessage() => QueuedMessage.fromMap(this);
}

/// AgentMessage 扩展方法
extension AgentMessageExtension on AgentMessage {
  /// 转换为 Map
  Map<String, dynamic> toMap() => toMap();
}
```

### 3.2 文件结构

```
lib/src/agent/
├── entity/
│   ├── agent_message.dart
│   ├── pending_message.dart
│   ├── queued_message.dart
│   ├── tool_call.dart
│   └── entity.dart  # 导出文件
├── client/
│   └── agent_proxy.dart  # 使用 PendingMessage
├── processor/
│   ├── message_queue.dart  # 使用 QueuedMessage
│   └── message_tracker.dart  # 使用 QueuedMessage
└── agent.dart  # 导出 entity
```

## 四、优势分析

### 4.1 类型安全

```dart
// 之前：类型不安全
final content = messageData['content'] as String?;  // 可能拼写错误

// 之后：类型安全
final content = message.content;  // IDE 自动补全，类型检查
```

### 4.2 代码可读性

```dart
// 之前：不清晰
messageData['processingStatus'] = 'completed';

// 之后：清晰明确
message = message.updateStatus(MessageProcessingStatus.completed);
```

### 4.3 维护性

- 所有消息字段定义在一处
- 修改字段只需修改 Entity 类
- 自动提供序列化和反序列化

### 4.4 IDE 支持

- 自动补全
- 类型检查
- 重构支持
- 文档提示

## 五、迁移策略

### 5.1 渐进式迁移

1. **第一阶段**：新增 Entity 类，不修改现有代码
2. **第二阶段**：在新功能中使用 Entity 类
3. **第三阶段**：逐步重构现有代码
4. **第四阶段**：移除兼容层

### 5.2 向后兼容

```dart
// 支持从 Map 创建
final message = PendingMessage.fromMap(oldMapData);

// 支持转换为 Map（用于序列化）
final map = message.toMap();

// 旧代码仍然可以工作（通过扩展方法）
final oldMap = {'id': '123', 'content': 'hello'};
final message = oldMap.toPendingMessage();
```

### 5.3 测试策略

1. **单元测试**：测试所有 Entity 类的序列化/反序列化
2. **集成测试**：测试 Entity 在实际使用中的表现
3. **迁移测试**：测试从 Map 到 Entity 的转换

## 六、实施建议

### 6.1 优先级

1. **高优先级**：`AgentMessage` 和 `PendingMessage`（影响前端渲染）
2. **中优先级**：`QueuedMessage`（影响内部处理）
3. **低优先级**：其他辅助类

### 6.2 时间估算

- Entity 类实现：1 天
- 单元测试：0.5 天
- AgentProxy 重构：0.5 天
- MessageQueue/Tracker 重构：1 天
- 集成测试：0.5 天
- **总计：3.5 天**

### 6.3 风险评估

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 破坏现有功能 | 高 | 提供兼容层，渐进式迁移 |
| 性能下降 | 中 | Entity 类设计为轻量级，避免过度封装 |
| 学习成本 | 低 | Entity 类设计简单，易于理解 |

## 七、总结

本设计方案通过引入类型安全的 Entity 类，解决了当前 Map 存储对象类型不安全、字段不一致的问题。采用渐进式迁移策略，确保平滑过渡，提升代码质量和可维护性。

### 关键收益

1. ✅ **类型安全**：消除 `Map<String, dynamic>` 的类型风险
2. ✅ **代码质量**：提升可读性、可维护性
3. ✅ **开发效率**：IDE 自动补全、重构支持
4. ✅ **向后兼容**：支持渐进式迁移，不影响现有功能
5. ✅ **领域驱动**：Entity 类反映业务概念，更易理解
