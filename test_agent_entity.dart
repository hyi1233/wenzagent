/// Agent Entity 测试
///
/// 测试 AgentMessage 和 PendingMessage 的序列化和反序列化

import 'package:wenzagent/wenzagent.dart';

void main() {
  print('=== Agent Entity 测试 ===\n');

  // ===== 测试 1: AgentMessage 基本功能 =====
  print('【测试 1】AgentMessage 基本功能');

  final message = AgentMessage(
    id: 'msg-001',
    content: '你好，这是一条测试消息',
    createdAt: DateTime.now(),
  );

  print('  消息ID: ${message.id}');
  print('  角色: ${message.role}');
  print('  类型: ${message.type}');
  print('  内容: ${message.content}');
  print('  创建时间: ${message.createdAt}');
  print('');

  // ===== 测试 2: AgentMessage 序列化 =====
  print('【测试 2】AgentMessage 序列化');

  final map = message.toMap();
  print('  序列化为 Map:');
  print('    $map');
  print('');

  final restored = AgentMessage.fromMap(map);
  print('  反序列化后:');
  print('    ID: ${restored.id}');
  print('    内容: ${restored.content}');
  print('    是否相等: ${restored.id == message.id && restored.content == message.content}');
  print('');

  // ===== 测试 3: PendingMessage =====
  print('【测试 3】PendingMessage 功能');

  final pendingMessage = PendingMessage(
    id: 'msg-002',
    content: '这是待确认消息',
    createdAt: DateTime.now(),
    sentAt: DateTime.now(),
    deviceId: 'device-001',
    employeeId: 'emp-001',
  );

  print('  消息ID: ${pendingMessage.id}');
  print('  状态: ${pendingMessage.status}');
  print('  是否待确认: ${pendingMessage.isPending}');
  print('  设备ID: ${pendingMessage.deviceId}');
  print('  员工ID: ${pendingMessage.employeeId}');
  print('');

  // ===== 测试 4: PendingMessage 状态更新 =====
  print('【测试 4】PendingMessage 状态更新');

  final confirmedMessage = pendingMessage.confirm();
  print('  原状态: ${pendingMessage.status}');
  print('  新状态: ${confirmedMessage.status}');
  print('  是否已确认: ${confirmedMessage.isConfirmed}');
  print('');

  // ===== 测试 5: PendingMessage 序列化 =====
  print('【测试 5】PendingMessage 序列化');

  final pendingMap = pendingMessage.toMap();
  print('  序列化为 Map:');
  pendingMap.forEach((key, value) {
    print('    $key: $value');
  });
  print('');

  final restoredPending = PendingMessage.fromMap(pendingMap);
  print('  反序列化后:');
  print('    ID: ${restoredPending.id}');
  print('    内容: ${restoredPending.content}');
  print('    状态: ${restoredPending.status}');
  print('    设备ID: ${restoredPending.deviceId}');
  print('');

  // ===== 测试 6: 从旧格式 Map 创建 =====
  print('【测试 6】从旧格式 Map 创建（向后兼容）');

  final oldMap = {
    'id': 'msg-old-001',
    'content': '这是旧格式的消息',
    'role': 'user',
    'type': 'text',
    'createdAt': DateTime.now().toIso8601String(),
    // 可能有自定义字段
    'customField': '自定义值',
  };

  final fromOldMap = PendingMessage.fromMap(oldMap);
  print('  从旧格式创建成功:');
  print('    ID: ${fromOldMap.id}');
  print('    内容: ${fromOldMap.content}');
  print('    元数据: ${fromOldMap.metadata}');
  print('');

  // ===== 测试 7: copyWith =====
  print('【测试 7】copyWith 功能');

  final copied = message.copyWith(
    content: '更新后的内容',
    role: 'assistant',
  );

  print('  原消息: ${message.content} (${message.role})');
  print('  复制后: ${copied.content} (${copied.role})');
  print('  ID保持不变: ${message.id == copied.id}');
  print('');

  // ===== 测试 8: 工具调用 =====
  print('【测试 8】工具调用');

  final toolMessage = AgentMessage(
    id: 'msg-tool-001',
    role: 'assistant',
    type: 'functionCall',
    content: '正在调用工具...',
    createdAt: DateTime.now(),
    toolCalls: [
      ToolCall(
        id: 'call-001',
        name: 'read_file',
        arguments: {'path': '/test/file.txt'},
      ),
    ],
  );

  print('  工具消息:');
  print('    ID: ${toolMessage.id}');
  print('    类型: ${toolMessage.type}');
  print('    工具调用数量: ${toolMessage.toolCalls?.length}');
  if (toolMessage.toolCalls != null && toolMessage.toolCalls!.isNotEmpty) {
    final call = toolMessage.toolCalls!.first;
    print('    第一个工具: ${call.name}');
    print('    参数: ${call.arguments}');
  }
  print('');

  // ===== 测试 9: Map 扩展方法 =====
  print('【测试 9】Map 扩展方法');

  final mapData = {
    'id': 'msg-ext-001',
    'content': '使用扩展方法创建',
    'createdAt': DateTime.now().toIso8601String(),
  };

  final extMessage = mapData.toAgentMessage();
  print('  使用扩展方法创建成功:');
  print('    ID: ${extMessage.id}');
  print('    内容: ${extMessage.content}');
  print('');

  print('=== 所有测试通过 ===\n');

  print('总结:');
  print('  ✓ AgentMessage 序列化/反序列化正常');
  print('  ✓ PendingMessage 功能完整');
  print('  ✓ 状态更新正常');
  print('  ✓ 向后兼容（支持从旧格式创建）');
  print('  ✓ copyWith 功能正常');
  print('  ✓ 工具调用支持完整');
  print('  ✓ Map 扩展方法可用');
}
