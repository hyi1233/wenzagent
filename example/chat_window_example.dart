// ============================================================================
// 聊天窗口示例
// ============================================================================
//
// 演示如何在前端实现：
// 1. 打开聊天：加载本地数据 -> 订阅事件 -> 同步远程
// 2. 发送消息（客户端生成 UUID）
// 3. 清空会话
// 4. 删除消息（撤回）
// 5. 处理 Agent 状态变化（idle/processing/streaming）
// 6. 处理权限请求
//
// 依赖：wenzagent (DeviceClient, CachedAgentProxy)
// 此示例为伪代码，展示集成模式。Flutter 中将 Stream 替换为 StreamBuilder 即可。
// ============================================================================

import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

void main() async {
  final deviceId = 'my-phone';
  final employeeId = 'employee-uuid-1';

  // ============================================================
  // 1. 初始化并连接
  // ============================================================

  final client = DeviceClient.getInstance(deviceId);
  await client.initialize(DeviceClientConfig(
    dbPath: '/tmp/wenzagent_db',
    host: '192.168.1.100',
    port: 9527,
    topic: 'default',
    deviceName: 'My Phone',
  ));
  await client.connect();

  // ============================================================
  // 2. 打开聊天：加载本地数据 -> 订阅事件 -> 同步远程
  // ============================================================

  // 2a. 获取或创建 AgentProxy（自动初始化并加载本地缓存）
  print('[聊天窗口] 获取 AgentProxy...');
  final proxy = await client.getOrCreateAgentProxy(
    employeeId: employeeId,
  );

  // 2b. 初始化（加载本地缓存消息，会触发 onMessagesChanged）
  await proxy.initialize();
  print('[聊天窗口] 初始化完成');

  // 2c. 订阅消息变更（远程模式下，新消息通过此流推送）
  final messagesSub = proxy.onMessagesChanged.listen((messages) {
    print('[聊天窗口] 收到消息更新: ${messages.length} 条');
    // Flutter: setState(() { messages = messages; });
  });

  // 2d. 订阅 Agent 状态变化
  final stateSub = proxy.onStateChanged.listen((state) {
    print('[聊天窗口] Agent 状态: ${state.status}');
    switch (state.status) {
      case AgentStatus.idle:
        // 处理完成：隐藏 loading、启用输入框
        print('[聊天窗口] Agent 空闲，可以发送新消息');
      case AgentStatus.processing:
        // 显示 loading 动画
        print('[聊天窗口] Agent 处理中...');
      case AgentStatus.streaming:
        // 流式输出中
        print('[聊天窗口] Agent 流式输出中...');
      case AgentStatus.waitingPermission:
        // 显示权限请求 UI
        print('[聊天窗口] Agent 等待权限确认...');
      default:
        break;
    }
    // Flutter: setState(() { agentState = state.status; });
  });

  // 2e. 打开会话时标记已读 + 后台同步远程
  client.notificationHub.shouldAutoMarkAsReadCallback = ({
    required String employeeId,
    String? fromDeviceId,
  }) {
    return true; // 当前会话窗口已打开
  };
  await client.setCurrentOpenSession(employeeId: employeeId);
  await proxy.clearAllUnread();

  // 2f. 后台同步远程最新消息（增量 LSN 同步）
  proxy.syncFromRemote().then((_) {
    print('[聊天窗口] 远程同步完成');
  });

  // ============================================================
  // 3. 加载并显示消息
  // ============================================================

  final messages = await proxy.getMessages();
  print('\n=== 聊天消息 (${messages.length} 条) ===');
  for (final msg in messages) {
    final status = msg.status ?? '';
    final preview = msg.content?.substring(0, 30) ?? '';
    print('[${msg.role}] $preview $status');
  }

  // ============================================================
  // 4. 发送消息
  // ============================================================

  // 客户端生成 UUID，确保本地图缓存的 ID 与服务端一致
  final messageId = await proxy.sendMessage(MessageInput(
    content: '你好，请介绍一下你自己',
    role: 'user',
  ));
  print('\n[聊天窗口] 已发送消息: $messageId');

  // 消息发送后，等待 onMessagesChanged 推送更新
  // （Agent 会异步处理并推送 assistant 回复）
  print('[聊天窗口] 等待 Agent 回复...');

  // ============================================================
  // 5. 处理权限请求
  // ============================================================
  //
  // 当 Agent 调用需要权限的工具时，前端需要：
  // 1. 从 getPendingPermissionRequest() 获取权限详情
  // 2. 向用户展示请求
  // 3. 用户批准或拒绝
  // 4. 调用 respondToPermission() 通知 Agent

  final permissionRequest = proxy.getPendingPermissionRequest();
  if (permissionRequest != null) {
    print('\n[聊天窗口] 收到权限请求:');
    print('  函数: ${permissionRequest.functionName}');
    print('  描述: ${permissionRequest.description}');
    print('  数据: ${permissionRequest.data}');

    // 用户批准
    await proxy.respondToPermission(
      permissionRequest.requestId,
      PermissionDecision.allow,
    );
    print('[聊天窗口] 已批准权限请求');
  }

  // ============================================================
  // 6. 撤回消息（删除用户消息及其助手回复）
  // ============================================================

  // await proxy.revokeMessage(messageId);
  // print('[聊天窗口] 已撤回消息: $messageId');

  // ============================================================
  // 7. 清空会话
  // ============================================================

  // await proxy.clearCurrentSession();
  // print('[聊天窗口] 会话已清空');

  // ============================================================
  // 8. 处理 Agent 状态变化（完整示例）
  // ============================================================
  //
  // 在实际 Flutter 中，通常配合 AnimatedBuilder 或 setState：

  /*
  // stateSub = proxy.onStateChanged.listen((state) {
  //   setState(() {
  //     isLoading = state.status == AgentStatus.processing;
  //     isStreaming = state.status == AgentStatus.streaming;
  //     isWaitingPermission = state.status == AgentStatus.waitingPermission;
  //   });
  // });
  */

  // ============================================================
  // 9. 清理
  // ============================================================

  // 模拟等待用户操作
  await Future.delayed(const Duration(seconds: 2));

  client.clearCurrentOpenSession();
  await messagesSub.cancel();
  await stateSub.cancel();

  // 注意：不要 dispose proxy，由 DeviceClient 管理
  await client.disconnect();

  print('\n=== 示例结束 ===');
}
