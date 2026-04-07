/// CachedAgentProxy 使用示例
///
/// 本示例演示：
/// 1. 本地模式：不启用缓存（本地Agent已有持久化）
/// 2. 远程模式：自动启用缓存，支持离线查看

import 'package:wenzagent/wenzagent.dart';

Future<void> main() async {
  // 初始化 Hive
  await HiveManager.initialize();
  
  // ===== 示例 1: 本地模式（不启用缓存） =====
  await localModeExample();
  
  // ===== 示例 2: 远程模式（自动启用缓存） =====
  await remoteModeExample();
  
  // ===== 示例 3: 离线查看消息 =====
  await offlineViewExample();
  
  // 清理
  await HiveManager.close();
}

/// 本地模式示例
///
/// 员工在本设备上线，直接调用本地Agent
/// 不需要额外缓存（本地Agent已有持久化机制）
Future<void> localModeExample() async {
  print('\n===== 本地模式示例 =====\n');
  
  // 1. 创建设备客户端
  final deviceClient = DeviceClientImpl(
    deviceId: 'device-001',
    host: '192.168.1.100',
    port: 9090,
  );
  
  try {
    await deviceClient.connect();
    print('已连接到服务器');
    
    // 2. 创建员工（在本设备上线）
    final employee = await deviceClient.employeeManager.createEmployee(
      EmployeeConfig(
        name: '本地助手',
        systemPrompt: '你是一个本地助手',
      ),
    );
    print('创建员工: ${employee.name} (在本设备上线)');
    
    // 3. 获取代理（自动包装为 CachedAgentProxy）
    final proxy = await deviceClient.getOrCreateAgentProxy(
      employeeId: employee.uuid,
    );
    
    // 4. 检查模式
    print('\n检查模式:');
    print('isLocalMode: ${proxy.isLocalMode}');  // true
    print('needCache: ${proxy.needCache}');      // false（本地模式不需要缓存）
    
    // 5. 发送消息
    await proxy.sendMessage(
      MessageInput(
        content: '你好',
        type: 'text',
      ),
    );
    print('发送消息');
    
    // 6. 获取消息（直接从Agent获取，不经过缓存）
    final messages = await proxy.getMessages();
    print('获取到 ${messages.length} 条消息');
    
    // 清理
    await deviceClient.destroyAgentProxy(employee.uuid);
    await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    
  } finally {
    await deviceClient.dispose();
  }
}

/// 远程模式示例
///
/// 员工在其他设备上线，通过RPC调用远程Agent
/// 自动启用缓存，支持离线查看
Future<void> remoteModeExample() async {
  print('\n===== 远程模式示例 =====\n');
  
  // 1. 创建设备客户端
  final deviceClient = DeviceClientImpl(
    deviceId: 'device-001',
    host: '192.168.1.100',
    port: 9090,
  );
  
  try {
    await deviceClient.connect();
    print('已连接到服务器');
    
    // 2. 假设员工 'employee-002' 在设备 'device-002' 上线
    // 创建本地员工记录（远程员工）
    final employee = await deviceClient.employeeManager.createEmployee(
      EmployeeConfig(
        name: '远程助手',
        systemPrompt: '你是一个远程助手',
      ),
    );
    
    // 设置员工在其他设备上线
    await deviceClient.employeeManager.updateCurrentDeviceId(
      employee.uuid,
      'device-002',
    );
    print('创建员工: ${employee.name} (在 device-002 上线)');
    
    // 3. 获取代理（自动包装为 CachedAgentProxy）
    final proxy = await deviceClient.getOrCreateAgentProxy(
      employeeId: employee.uuid,
      deviceId: 'device-002',
    );
    
    // 4. 检查模式
    print('\n检查模式:');
    print('isLocalMode: ${proxy.isLocalMode}');  // false
    print('needCache: ${proxy.needCache}');      // true（远程模式需要缓存）
    
    // 5. 监听缓存状态（仅远程模式有效）
    proxy.onCacheStateChanged.listen((state) {
      print('缓存状态: $state');
    });
    
    // 6. 加载本地缓存（立即显示，快速响应）
    final cachedMessages = await proxy.getMessages();
    print('从缓存加载 ${cachedMessages.length} 条消息');
    
    // 7. 发送消息（自动缓存到本地）
    await proxy.sendMessage(
      MessageInput(
        content: '你好',
        type: 'text',
      ),
    );
    print('发送消息并缓存到本地');
    
    // 8. 手动同步远程消息
    await proxy.syncWithRemote();
    print('同步完成，最后同步时间: ${proxy.lastSyncTime}');
    
    // 清理
    await deviceClient.destroyAgentProxy(employee.uuid);
    await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    
  } finally {
    await deviceClient.dispose();
  }
}

/// 离线查看示例
///
/// 演示如何在离线状态下查看远程设备的回复消息
Future<void> offlineViewExample() async {
  print('\n===== 离线查看示例 =====\n');
  
  final deviceClient = DeviceClientImpl(
    deviceId: 'device-001',
    host: '192.168.1.100',
    port: 9090,
  );
  
  try {
    // 1. 在线时获取代理并接收消息
    await deviceClient.connect();
    
    final employee = await deviceClient.employeeManager.createEmployee(
      EmployeeConfig(
        name: '离线测试助手',
        systemPrompt: '你是一个助手',
      ),
    );
    
    await deviceClient.employeeManager.updateCurrentDeviceId(
      employee.uuid,
      'device-002',
    );
    
    final proxy = await deviceClient.getOrCreateAgentProxy(
      employeeId: employee.uuid,
      deviceId: 'device-002',
    );
    
    // 同步远程消息到本地缓存
    await proxy.syncWithRemote();
    print('在线时同步消息到本地缓存');
    
    // 2. 断开连接（模拟离线）
    await deviceClient.disconnect();
    print('\n断开连接，进入离线状态');
    
    // 3. 离线时仍可查看缓存的消息
    final offlineMessages = await proxy.getMessages();
    print('离线状态下从缓存读取 ${offlineMessages.length} 条消息');
    
    // 4. 尝试同步（会失败，但不影响查看缓存）
    print('\n尝试在离线状态下同步:');
    await proxy.syncWithRemote();  // 会失败，但不抛异常
    print('同步失败，但仍可查看缓存的 ${proxy.cachedMessageCount} 条消息');
    
    // 清理
    await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    
  } finally {
    await deviceClient.dispose();
  }
}

/// 实际应用场景
///
/// 场景：用户打开聊天窗口
/// 1. 系统自动判断是本地还是远程
/// 2. 本地：直接从Agent加载，无需额外缓存
/// 3. 远程：先显示缓存，后台同步，支持离线查看
Future<void> realWorldScenario() async {
  print('\n===== 实际应用场景 =====\n');
  
  final deviceClient = DeviceClientImpl(
    deviceId: 'user-device',
    host: '192.168.1.100',
    port: 9090,
  );
  
  try {
    await deviceClient.connect();
    
    // 创建员工
    final employee = await deviceClient.employeeManager.createEmployee(
      EmployeeConfig(
        name: '客服助手',
        systemPrompt: '你是一个客服助手',
      ),
    );
    
    print('用户打开聊天窗口...');
    
    // 获取代理（系统自动判断本地/远程模式）
    final proxy = await deviceClient.getOrCreateAgentProxy(
      employeeId: employee.uuid,
    );
    
    // 显示模式信息
    if (proxy.isLocalMode) {
      print('本地模式：直接访问本地Agent');
      print('消息已通过Agent持久化，无需额外缓存');
    } else {
      print('远程模式：访问远程Agent');
      print('自动启用缓存，支持离线查看');
      
      // 监听缓存状态
      proxy.onCacheStateChanged.listen((state) {
        if (state == CacheState.syncing) {
          print('正在同步远程消息...');
        } else if (state == CacheState.idle) {
          print('同步完成');
        }
      });
    }
    
    // 获取消息（用户无需关心是本地还是远程）
    final messages = await proxy.getMessages();
    print('显示 ${messages.length} 条消息');
    
    // 清理
    await deviceClient.destroyAgentProxy(employee.uuid);
    await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    
  } finally {
    await deviceClient.dispose();
  }
}
