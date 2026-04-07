/// Proxy 缓存 deviceId 测试示例
/// 
/// 本示例验证远程 AgentProxy 的消息缓存使用了正确的 deviceId。

import 'package:wenzagent/wenzagent.dart';

/// 测试：验证远程消息缓存的 deviceId 正确性
class ProxyCacheDeviceIdTest {
  final DeviceClient deviceClient;
  
  ProxyCacheDeviceIdTest({required this.deviceClient});
  
  /// 测试场景1：远程消息缓存
  Future<void> testRemoteMessageCache() async {
    print('=== 测试：远程消息缓存 deviceId ===');
    
    try {
      // 1. 连接到服务器
      await deviceClient.connect();
      print('✅ 已连接到服务器');
      print('   本地设备ID: ${deviceClient.deviceId}');
      
      // 2. 创建远程 AgentProxy
      const employeeId = 'employee-remote-test';
      const remoteDeviceId = 'device-remote-001';
      
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
        deviceId: remoteDeviceId,
      );
      
      print('✅ 已创建远程 AgentProxy');
      print('   Proxy 设备ID: ${proxy.deviceId}');
      print('   Employee ID: ${proxy.employeeId}');
      print('   是否本地模式: ${proxy.isLocalMode}');
      print('   是否启用缓存: ${proxy.needCache}');
      
      // 3. 验证 proxy 的 deviceId 是否正确
      if (proxy.deviceId != remoteDeviceId) {
        print('❌ 错误：Proxy 的 deviceId 不正确');
        print('   期望: $remoteDeviceId');
        print('   实际: ${proxy.deviceId}');
        return;
      }
      
      print('✅ Proxy 的 deviceId 正确');
      
      // 4. 发送消息
      final input = MessageInput(
        content: '测试远程消息缓存',
      );
      
      final messageId = await proxy.sendMessage(input);
      print('✅ 已发送消息: $messageId');
      
      // 5. 获取消息并验证
      final messages = await proxy.getMessages();
      print('✅ 获取到 ${messages.length} 条消息');
      
      // 6. 验证消息是否被正确缓存
      // 消息应该缓存到 remoteDeviceId 通道，而不是本地 deviceId
      final cachedMessages = await deviceClient.messageStore.getMessagesWithDeviceId(
        remoteDeviceId,
        employeeId,
      );
      
      if (cachedMessages.isEmpty) {
        print('❌ 错误：消息未缓存到正确的通道');
        print('   查询通道: $remoteDeviceId:$employeeId');
      } else {
        print('✅ 消息已正确缓存到远程设备通道');
        print('   缓存通道: $remoteDeviceId:$employeeId');
        print('   缓存数量: ${cachedMessages.length}');
      }
      
      // 7. 验证消息未缓存到本地设备通道
      final localChannelMessages = await deviceClient.messageStore.getMessagesWithDeviceId(
        deviceClient.deviceId,
        employeeId,
      );
      
      if (localChannelMessages.isNotEmpty) {
        print('❌ 错误：消息被错误地缓存到本地设备通道');
        print('   错误通道: ${deviceClient.deviceId}:$employeeId');
        print('   消息数量: ${localChannelMessages.length}');
      } else {
        print('✅ 确认消息未缓存到本地设备通道');
      }
      
    } catch (e) {
      print('❌ 测试失败: $e');
    }
  }
  
  /// 测试场景2：本地消息持久化
  Future<void> testLocalMessagePersist() async {
    print('\n=== 测试：本地消息持久化 deviceId ===');
    
    try {
      // 1. 创建本地 AgentProxy
      const employeeId = 'employee-local-test';
      
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
        // 不指定 deviceId，使用本地设备
      );
      
      print('✅ 已创建本地 AgentProxy');
      print('   Proxy 设备ID: ${proxy.deviceId}');
      print('   本地设备ID: ${deviceClient.deviceId}');
      print('   是否本地模式: ${proxy.isLocalMode}');
      print('   是否启用缓存: ${proxy.needCache}');
      
      // 2. 验证 proxy 的 deviceId 是本地设备
      if (proxy.deviceId != deviceClient.deviceId) {
        print('❌ 错误：本地 Proxy 的 deviceId 不正确');
        print('   期望: ${deviceClient.deviceId}');
        print('   实际: ${proxy.deviceId}');
        return;
      }
      
      print('✅ 本地 Proxy 的 deviceId 正确');
      
      // 3. 本地模式不应该启用缓存
      if (proxy.needCache) {
        print('⚠️  注意：本地模式启用了缓存（可能不符合预期）');
      } else {
        print('✅ 本地模式未启用缓存（符合预期）');
      }
      
    } catch (e) {
      print('❌ 测试失败: $e');
    }
  }
  
  /// 测试场景3：多设备切换
  Future<void> testMultiDeviceSwitch() async {
    print('\n=== 测试：多设备切换 ===');
    
    try {
      const employeeId = 'employee-multi-test';
      
      // 1. 创建远程 AgentProxy - 设备A
      final proxyA = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
        deviceId: 'device-A',
      );
      
      print('✅ 已创建设备A的 Proxy');
      print('   Device ID: ${proxyA.deviceId}');
      
      // 2. 发送消息到设备A
      final msgA = await proxyA.sendMessage(
        MessageInput(content: '消息到设备A'),
      );
      print('✅ 已发送消息到设备A: $msgA');
      
      // 3. 创建远程 AgentProxy - 设备B
      final proxyB = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
        deviceId: 'device-B',
      );
      
      print('✅ 已创建设备B的 Proxy');
      print('   Device ID: ${proxyB.deviceId}');
      
      // 4. 发送消息到设备B
      final msgB = await proxyB.sendMessage(
        MessageInput(content: '消息到设备B'),
      );
      print('✅ 已发送消息到设备B: $msgB');
      
      // 5. 验证消息分别缓存到各自的通道
      final messagesA = await deviceClient.messageStore.getMessagesWithDeviceId(
        'device-A',
        employeeId,
      );
      
      final messagesB = await deviceClient.messageStore.getMessagesWithDeviceId(
        'device-B',
        employeeId,
      );
      
      print('\n验证消息缓存:');
      print('  设备A通道: ${messagesA.length} 条消息');
      print('  设备B通道: ${messagesB.length} 条消息');
      
      if (messagesA.isNotEmpty && messagesB.isNotEmpty) {
        print('✅ 消息分别缓存到各自的设备通道');
      } else {
        print('❌ 消息缓存异常');
      }
      
    } catch (e) {
      print('❌ 测试失败: $e');
    }
  }
}

/// 使用示例
void main() async {
  // 创建 DeviceClient
  final deviceClient = DeviceClient(
    deviceId: 'device-local',
    host: 'localhost',
    port: 9090,
  );
  
  // 创建测试实例
  final test = ProxyCacheDeviceIdTest(deviceClient: deviceClient);
  
  // 运行测试
  await test.testRemoteMessageCache();
  await test.testLocalMessagePersist();
  await test.testMultiDeviceSwitch();
  
  // 清理
  await deviceClient.dispose();
}
