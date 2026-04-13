// ============================================================================
// 员工列表示例
// ============================================================================
//
// 演示如何在前端实现：
// 1. 订阅设备上线/下线事件
// 2. 设备上线后自动同步员工列表（带防抖）
// 3. 根据绑定设备显示员工在线状态
//
// 依赖：wenzagent (DeviceClient, DeviceConnectionManager)
// 此示例为伪代码，展示集成模式。Flutter 中将 Stream 替换为 StreamBuilder 即可。
// ============================================================================

import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

void main() async {
  final deviceId = 'my-phone';

  // ============================================================
  // 1. 初始化
  // ============================================================

  final client = DeviceClient.getInstance(deviceId);
  await client.initialize(DeviceClientConfig(
    dbPath: '/tmp/wenzagent_db',
    host: '192.168.1.100',
    port: 9527,
    topic: 'default',
    deviceName: 'My Phone',
  ));

  // ============================================================
  // 2. 订阅设备上线/下线事件
  // ============================================================
  //
  // DeviceClient 提供 onDeviceEvent 流，当设备上线/下线时推送事件。

  final deviceEventSub = client.onDeviceEvent.listen((event) {
    // event 包含设备信息和在线状态
    print('[员工列表] 设备事件: '
        'type=${event.type}, '
        'device=${event.device.name}');
  });

  // ============================================================
  // 3. 订阅连接状态变化
  // ============================================================

  final connectionSub = client.onStateChanged.listen((state) {
    print('[员工列表] 连接状态: $state');
    if (state == DeviceConnectionState.connected) {
      // 连接成功后同步员工列表
      client.syncEmployeesFromDevices();
    }
  });

  // ============================================================
  // 4. 订阅员工变化事件
  // ============================================================

  final employeeSub = client.onEmployeeChanged.listen((event) {
    print('[员工列表] 员工变化: '
        'employeeId=${event.employeeId}, '
        'type=${event.type}');
    // Flutter: 刷新员工列表
  });

  // ============================================================
  // 5. 连接并同步
  // ============================================================

  print('[员工列表] 正在连接...');
  await client.connect();
  print('[员工列表] 已连接');

  // 连接成功后，syncEmployeesFromDevices 会自动被连接状态变化触发
  // 也可以手动调用以强制同步
  await client.syncEmployeesFromDevices();

  // ============================================================
  // 6. 获取员工列表
  // ============================================================

  final employees = await client.employeeManager.getEmployees();
  final onlineDevices = await client.getOnlineDevices();

  print('\n=== 员工列表 ===');
  print('在线设备: ${onlineDevices.length}');

  for (final employee in employees) {
    final boundDevice = employee.currentDeviceId;

    // 判断员工是否在线：检查其绑定的设备是否在线
    final isBoundDeviceOnline = boundDevice != null &&
        onlineDevices.any((d) => d.id == boundDevice);

    print(
      '${isBoundDeviceOnline ? '🟢' : '⚪'} '
      '${employee.name} '
      '[绑定设备: ${boundDevice?.substring(0, 8) ?? '无'}] '
      '[${employee.role}]',
    );
  }

  // ============================================================
  // 7. 设备上线后自动同步（带防抖）
  // ============================================================
  //
  // 实际项目中，设备上线事件会触发 DataSyncManager 自动同步。
  // DataSyncManager 内置 2 秒防抖，避免短时间内重复同步。
  //
  // 以下展示手动触发的模式（通常不需要）：

  // 监听 LAN 消息，当新设备上线时同步
  final lanSub = client.onLanMessage.listen((msg) {
    if (msg.type == LanMessageType.deviceOnline) {
      print('[员工列表] 检测到设备上线，触发员工同步');
      // syncEmployeesFromDevices 已内置防抖，多次调用只会执行一次
      client.syncEmployeesFromDevices();
    }
  });

  // ============================================================
  // 8. Ping 特定员工（检查是否可达）
  // ============================================================

  if (employees.isNotEmpty) {
    final targetEmployeeId = employees.first.uuid;
    final isReachable = await client.pingEmployee(targetEmployeeId);
    print('\n[员工列表] Ping ${employees.first.name}: '
        'isReachable=$isReachable');
  }

  // ============================================================
  // 9. 获取在线设备列表
  // ============================================================

  final devices = await client.getOnlineDevices();
  print('\n=== 在线设备 ===');
  for (final device in devices) {
    print('  ${device.name} (${device.id})');
  }

  // ============================================================
  // 10. 清理
  // ============================================================

  await Future.delayed(const Duration(seconds: 2));

  deviceEventSub.cancel();
  connectionSub.cancel();
  employeeSub.cancel();
  lanSub.cancel();
  await client.disconnect();

  print('\n=== 示例结束 ===');
}
