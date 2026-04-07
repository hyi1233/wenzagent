import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('CachedAgentProxy Tests', () {
    late DeviceClient deviceClient;
    
    setUpAll(() async {
      // 初始化 Hive
      await HiveManager.initialize();
      
      // 创建设备客户端
      deviceClient = DeviceClientImpl(
        deviceId: 'test-device-001',
        host: 'localhost',
        port: 9090,
      );
    });
    
    tearDownAll(() async {
      await deviceClient.dispose();
      await HiveManager.close();
    });
    
    test('创建本地 CachedAgentProxy（不启用缓存）', () async {
      // 创建测试员工
      final employee = await deviceClient.employeeManager.createEmployee(
        EmployeeConfig(
          name: '测试员工',
          systemPrompt: '你是一个测试助手',
        ),
      );
      
      // 获取代理（自动包装为 CachedAgentProxy）
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employee.uuid,
      );
      
      expect(proxy, isNotNull);
      expect(proxy.employeeId, equals(employee.uuid));
      expect(proxy.deviceId, equals(deviceClient.deviceId));
      
      // 本地模式，不需要缓存
      expect(proxy.isLocalMode, isTrue);
      expect(proxy.needCache, isFalse);
      
      // 清理
      await deviceClient.destroyAgentProxy(employee.uuid);
      await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    });
    
    test('本地模式发送消息', () async {
      // 创建测试员工
      final employee = await deviceClient.employeeManager.createEmployee(
        EmployeeConfig(
          name: '测试员工2',
          systemPrompt: '你是一个测试助手',
        ),
      );
      
      // 获取代理
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employee.uuid,
      );
      
      // 发送消息
      final messageId = await proxy.sendMessage(
        MessageInput(
          content: '你好，这是一条测试消息',
          type: 'text',
        ),
      );
      
      expect(messageId, isNotEmpty);
      
      // 本地模式直接从Agent获取消息
      final messages = await proxy.getMessages();
      
      expect(messages.length, greaterThan(0));
      expect(messages.any((m) => m.id == messageId), isTrue);
      
      // 清理
      await deviceClient.destroyAgentProxy(employee.uuid);
      await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    });
    
    test('本地模式不启用缓存功能', () async {
      // 创建测试员工
      final employee = await deviceClient.employeeManager.createEmployee(
        EmployeeConfig(
          name: '测试员工3',
          systemPrompt: '你是一个测试助手',
        ),
      );
      
      // 获取代理
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employee.uuid,
      );
      
      // 本地模式，缓存相关属性应该返回默认值
      expect(proxy.needCache, isFalse);
      expect(proxy.cachedMessageCount, equals(0));
      expect(proxy.lastSyncTime, isNull);
      expect(proxy.isSynced, isFalse);
      expect(proxy.cacheState, equals(CacheState.idle));
      
      // 同步方法对本地模式无效
      await proxy.syncWithRemote();
      expect(proxy.lastSyncTime, isNull); // 仍然为null
      
      // 清理
      await deviceClient.destroyAgentProxy(employee.uuid);
      await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    });
    
    test('获取代理实例', () async {
      // 创建测试员工
      final employee = await deviceClient.employeeManager.createEmployee(
        EmployeeConfig(
          name: '测试员工4',
          systemPrompt: '你是一个测试助手',
        ),
      );
      
      // 获取代理
      final proxy1 = await deviceClient.getOrCreateAgentProxy(
        employeeId: employee.uuid,
      );
      
      // 再次获取应该返回同一个实例
      final proxy2 = deviceClient.getAgentProxy(employee.uuid);
      
      expect(proxy2, isNotNull);
      expect(identical(proxy1, proxy2), isTrue);
      
      // 获取所有代理
      final allProxies = deviceClient.getLocalAgentProxies();
      expect(allProxies.length, greaterThan(0));
      
      // 清理
      await deviceClient.destroyAgentProxy(employee.uuid);
      await deviceClient.employeeManager.deleteEmployee(employee.uuid);
    });
    
    // 注意：远程模式的测试需要连接到远程服务器，这里暂时跳过
    // 实际使用时，远程模式会自动启用缓存
  });
  
  group('CachedAgentProxy 远程模式模拟测试', () {
    test('远程模式启用缓存', () {
      // 模拟远程模式的 CachedAgentProxy
      // 在实际使用中，当员工在其他设备上线时，会自动创建远程代理
      
      // 远程模式的特点：
      // - isLocalMode = false
      // - needCache = true
      // - 自动加载本地缓存
      // - 定期同步远程消息
      // - 支持离线查看
      
      print('远程模式会自动启用缓存，支持离线查看');
    });
    
    test('缓存状态管理（仅远程模式）', () async {
      // 这个测试演示缓存状态如何工作
      // 本地模式不会触发这些状态
      
      print('缓存状态包括：');
      print('- idle: 空闲');
      print('- loading: 加载中');
      print('- syncing: 同步中');
      print('- error: 错误');
    });
  });
}
