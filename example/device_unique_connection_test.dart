import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 测试：Host 确保同一 deviceId 只有一个连接
/// 使用原始 WebSocket 绕过 LanClientServiceImpl 的单例模式
Future<void> main() async {
  print('================================================');
  print('  Host 端 deviceId 唯一连接验证测试');
  print('================================================\n');

  // 1. 启动 Host
  print('【步骤1】启动 Host...');
  final host = LanHostServiceImpl();
  await host.start(port: 0);
  print('  ✓ Host 已启动: ${host.localIp}:${host.port}\n');

  try {
    // 2. 使用原始 WebSocket 创建第一个连接
    print('【步骤2】创建第一个 WebSocket 连接 (device-alpha)...');
    final uri1 = Uri.parse('ws://${host.localIp}:${host.port}/ws');
    final ws1 = WebSocketChannel.connect(uri1);
    await ws1.ready;
    print('  ✓ WebSocket 1 已连接\n');

    // 发送 clientInfo 消息注册 deviceId
    final clientInfo1 = {
      'type': 'clientInfo',
      'fromId': 'device-alpha',
      'fromName': 'Device Alpha 1',
      'content': '192.168.1.100',
      'fileName': 'device-alpha',  // deviceId
      'topic': '',
    };
    ws1.sink.add(jsonEncode(clientInfo1));
    
    // 监听第一个连接的消息
    var ws1ReceivedKicked = false;
    var ws1Messages = <String>[];
    ws1.stream.listen(
      (data) {
        print('  [WS1 收到] $data');
        ws1Messages.add(data);
        try {
          final msg = jsonDecode(data);
          if (msg['type'] == 'system' && msg['content'] == 'kicked:duplicate_login') {
            ws1ReceivedKicked = true;
            print('  [WS1] 收到被踢下线消息！');
          }
        } catch (_) {}
      },
      onDone: () {
        print('  [WS1] 连接已关闭');
      },
    );

    await Future.delayed(const Duration(milliseconds: 500));

    // 3. 使用原始 WebSocket 创建第二个连接（相同 deviceId）
    print('【步骤3】创建第二个 WebSocket 连接 (相同 deviceId)...');
    final uri2 = Uri.parse('ws://${host.localIp}:${host.port}/ws');
    final ws2 = WebSocketChannel.connect(uri2);
    await ws2.ready;
    print('  ✓ WebSocket 2 已连接\n');

    // 发送 clientInfo 消息注册相同的 deviceId
    final clientInfo2 = {
      'type': 'clientInfo',
      'fromId': 'device-alpha',
      'fromName': 'Device Alpha 2',
      'content': '192.168.1.101',
      'fileName': 'device-alpha',  // 相同的 deviceId
      'topic': '',
    };
    ws2.sink.add(jsonEncode(clientInfo2));

    // 监听第二个连接的消息
    ws2.stream.listen(
      (data) {
        print('  [WS2 收到] $data');
      },
      onDone: () {
        print('  [WS2] 连接已关闭');
      },
    );

    // 4. 等待消息处理
    await Future.delayed(const Duration(milliseconds: 1000));

    // 5. 验证结果
    print('【步骤4】验证结果...');
    print('  WS1 是否收到 kicked 消息: $ws1ReceivedKicked');
    print('  WS1 收到的消息数: ${ws1Messages.length}');
    print('');

    // 6. 最终汇总
    print('================================================');
    print('  测试结果：');
    if (ws1ReceivedKicked) {
      print('  ✓ Host 正确发送了 kicked:duplicate_login 消息');
    } else {
      print('  ✗ Host 未发送 kicked:duplicate_login 消息');
      print('    （可能 WS1 连接在消息到达前就被关闭了）');
    }
    print('================================================\n');

    // 清理
    print('【清理】释放资源...');
    await ws1.sink.close();
    await ws2.sink.close();
    print('  ✓ WebSocket 已关闭\n');

  } finally {
    await host.stop();
    print('Host 已停止');
  }
}
