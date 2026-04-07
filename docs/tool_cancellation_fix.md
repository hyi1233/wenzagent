# Agent 工具取消机制修复方案

## 问题背景

用户报告了一个关键问题：
- Agent 正在执行工具（如命令执行）
- 用户发送取消指令
- Agent 命令执行被打断
- 但前端界面 AgentProxy 一直显示"执行中"状态

## 根本原因

### 1. 工具执行期间没有检查取消令牌

```dart
// langchain_chat_adapter.dart 第345-353行
ToolResult result;
try {
  result = await tool.execute(toolArguments);  // 阻塞等待，无法取消
} catch (e) {
  result = ToolResult.error('工具执行异常: $e');
}
```

**问题**：工具执行期间没有检查取消令牌，如果工具执行时间很长，打断无法生效。

### 2. stopStreaming() 实现不完整

```dart
// langchain_chat_adapter.dart 第395-397行
@override
Future<void> stopStreaming() async {
  _isStreaming = false;  // 只是设置标志，没有真正停止操作
}
```

**问题**：`stopStreaming()` 只设置标志，没有停止正在执行的工具。

### 3. 命令执行工具不支持中断

```dart
// command_execute_tool.dart 第56-72行
final ProcessResult result;
if (Platform.isWindows) {
  result = await Process.run(  // 阻塞等待，无法中断
    'cmd',
    ['/c', command],
    workingDirectory: workingDirectory,
    runInShell: false,
  ).timeout(Duration(seconds: timeout));
}
```

**问题**：使用 `Process.run()` 是阻塞的，无法在执行期间中断进程。

## 解决方案

### 1. 创建 CancellableToolExecutor 类

**文件**: `lib/src/agent/tool/cancellable_tool_executor.dart`

支持取消的工具执行器，包装工具执行过程，使其能够响应取消令牌：

```dart
class CancellableToolExecutor {
  final AgentTool _tool;
  final CancellationToken _cancellationToken;

  CancellableToolExecutor(this._tool, this._cancellationToken);

  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final completer = Completer<ToolResult>();

    // 监听取消事件
    final subscription = _cancellationToken.onCancel.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(ToolCancelledException('Tool execution cancelled'));
      }
    });

    // 异步执行工具
    () async {
      try {
        final result = await _tool.execute(arguments);
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      } finally {
        await subscription.cancel();
      }
    }();

    return completer.future;
  }
}
```

### 2. 修改 CommandExecuteTool 支持中断

**文件**: `lib/src/agent/tool/builtin/command_execute_tool.dart`

#### 2.1 使用 Process.start() 替代 Process.run()

```dart
// 旧代码（阻塞）
final ProcessResult result = await Process.run('cmd', ['/c', command]);

// 新代码（可中断）
_currentProcess = await Process.start('cmd', ['/c', command]);
final exitCode = await _currentProcess!.exitCode;
```

#### 2.2 添加取消监听机制

```dart
// 创建取消监听器
final cancellationCompleter = Completer<Map<String, dynamic>>();
StreamSubscription? cancelMonitor;
cancelMonitor = await _createCancellationMonitor(cancellationCompleter);

// 等待：进程完成、超时或取消
final result = await Future.any([
  outputCompleter.future,      // 进程完成
  timeoutFuture,                // 超时
  cancellationCompleter.future, // 取消
]);
```

#### 2.3 实现 cancel() 方法

```dart
@override
void cancel() {
  _isCancelled = true;
  _killProcess();
}

void _killProcess() {
  try {
    _currentProcess?.kill();
  } catch (e) {
    // 忽略杀死进程时的错误
  }
}
```

### 3. 修改 AgentTool 基类

**文件**: `lib/src/agent/tool/agent_tool.dart`

添加 `cancel()` 方法，子类可以重写以支持取消：

```dart
abstract class AgentTool {
  // ... 其他方法 ...

  /// 取消工具执行
  ///
  /// 默认实现为空，子类可以重写此方法以支持取消长时间运行的操作。
  void cancel() {
    // 默认空实现，子类可重写
  }
}
```

### 4. 修改 LangChainChatAdapter

**文件**: `lib/src/agent/adapter/langchain_chat_adapter.dart`

#### 4.1 添加当前工具追踪

```dart
/// 当前正在执行的工具（用于取消）
AgentTool? _currentTool;
```

#### 4.2 使用可取消执行器

```dart
// 执行工具
_currentTool = tool;  // 记录当前工具
try {
  final executor = CancellableToolExecutor(tool, cancellationToken!);
  result = await executor.execute(toolArguments);
} on ToolCancelledException {
  yield StreamResponse.error('Cancelled');
  return;
} finally {
  _currentTool = null;
}
```

#### 4.3 增强 stopStreaming()

```dart
@override
Future<void> stopStreaming() async {
  _isStreaming = false;
  
  // 取消正在执行的工具
  if (_currentTool != null) {
    _currentTool!.cancel();
    _currentTool = null;
  }
}
```

## 执行流程对比

### 修复前（问题流程）

```
T0: 用户发送命令："执行长时间命令"
T0: Agent 开始处理
T0: Agent 调用命令执行工具
T0: Process.run() 开始执行（阻塞）
T2: 用户发送取消指令
T2: interruptCurrentTask() 调用
T2: _currentCancellationToken.cancel()
T2: stopStreaming()（只设置标志）❌
T2: 状态更新为 idle
T10: 命令执行完成
T10: 工具返回结果 ❌
T10: 继续执行后续逻辑
T10: 状态可能被覆盖 ❌
```

### 修复后（正确流程）

```
T0: 用户发送命令："执行长时间命令"
T0: Agent 开始处理
T0: Agent 调用命令执行工具
T0: Process.start() 开始执行（可中断）
T0: 启动取消监听器 ✅
T2: 用户发送取消指令
T2: interruptCurrentTask() 调用
T2: _currentCancellationToken.cancel()
T2: stopStreaming() 调用
T2: _currentTool.cancel() ✅
T2: Process.kill() 杀死进程 ✅
T2: cancellationCompleter.complete({'cancelled': true}) ✅
T2: 工具执行被取消 ✅
T2: 返回 ToolCancelledException ✅
T2: yield StreamResponse.error('Cancelled') ✅
T2: 状态正确更新为 idle ✅
```

## 关键改进

### 1. 工具执行可中断

- ✅ 使用 `Process.start()` 替代 `Process.run()`
- ✅ 监听取消令牌
- ✅ 及时中断进程

### 2. 状态更新及时

- ✅ 工具执行被取消后立即返回
- ✅ 状态正确更新为 idle
- ✅ 前端界面收到正确的状态

### 3. 扩展性好

- ✅ `AgentTool.cancel()` 默认空实现，不影响现有工具
- ✅ 子类可以按需重写 `cancel()` 方法
- ✅ `CancellableToolExecutor` 可以包装任何工具

## 数据结构

### ToolCancelledException

```dart
class ToolCancelledException implements Exception {
  final String message;
  ToolCancelledException(this.message);
}
```

### 取消事件流

```
CancellationToken.cancel()
    ↓
onCancel Stream 发送事件
    ↓
CancellableToolExecutor 监听
    ↓
Completer.completeError(ToolCancelledException)
    ↓
LangChainChatAdapter 捕获
    ↓
yield StreamResponse.error('Cancelled')
```

## 影响范围

### 正面影响

1. **工具可中断**：长时间运行的工具可以被取消
2. **状态正确**：前端界面状态与实际状态一致
3. **用户体验提升**：用户可以及时停止不需要的操作

### 向后兼容

- ✅ `AgentTool.cancel()` 默认空实现，不影响现有工具
- ✅ 现有工具可以按需实现 `cancel()` 方法
- ✅ 不影响不使用取消功能的代码路径

## 测试建议

### 测试场景1：命令执行取消

```dart
// 1. 发送长时间执行的命令
final proxy = await deviceClient.getOrCreateAgentProxy(
  employeeId: 'employee-1',
);
proxy.sendMessage(MessageInput(content: '执行命令: sleep 100'));

// 2. 等待1秒
await Future.delayed(Duration(seconds: 1));

// 3. 发送取消
await proxy.interrupt();

// 4. 验证状态
expect(proxy.status, equals(AgentStatus.idle));
expect(proxy.isSending, equals(false));
```

### 测试场景2：多次取消

```dart
// 1. 发送命令
proxy.sendMessage(MessageInput(content: '执行命令1'));

// 2. 多次取消
await proxy.interrupt();
await proxy.interrupt();
await proxy.interrupt();

// 3. 验证状态稳定
expect(proxy.status, equals(AgentStatus.idle));
```

### 测试场景3：取消后继续操作

```dart
// 1. 发送命令并取消
proxy.sendMessage(MessageInput(content: '执行命令1'));
await proxy.interrupt();

// 2. 发送新命令
proxy.sendMessage(MessageInput(content: '执行命令2'));

// 3. 验证新命令正常执行
expect(proxy.status, equals(AgentStatus.processing));
```

## 相关文件

- `lib/src/agent/tool/cancellable_tool_executor.dart` - 可取消工具执行器
- `lib/src/agent/tool/agent_tool.dart` - 工具基类（添加 cancel 方法）
- `lib/src/agent/tool/builtin/command_execute_tool.dart` - 命令执行工具（支持中断）
- `lib/src/agent/adapter/langchain_chat_adapter.dart` - 聊天适配器（使用可取消执行器）

## 总结

通过实现工具取消机制，解决了 Agent 命令执行被打断但前端界面一直显示"执行中"的问题。关键改进包括：

1. **CancellableToolExecutor**：包装工具执行，响应取消令牌
2. **Process.start()**：使用可中断的进程启动方式
3. **AgentTool.cancel()**：提供取消接口，子类可重写
4. **stopStreaming()**：增强取消逻辑，调用工具的 cancel 方法

这些改进确保了工具执行可以被及时中断，前端状态与实际状态保持一致，提升了用户体验。
