/// 工具取消机制测试示例
/// 
/// 本示例测试 Agent 工具取消功能，验证长时间运行的命令可以被正确中断。

import 'package:wenzagent/wenzagent.dart';

/// 测试：命令执行取消功能
class ToolCancellationTest {
  final DeviceClient deviceClient;
  
  ToolCancellationTest({required this.deviceClient});
  
  /// 测试场景1：正常取消命令执行
  Future<void> testNormalCancellation() async {
    print('=== 测试：正常取消命令执行 ===');
    
    try {
      // 1. 连接到服务器
      await deviceClient.connect();
      print('✅ 已连接到服务器');
      
      // 2. 创建 AgentProxy
      const employeeId = 'employee-cancel-test';
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
      );
      
      print('✅ 已创建 AgentProxy');
      print('   当前状态: ${proxy.status}');
      
      // 3. 配置 Agent
      await proxy.setProvider(ProviderConfig(
        provider: 'openai',
        model: 'gpt-4',
        apiKey: 'your-api-key',
      ));
      
      // 4. 注册命令执行工具
      proxy.registerTool(CommandExecuteTool());
      
      // 5. 发送一个长时间执行的命令
      print('\n📤 发送命令: 执行 sleep 100');
      final messageFuture = proxy.sendMessage(
        MessageInput(content: '请执行命令: sleep 100'),
      ).toList();
      
      // 6. 等待一段时间让命令开始执行
      await Future.delayed(Duration(seconds: 2));
      
      print('⏱️  命令执行中...');
      print('   当前状态: ${proxy.status}');
      print('   是否发送中: ${proxy.isSending}');
      
      // 7. 发送取消指令
      print('\n🛑 发送取消指令');
      await proxy.interrupt();
      
      // 8. 验证状态
      await Future.delayed(Duration(milliseconds: 500));
      
      print('\n✅ 取消完成');
      print('   当前状态: ${proxy.status}');
      print('   是否发送中: ${proxy.isSending}');
      
      if (proxy.status == AgentStatus.idle && !proxy.isSending) {
        print('✅ 测试通过：状态正确更新为 idle');
      } else {
        print('❌ 测试失败：状态未正确更新');
        print('   期望: idle, 实际: ${proxy.status}');
      }
      
      // 9. 等待消息流完成
      try {
        await messageFuture;
      } catch (e) {
        print('消息流被取消: $e');
      }
      
    } catch (e) {
      print('❌ 测试失败: $e');
    }
  }
  
  /// 测试场景2：取消后继续操作
  Future<void> testContinueAfterCancellation() async {
    print('\n=== 测试：取消后继续操作 ===');
    
    try {
      const employeeId = 'employee-continue-test';
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
      );
      
      await proxy.setProvider(ProviderConfig(
        provider: 'openai',
        model: 'gpt-4',
        apiKey: 'your-api-key',
      ));
      
      proxy.registerTool(CommandExecuteTool());
      
      // 1. 发送第一个命令并取消
      print('📤 发送第一个命令');
      final future1 = proxy.sendMessage(
        MessageInput(content: '执行命令: sleep 50'),
      ).toList();
      
      await Future.delayed(Duration(seconds: 1));
      await proxy.interrupt();
      
      print('✅ 第一个命令已取消');
      print('   状态: ${proxy.status}');
      
      // 2. 发送第二个命令
      await Future.delayed(Duration(milliseconds: 500));
      
      print('\n📤 发送第二个命令');
      final future2 = proxy.sendMessage(
        MessageInput(content: '你好'),
      ).toList();
      
      // 3. 验证第二个命令正常执行
      await Future.delayed(Duration(seconds: 2));
      
      print('✅ 第二个命令正在执行');
      print('   状态: ${proxy.status}');
      
      if (proxy.status == AgentStatus.processing || 
          proxy.status == AgentStatus.streaming) {
        print('✅ 测试通过：取消后可以继续发送新命令');
      } else {
        print('⚠️  注意：第二个命令可能已完成或未开始');
      }
      
      // 清理
      try {
        await future1;
      } catch (_) {}
      await future2;
      
    } catch (e) {
      print('❌ 测试失败: $e');
    }
  }
  
  /// 测试场景3：多次取消
  Future<void> testMultipleCancellations() async {
    print('\n=== 测试：多次取消 ===');
    
    try {
      const employeeId = 'employee-multi-cancel-test';
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
      );
      
      await proxy.setProvider(ProviderConfig(
        provider: 'openai',
        model: 'gpt-4',
        apiKey: 'your-api-key',
      ));
      
      proxy.registerTool(CommandExecuteTool());
      
      // 1. 发送命令
      print('📤 发送命令');
      final future = proxy.sendMessage(
        MessageInput(content: '执行命令: sleep 200'),
      ).toList();
      
      await Future.delayed(Duration(seconds: 1));
      
      // 2. 多次取消
      print('\n🛑 连续发送3次取消指令');
      await proxy.interrupt();
      print('   第1次取消完成');
      
      await proxy.interrupt();
      print('   第2次取消完成');
      
      await proxy.interrupt();
      print('   第3次取消完成');
      
      // 3. 验证状态稳定
      await Future.delayed(Duration(milliseconds: 500));
      
      final status1 = proxy.status;
      await Future.delayed(Duration(milliseconds: 100));
      final status2 = proxy.status;
      
      print('\n状态检查:');
      print('   状态1: $status1');
      print('   状态2: $status2');
      
      if (status1 == status2 && status1 == AgentStatus.idle) {
        print('✅ 测试通过：多次取消后状态稳定');
      } else {
        print('❌ 测试失败：状态不稳定');
      }
      
      // 清理
      try {
        await future;
      } catch (_) {}
      
    } catch (e) {
      print('❌ 测试失败: $e');
    }
  }
  
  /// 测试场景4：状态同步验证
  Future<void> testStatusSynchronization() async {
    print('\n=== 测试：状态同步验证 ===');
    
    try {
      const employeeId = 'employee-status-sync-test';
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
      );
      
      await proxy.setProvider(ProviderConfig(
        provider: 'openai',
        model: 'gpt-4',
        apiKey: 'your-api-key',
      ));
      
      proxy.registerTool(CommandExecuteTool());
      
      // 监听状态变化
      final statusHistory = <AgentStatus>[];
      final subscription = proxy.onStateChanged.listen((snapshot) {
        statusHistory.add(snapshot.status);
        print('📊 状态变化: ${snapshot.status}');
      });
      
      // 1. 发送命令
      print('\n📤 发送命令');
      final future = proxy.sendMessage(
        MessageInput(content: '执行命令: sleep 10'),
      ).toList();
      
      await Future.delayed(Duration(milliseconds: 500));
      
      // 2. 取消
      print('\n🛑 发送取消指令');
      await proxy.interrupt();
      
      await Future.delayed(Duration(milliseconds: 500));
      
      // 3. 验证状态历史
      print('\n状态历史记录:');
      for (var i = 0; i < statusHistory.length; i++) {
        print('   $i. ${statusHistory[i]}');
      }
      
      // 验证最终状态
      if (statusHistory.isNotEmpty && 
          statusHistory.last == AgentStatus.idle) {
        print('✅ 测试通过：最终状态为 idle');
      } else {
        print('❌ 测试失败：最终状态不为 idle');
      }
      
      // 清理
      await subscription.cancel();
      try {
        await future;
      } catch (_) {}
      
    } catch (e) {
      print('❌ 测试失败: $e');
    }
  }
}

/// 使用示例
void main() async {
  // 创建 DeviceClient
  final deviceClient = DeviceClient(
    deviceId: 'device-test',
    host: 'localhost',
    port: 9090,
  );
  
  // 创建测试实例
  final test = ToolCancellationTest(deviceClient: deviceClient);
  
  // 运行测试
  await test.testNormalCancellation();
  await test.testContinueAfterCancellation();
  await test.testMultipleCancellations();
  await test.testStatusSynchronization();
  
  // 清理
  await deviceClient.dispose();
}
