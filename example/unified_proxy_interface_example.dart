/// CachedAgentProxy 使用示例（更新版）
///
/// 演示统一接口：
/// - getAgentProxy() 会查找本地和远程代理
/// - 返回统一的 CachedAgentProxy 类型

import 'package:wenzagent/wenzagent.dart';

Future<void> main() async {
  // 初始化 Hive
  await HiveManager.initialize();
  
  final deviceClient = DeviceClientImpl(
    deviceId: 'device-001',
    host: '192.168.1.100',
    port: 9090,
  );
  
  try {
    await deviceClient.connect();
    
    // ===== 统一的接口 =====
    
    // 创建本地员工
    final localEmployee = await deviceClient.employeeManager.createEmployee(
      AiEmployeeEntity(
        uuid: 'local-employee-001',
        employeeId: 'local-employee-001',
        name: '本地助手',
        systemPrompt: '你是一个本地助手',
        skills: [],
      ),
    );
    
    // 创建远程员工（在其他设备上线）
    final remoteEmployee = await deviceClient.employeeManager.createEmployee(
      AiEmployeeEntity(
        uuid: 'remote-employee-001',
        employeeId: 'remote-employee-001',
        name: '远程助手',
        systemPrompt: '你是一个远程助手',
        skills: [],
      ),
    );
    
    // 设置远程员工在其他设备上线
    await deviceClient.employeeManager.updateCurrentDeviceId(
      remoteEmployee.uuid,
      'device-002',
    );
    
    // ===== 获取代理（统一接口） =====
    
    // 获取本地代理
    final localProxy = await deviceClient.getOrCreateAgentProxy(
      employeeId: localEmployee.uuid,
    );
    print('本地代理: ${localProxy.employeeId}');
    print('isLocalMode: ${localProxy.isLocalMode}');
    print('needCache: ${localProxy.needCache}');  // false
    
    // 获取远程代理
    final remoteProxy = await deviceClient.getOrCreateAgentProxy(
      employeeId: remoteEmployee.uuid,
    );
    print('远程代理: ${remoteProxy.employeeId}');
    print('isLocalMode: ${remoteProxy.isLocalMode}');
    print('needCache: ${remoteProxy.needCache}');  // true
    
    // ===== 查找代理（统一查找） =====
    
    // getAgentProxy() 会自动查找本地和远程代理
    final foundLocalProxy = deviceClient.getAgentProxy(localEmployee.uuid);
    print('找到本地代理: ${foundLocalProxy?.employeeId}');
    
    final foundRemoteProxy = deviceClient.getAgentProxy(remoteEmployee.uuid);
    print('找到远程代理: ${foundRemoteProxy?.employeeId}');
    
    // ===== 获取代理列表 =====
    
    // 获取所有本地代理
    final localProxies = deviceClient.getLocalAgentProxies();
    print('本地代理数量: ${localProxies.length}');
    
    // 获取所有远程代理
    final remoteProxies = deviceClient.getRemoteAgentProxies();
    print('远程代理数量: ${remoteProxies.length}');
    
    // 获取所有代理（本地 + 远程）
    final allProxies = deviceClient.getAllAgentProxies();
    print('所有代理数量: ${allProxies.length}');
    
    // ===== 使用代理（统一方法） =====
    
    // 无论是本地还是远程，使用方式都一样
    for (final proxy in allProxies) {
      print('\n--- 代理: ${proxy.employeeId} ---');
      print('模式: ${proxy.isLocalMode ? "本地" : "远程"}');
      print('缓存: ${proxy.needCache ? "启用" : "不启用"}');
      
      // 发送消息
      await proxy.sendMessage(
        MessageInput(
          content: '你好',
          type: 'text',
        ),
      );
      
      // 获取消息
      final messages = await proxy.getMessages();
      print('消息数量: ${messages.length}');
      
      // 远程模式特有：检查缓存状态
      if (proxy.needCache) {
        print('缓存消息数: ${proxy.cachedMessageCount}');
        print('是否已同步: ${proxy.isSynced}');
      }
    }
    
    // ===== 离线查看（仅远程模式支持） =====
    
    // 断开连接
    await deviceClient.disconnect();
    print('\n离线状态');
    
    // 远程代理仍可查看缓存的消息
    final offlineMessages = await remoteProxy.getMessages();
    print('离线查看远程消息: ${offlineMessages.length} 条');
    
    // 本地代理无法访问（因为 Agent 已关闭）
    // 但可以访问已缓存的消息（如果有）
    
  } finally {
    await deviceClient.dispose();
    await HiveManager.close();
  }
}
