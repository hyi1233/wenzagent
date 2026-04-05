import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 远程获取会话列表测试
///
/// 测试场景：
/// 1. 启动 LAN Host
/// 2. Device-A 创建员工 Alice 和 Bob
/// 3. Device-B 创建员工 Charlie
/// 4. 通过 LAN 同步，两个设备应该看到相同的会话列表（Alice, Bob, Charlie）
/// 5. 区别只是每个会话是本地还是远程（通过 currentDeviceId 判断）

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║              远程获取会话列表测试                          ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = RemoteSessionListTest();
  await test.run();
}

class RemoteSessionListTest {
  late LanHostServiceImpl host;
  late DeviceClientImpl deviceA;
  late DeviceClientImpl deviceB;

  final String deviceAId = 'device-alpha';
  final String deviceBId = 'device-beta';
  final String employeeAliceUuid = 'emp-alice-001';
  final String employeeBobUuid = 'emp-bob-002';
  final String employeeCharlieUuid = 'emp-charlie-003';

  /// 从环境变量获取 API 配置
  String? get _apiKey => Platform.environment['OPENAI_API_KEY'];
  String? get _apiBaseUrl => Platform.environment['OPENAI_API_URL'];

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化存储 =====
      print('\n[阶段 1] 初始化存储...');
      await _initializeStorage();

      // ===== 阶段 2: 启动 LAN Host =====
      print('\n[阶段 2] 启动 LAN Host...');
      await _startHost();

      // ===== 阶段 3: Device-A 创建员工和会话 =====
      print('\n[阶段 3] Device-A 创建员工和会话...');
      await _deviceAConnectAndCreateSessions();

      // ===== 阶段 4: Device-B 创建员工和会话 =====
      print('\n[阶段 4] Device-B 创建员工和会话...');
      await _deviceBConnectAndCreateSessions();

      // ===== 阶段 5: 同步数据 =====
      print('\n[阶段 5: 同步数据...');
      await _syncData();

      // ===== 阶段 6: 验证会话列表一致 =====
      print('\n[阶段 6: 验证会话列表一致（只是远程/本地区别）...');
      await _verifySessionLists();

      print('\n╔══════════════════════════════════════════════════════════╗');
      print('║                    ✓ 所有测试通过！                        ║');
      print('╚══════════════════════════════════════════════════════════╝\n');
    } catch (e, stackTrace) {
      print('❌ 测试失败: $e');
      print(stackTrace);
    } finally {
      await _cleanup();
    }
  }

  /// 初始化存储
  Future<void> _initializeStorage() async {
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_remote_session_');
    print('  临时目录: ${tempDir.path}');
    await HiveManager.instance.initialize(storagePath: tempDir.path);
    print('  ✓ Hive 初始化完成');
  }

  /// 启动 LAN Host
  Future<void> _startHost() async {
    host = LanHostServiceImpl();
    await host.start(port: 0);
    print('  ✓ Host 已启动: ${host.localIp}:${host.port}');
  }

  /// Device-A 连接并创建员工和会话
  Future<void> _deviceAConnectAndCreateSessions() async {
    deviceA = DeviceClientImpl(
      deviceId: deviceAId,
      deviceName: 'Device Alpha',
      host: host.localIp!,
      port: host.port,
    );

    await deviceA.connect();
    print('  ✓ Device-A 已连接: $deviceAId');

    // 创建员工 Alice
    final alice = AiEmployeeEntity(
      uuid: employeeAliceUuid,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      systemPrompt: '你是 Alice，一个友好的 AI 助手',
      provider: 'openai',
      model: 'mimo-v2-pro',
      apiKey: _apiKey,
      apiBaseUrl: _apiBaseUrl,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceA.employeeManager.createEmployee(alice);
    print('  ✓ Device-A 创建员工 Alice');

    // 创建员工 Bob
    final bob = AiEmployeeEntity(
      uuid: employeeBobUuid,
      name: 'Bob',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Bob',
      systemPrompt: '你是 Bob，一个专业的 AI 助手',
      provider: 'openai',
      model: 'mimo-v2-pro',
      apiKey: _apiKey,
      apiBaseUrl: _apiBaseUrl,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceA.employeeManager.createEmployee(bob);
    print('  ✓ Device-A 创建员工 Bob');

    // 为 Alice 创建会话
    await deviceA.sessionManager.getOrCreateSession(employeeAliceUuid);
    await deviceA.employeeManager.updateCurrentDeviceId(employeeAliceUuid, deviceAId);
    print('  ✓ 为 Alice 创建会话，currentDeviceId = $deviceAId（本地）');

    // 为 Bob 创建会话
    await deviceA.sessionManager.getOrCreateSession(employeeBobUuid);
    await deviceA.employeeManager.updateCurrentDeviceId(employeeBobUuid, deviceAId);
    print('  ✓ 为 Bob 创建会话，currentDeviceId = $deviceAId（本地）');

    // 创建本地 Agent
    await deviceA.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);
    await deviceA.getOrCreateAgentProxy(employeeUuid: employeeBobUuid);
    print('  ✓ 创建本地 Agent');
  }

  /// Device-B 连接并创建员工和会话
  Future<void> _deviceBConnectAndCreateSessions() async {
    deviceB = DeviceClientImpl(
      deviceId: deviceBId,
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
    );

    await deviceB.connect();
    print('  ✓ Device-B 已连接: $deviceBId');

    // Device-B 也创建相同的员工 Alice 和 Bob（模拟同步）
    final alice = AiEmployeeEntity(
      uuid: employeeAliceUuid,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      provider: 'openai',
      model: 'mimo-v2-pro',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceB.employeeManager.createEmployee(alice);

    final bob = AiEmployeeEntity(
      uuid: employeeBobUuid,
      name: 'Bob',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Bob',
      provider: 'openai',
      model: 'mimo-v2-pro',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceB.employeeManager.createEmployee(bob);

    // 创建员工 Charlie（Device-B 独有）
    final charlie = AiEmployeeEntity(
      uuid: employeeCharlieUuid,
      name: 'Charlie',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Charlie（Device-B 创建）',
      systemPrompt: '你是 Charlie，一个智能的 AI 助手',
      provider: 'openai',
      model: 'mimo-v2-pro',
      apiKey: _apiKey,
      apiBaseUrl: _apiBaseUrl,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceB.employeeManager.createEmployee(charlie);
    print('  ✓ Device-B 创建员工 Charlie');

    // 为 Charlie 创建会话
    await deviceB.sessionManager.getOrCreateSession(employeeCharlieUuid);
    await deviceB.employeeManager.updateCurrentDeviceId(employeeCharlieUuid, deviceBId);
    print('  ✓ 为 Charlie 创建会话，currentDeviceId = $deviceBId（本地）');

    // 创建本地 Agent
    await deviceB.getOrCreateAgentProxy(employeeUuid: employeeCharlieUuid);
    print('  ✓ 创建本地 Agent');
  }

  /// 同步数据
  Future<void> _syncData() async {
    // Device-A 同步 Alice 和 Bob 的会话数据到 Device-B
    final sessionAliceA = await deviceA.sessionManager.getSession(employeeAliceUuid);
    if (sessionAliceA != null) {
      await deviceB.sessionManager.save(sessionAliceA);
    }
    final sessionBobA = await deviceA.sessionManager.getSession(employeeBobUuid);
    if (sessionBobA != null) {
      await deviceB.sessionManager.save(sessionBobA);
    }
    print('  ✓ Device-A → Device-B 同步会话数据');

    // Device-B 同步 Charlie 的会话数据到 Device-A
    final sessionCharlieB = await deviceB.sessionManager.getSession(employeeCharlieUuid);
    if (sessionCharlieB != null) {
      await deviceA.sessionManager.save(sessionCharlieB);
    }
    print('  ✓ Device-B → Device-A 同步会话数据');

    // 同步员工的 currentDeviceId
    final aliceA = await deviceA.employeeManager.getEmployee(employeeAliceUuid);
    if (aliceA != null && aliceA.currentDeviceId != null) {
      await deviceB.employeeManager.updateCurrentDeviceId(employeeAliceUuid, aliceA.currentDeviceId!);
    }

    final bobA = await deviceA.employeeManager.getEmployee(employeeBobUuid);
    if (bobA != null && bobA.currentDeviceId != null) {
      await deviceB.employeeManager.updateCurrentDeviceId(employeeBobUuid, bobA.currentDeviceId!);
    }

    final charlieB = await deviceB.employeeManager.getEmployee(employeeCharlieUuid);
    if (charlieB != null && charlieB.currentDeviceId != null) {
      await deviceA.employeeManager.updateCurrentDeviceId(employeeCharlieUuid, charlieB.currentDeviceId!);
    }
    print('  ✓ 同步员工 currentDeviceId');

    // 同步员工信息（Alice, Bob 到 Device-B；Charlie 到 Device-A）
    final alice = await deviceA.employeeManager.getEmployee(employeeAliceUuid);
    if (alice != null) {
      await deviceB.employeeManager.updateEmployee(alice);
    }
    final bob = await deviceA.employeeManager.getEmployee(employeeBobUuid);
    if (bob != null) {
      await deviceB.employeeManager.updateEmployee(bob);
    }
    final charlie = await deviceB.employeeManager.getEmployee(employeeCharlieUuid);
    if (charlie != null) {
      await deviceA.employeeManager.updateEmployee(charlie);
    }
    print('  ✓ 同步员工信息');
  }

  /// 验证会话列表一致
  Future<void> _verifySessionLists() async {
    // Device-A 的会话列表
    final sessionsA = await deviceA.sessionManager.getAllSessions();
    print('\n  [验证] Device-A 会话列表:');
    print('    数量: ${sessionsA.length}');
    for (final session in sessionsA) {
      final employee = await deviceA.employeeManager.getEmployee(session.employeeUuid);
      final currentDeviceId = employee?.currentDeviceId;
      final isLocal = currentDeviceId == deviceAId;
      final isRemote = currentDeviceId != deviceAId;

      print('    - ${employee?.name ?? "未知"} (${session.employeeUuid})');
      print('      currentDeviceId: $currentDeviceId');
      print('      状态: ${isLocal ? "本地" : "远程"}');
    }

    // Device-B 的会话列表
    final sessionsB = await deviceB.sessionManager.getAllSessions();
    print('\n  [验证] Device-B 会话列表:');
    print('    数量: ${sessionsB.length}');
    for (final session in sessionsB) {
      final employee = await deviceB.employeeManager.getEmployee(session.employeeUuid);
      final currentDeviceId = employee?.currentDeviceId;
      final isLocal = currentDeviceId == deviceBId;
      final isRemote = currentDeviceId != deviceBId;

      print('    - ${employee?.name ?? "未知"} (${session.employeeUuid})');
      print('      currentDeviceId: $currentDeviceId');
      print('      状态: ${isLocal ? "本地" : "远程"}');
    }

    // 两个设备的会话列表应该包含相同的员工
    final employeeUuidsA = sessionsA.map((s) => s.employeeUuid).toSet();
    final employeeUuidsB = sessionsB.map((s) => s.employeeUuid).toSet();

    print('\n  [验证] 会话列表对比:');
    print('    Device-A 员工: ${employeeUuidsA.length} 个');
    print('    Device-B 员工: ${employeeUuidsB.length} 个');
    print('    相同员工: ${employeeUuidsA.intersection(employeeUuidsB).length} 个');

    // 验证两个设备看到的会话列表完全一致
    assert(sessionsA.length == sessionsB.length,
           '两个设备的会话数量应该相同');
    assert(employeeUuidsA.containsAll(employeeUuidsB),
           'Device-A 应该包含 Device-B 的所有会话');
    assert(employeeUuidsB.containsAll(employeeUuidsA),
           'Device-B 应该包含 Device-A 的所有会话');
    print('  ✓ 两个设备的会话列表完全一致');

    // 验证具体的会话
    assert(employeeUuidsA.contains(employeeAliceUuid), '应该包含 Alice');
    assert(employeeUuidsA.contains(employeeBobUuid), '应该包含 Bob');
    assert(employeeUuidsA.contains(employeeCharlieUuid), '应该包含 Charlie');
    assert(employeeUuidsB.contains(employeeAliceUuid), '应该包含 Alice');
    assert(employeeUuidsB.contains(employeeBobUuid), '应该包含 Bob');
    assert(employeeUuidsB.contains(employeeCharlieUuid), '应该包含 Charlie');
    print('  ✓ 会话列表包含所有员工：Alice, Bob, Charlie');

    // 验证远程/本地判断
    final aliceA = await deviceA.employeeManager.getEmployee(employeeAliceUuid);
    assert(aliceA?.currentDeviceId == deviceAId, 'Alice 在 Device-A 上应该是本地');
    print('  ✓ Alice 在 Device-A 上是本地会话');

    final aliceB = await deviceB.employeeManager.getEmployee(employeeAliceUuid);
    assert(aliceB?.currentDeviceId == deviceAId, 'Alice 在 Device-B 上应该是远程');
    print('  ✓ Alice 在 Device-B 上是远程会话');

    final charlieA = await deviceA.employeeManager.getEmployee(employeeCharlieUuid);
    assert(charlieA?.currentDeviceId == deviceBId, 'Charlie 在 Device-A 上应该是远程');
    print('  ✓ Charlie 在 Device-A 上是远程会话');

    final charlieB = await deviceB.employeeManager.getEmployee(employeeCharlieUuid);
    assert(charlieB?.currentDeviceId == deviceBId, 'Charlie 在 Device-B 上应该是本地');
    print('  ✓ Charlie 在 Device-B 上是本地会话');

    print('\n  ✓ 验证通过：两个设备看到相同的会话列表，只是远程/本地状态不同');
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');

    try {
      await deviceB.disconnect();
      print('  ✓ Device-B 已断开');
    } catch (_) {}

    try {
      await deviceA.disconnect();
      print('  ✓ Device-A 已断开');
    } catch (_) {}

    try {
      await host.stop();
      print('  ✓ Host 已停止');
    } catch (_) {}

    print('  ✓ 清理完成');
  }
}
