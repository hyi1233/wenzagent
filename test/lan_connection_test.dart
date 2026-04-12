import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:wenzagent/wenzagent.dart';

/// LAN 连接稳定性测试
///
/// 覆盖场景：
/// 1. Host 启动/停止
/// 2. Client 连接/断开
/// 3. 客户端心跳 ping（Client 发 ping，Host 记录 lastPingTime）
/// 4. 并发连接/断开（触发之前 RangeError 的 bug）
/// 5. Client 超时被 Host 踢掉
/// 6. 同一 deviceId 重复连接踢掉旧连接
/// 7. Client 断线后自动重连
/// 8. Host 重启后 Client 重连
void main() {
  late LanHostServiceImpl host;

  setUp(() async {
    host = LanHostServiceImpl();
    // 如果上次测试没清理，先停止
    if (host.isRunning) {
      await host.stop();
    }
    await host.start(port: 0);
  });

  tearDown(() async {
    await host.stop();
  });

  // ===================================================================
  // 1. Host 启动/停止
  // ===================================================================
  group('Host 启动/停止', () {
    test('启动后 isRunning 为 true', () async {
      expect(host.isRunning, isTrue);
      expect(host.localIp, isNotNull);
      expect(host.port, isPositive);
    });

    test('停止后 isRunning 为 false', () async {
      await host.stop();
      expect(host.isRunning, isFalse);
      expect(host.clients, isEmpty);
    });

    test('停止后再启动', () async {
      await host.stop();
      await host.start(port: 0);
      expect(host.isRunning, isTrue);
    });

    test('重复启动不报错', () async {
      await host.start(port: 0);
      expect(host.isRunning, isTrue);
    });

    test('重复停止不报错', () async {
      await host.stop();
      await host.stop();
      expect(host.isRunning, isFalse);
    });
  });

  // ===================================================================
  // 2. Client 连接/断开
  // ===================================================================
  group('Client 连接/断开', () {
    test('单个 Client 连接后 Host 能看到', () async {
      final ws = await _connectRaw(host);
      await _sendClientInfo(ws, 'device-1', 'Device One');

      await Future.delayed(const Duration(milliseconds: 300));

      expect(host.clients.length, 1);
      expect(host.clients.first.deviceId, 'device-1');

      await ws.sink.close();
      await Future.delayed(const Duration(milliseconds: 300));
      expect(host.clients.length, 0);
    });

    test('多个 Client 连接', () async {
      final ws1 = await _connectRaw(host);
      final ws2 = await _connectRaw(host);
      await _sendClientInfo(ws1, 'device-1', 'Device One');
      await _sendClientInfo(ws2, 'device-2', 'Device Two');

      await Future.delayed(const Duration(milliseconds: 300));

      expect(host.clients.length, 2);

      await ws1.sink.close();
      await Future.delayed(const Duration(milliseconds: 300));
      expect(host.clients.length, 1);
      expect(host.clients.first.deviceId, 'device-2');

      await ws2.sink.close();
      await Future.delayed(const Duration(milliseconds: 300));
      expect(host.clients.length, 0);
    });

    test('Client 未发送 clientInfo 时不出现在已注册设备中', () async {
      final ws = await _connectRaw(host);

      await Future.delayed(const Duration(milliseconds: 300));

      expect(host.clients.length, 1);
      expect(host.clients.first.deviceId, isNull);

      await ws.sink.close();
    });
  });

  // ===================================================================
  // 3. 客户端心跳 ping（Client 发 ping，Host 记录 lastPingTime）
  // ===================================================================
  group('客户端心跳', () {
    test('Client 发送 ping 后 Host 更新 lastPingTime 且不被踢', () async {
      final ws = await _connectRaw(host);
      await _sendClientInfo(ws, 'device-1', 'Device One');

      // 模拟客户端定期发送 ping
      final pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          ws.sink.add(jsonEncode({
            'id': 'ping-1',
            'type': 'ping',
            'fromId': 'device-1',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }));
        } catch (_) {}
      });

      // 记录初始 lastPingTime
      await Future.delayed(const Duration(milliseconds: 300));
      final beforePing = host.clients.first.lastPingTime;

      // 等待至少一个心跳检测周期（Host 5s 检查一次）
      await Future.delayed(const Duration(seconds: 12));

      expect(host.clients.length, 1);
      expect(host.clients.first.deviceId, 'device-1');

      final afterPing = host.clients.first.lastPingTime;
      expect(afterPing, isNotNull);
      expect(afterPing!.isAfter(beforePing ?? DateTime(2000)), isTrue);

      pingTimer.cancel();
      await ws.sink.close();
    });

    test('LanClientServiceImpl 自动发送 ping 心跳', () async {
      await LanClientServiceImpl.dispose('auto-ping-test');
      final client = LanClientServiceImpl(deviceId: 'auto-ping-test');
      await client.connect(host.localIp!, port: host.port);

      expect(client.isConnected, isTrue);

      // 等待客户端发送第一个 ping（每 10 秒发送一次）+ 确认被 Host 处理
      await Future.delayed(const Duration(seconds: 11));

      expect(client.isConnected, isTrue);
      expect(host.clients.length, 1);
      expect(host.clients.first.lastPingTime, isNotNull);

      await client.disconnect();
      await LanClientServiceImpl.dispose('auto-ping-test');
    }, timeout: const Timeout(Duration(seconds: 25)));
  });

  // ===================================================================
  // 4. 并发连接/断开（RangeError 回归测试）
  // ===================================================================
  group('并发连接/断开（RangeError 回归测试）', () {
    test('快速连接和断开多个 Client 不崩溃', () async {
      final connections = <WebSocketChannel>[];

      for (int i = 0; i < 20; i++) {
        final ws = await _connectRaw(host);
        await _sendClientInfo(ws, 'concurrent-$i', 'Concurrent $i');
        connections.add(ws);
      }

      await Future.delayed(const Duration(milliseconds: 500));
      expect(host.clients.length, 20);

      for (int i = 0; i < 10; i++) {
        await connections[i].sink.close();
      }

      await Future.delayed(const Duration(milliseconds: 500));
      expect(host.clients.length, 10);

      for (int i = 10; i < 20; i++) {
        await connections[i].sink.close();
      }

      await Future.delayed(const Duration(milliseconds: 500));
      expect(host.clients.length, 0);
    });

    test('在心跳检查期间断开 Client 不崩溃', () async {
      final ws1 = await _connectRaw(host);
      await _sendClientInfo(ws1, 'ping-test-1', 'Ping Test 1');

      final ws2 = await _connectRaw(host);
      // ws2 定期发送 ping 保持存活
      final ws2Timer = Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          ws2.sink.add(jsonEncode({
            'id': 'ping-ws2',
            'type': 'ping',
            'fromId': 'ping-test-2',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }));
        } catch (_) {}
      });
      await _sendClientInfo(ws2, 'ping-test-2', 'Ping Test 2');

      // 等待一个心跳检测周期
      await Future.delayed(const Duration(seconds: 6));

      // 手动关闭 ws1（不发送 ping）
      await ws1.sink.close();

      // 再等一个检测周期
      await Future.delayed(const Duration(seconds: 6));

      // 不应该崩溃
      expect(host.clients.length, 1);
      expect(host.clients.first.deviceId, 'ping-test-2');

      ws2Timer.cancel();
      await ws2.sink.close();
    });

    test('同时断开所有 Client 不崩溃', () async {
      final connections = <WebSocketChannel>[];

      for (int i = 0; i < 10; i++) {
        final ws = await _connectRaw(host);
        await _sendClientInfo(ws, 'all-close-$i', 'All Close $i');
        connections.add(ws);
      }

      await Future.delayed(const Duration(milliseconds: 300));

      await Future.wait(connections.map((ws) => ws.sink.close()));

      await Future.delayed(const Duration(seconds: 1));

      expect(host.clients.length, 0);
    });
  });

  // ===================================================================
  // 5. Client 超时被 Host 踢掉
  // ===================================================================
  group('Client 超时踢出', () {
    test('不发送 ping 的 Client 被 Host 踢掉', () async {
      final ws = await _connectRaw(host);
      await _sendClientInfo(ws, 'timeout-device', 'Timeout Device');

      await Future.delayed(const Duration(milliseconds: 300));
      expect(host.clients.length, 1);

      // 不发送 ping，等待心跳超时（10s）+ 检测周期（5s）
      await Future.delayed(const Duration(seconds: 16));

      expect(host.clients.length, 0);
    }, timeout: const Timeout(Duration(seconds: 25)));
  });

  // ===================================================================
  // 6. 同一 deviceId 重复连接踢掉旧连接
  // ===================================================================
  group('同一 deviceId 唯一连接', () {
    test('新连接踢掉旧连接', () async {
      final ws1 = await _connectRaw(host);
      await _sendClientInfo(ws1, 'dup-device', 'Dup Device 1');

      // ws1 定期发 ping 保持存活
      final ws1Timer = Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          ws1.sink.add(jsonEncode({
            'id': 'ping-ws1',
            'type': 'ping',
            'fromId': 'dup-device',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }));
        } catch (_) {}
      });

      await Future.delayed(const Duration(milliseconds: 300));
      expect(host.clients.length, 1);

      // 用相同 deviceId 建立新连接
      final ws2 = await _connectRaw(host);

      // ws2 定期发 ping
      final ws2Timer = Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          ws2.sink.add(jsonEncode({
            'id': 'ping-ws2',
            'type': 'ping',
            'fromId': 'dup-device',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }));
        } catch (_) {}
      });

      await _sendClientInfo(ws2, 'dup-device', 'Dup Device 2');

      // 等待 Host 处理踢掉逻辑 + 延迟关闭（100ms）
      await Future.delayed(const Duration(milliseconds: 800));

      // Host 应该只有一个连接，deviceId 为 dup-device
      final dupClients =
          host.clients.where((c) => c.deviceId == 'dup-device').toList();
      expect(dupClients.length, 1);

      ws1Timer.cancel();
      ws2Timer.cancel();
      await ws1.sink.close();
      await ws2.sink.close();
    });
  });

  // ===================================================================
  // 7. Client 断线后自动重连 (LanClientServiceImpl)
  // ===================================================================
  group('Client 自动重连', () {
    test('Host 停止后 Client 检测断线', () async {
      final client = LanClientServiceImpl(deviceId: 'reconnect-test');
      await client.connect(host.localIp!, port: host.port);

      expect(client.isConnected, isTrue);

      // 停止 Host
      await host.stop();

      // 等待 Client 检测到断线
      await Future.delayed(const Duration(seconds: 2));

      expect(client.isConnected, isFalse);

      await client.disconnect();
    });

    test('Host 重启后 Client 可重新连接', () async {
      final originalPort = host.port;

      await LanClientServiceImpl.dispose('restart-test');
      final client = LanClientServiceImpl(deviceId: 'restart-test');
      await client.connect(host.localIp!, port: originalPort);
      expect(client.isConnected, isTrue);

      await host.stop();
      await Future.delayed(const Duration(seconds: 1));

      expect(client.isConnected, isFalse);

      await host.start(port: originalPort);

      await client.reconnect();
      expect(client.isConnected, isTrue);

      await client.disconnect();
      await LanClientServiceImpl.dispose('restart-test');
    });
  });

  // ===================================================================
  // 8. 消息收发
  // ===================================================================
  group('消息收发', () {
    test('Host 广播消息到所有 Client', () async {
      final ws1 = await _connectRaw(host);
      await _sendClientInfo(ws1, 'msg-1', 'Msg 1');
      final ws2 = await _connectRaw(host);
      await _sendClientInfo(ws2, 'msg-2', 'Msg 2');

      final ws1Messages = <String>[];
      final ws2Messages = <String>[];

      ws1.stream.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        if (msg['type'] == 'text') ws1Messages.add(data);
      });

      ws2.stream.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        if (msg['type'] == 'text') ws2Messages.add(data);
      });

      await Future.delayed(const Duration(milliseconds: 300));

      host.broadcast(LanMessage(
        id: 'broadcast-1',
        type: LanMessageType.text,
        fromId: 'host',
        fromName: 'Host',
        content: 'Hello everyone',
        timestamp: DateTime.now(),
      ));

      await Future.delayed(const Duration(milliseconds: 300));

      expect(ws1Messages.any((m) {
        final msg = jsonDecode(m) as Map<String, dynamic>;
        return msg['content'] == 'Hello everyone';
      }), isTrue);

      expect(ws2Messages.any((m) {
        final msg = jsonDecode(m) as Map<String, dynamic>;
        return msg['content'] == 'Hello everyone';
      }), isTrue);

      await ws1.sink.close();
      await ws2.sink.close();
    });

    test('Host 发送定向消息到指定 deviceId', () async {
      final ws1 = await _connectRaw(host);
      await _sendClientInfo(ws1, 'target-1', 'Target 1');
      final ws2 = await _connectRaw(host);
      await _sendClientInfo(ws2, 'target-2', 'Target 2');

      final ws1Messages = <String>[];
      final ws2Messages = <String>[];

      ws1.stream.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        if (msg['type'] == 'text') ws1Messages.add(data);
      });

      ws2.stream.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        if (msg['type'] == 'text') ws2Messages.add(data);
      });

      await Future.delayed(const Duration(milliseconds: 300));

      host.sendToDeviceId('target-1', LanMessage(
        id: 'direct-1',
        type: LanMessageType.text,
        fromId: 'host',
        content: 'Only for target-1',
        timestamp: DateTime.now(),
      ));

      await Future.delayed(const Duration(milliseconds: 300));

      expect(ws1Messages.any((m) {
        final msg = jsonDecode(m) as Map<String, dynamic>;
        return msg['content'] == 'Only for target-1';
      }), isTrue);

      expect(ws2Messages.any((m) {
        final msg = jsonDecode(m) as Map<String, dynamic>;
        return msg['content'] == 'Only for target-1';
      }), isFalse);

      await ws1.sink.close();
      await ws2.sink.close();
    });
  });

  // ===================================================================
  // 9. Host disconnectClient 方法
  // ===================================================================
  group('Host 主动断开 Client', () {
    test('disconnectClient 能正确移除 Client', () async {
      final ws = await _connectRaw(host);
      await _sendClientInfo(ws, 'kick-me', 'Kick Me');

      await Future.delayed(const Duration(milliseconds: 300));
      expect(host.clients.length, 1);

      final clientId = host.clients.first.id!;
      host.disconnectClient(clientId);

      await Future.delayed(const Duration(milliseconds: 300));
      expect(host.clients.length, 0);
    });
  });

  // ===================================================================
  // 10. LanClientServiceImpl 层测试
  // ===================================================================
  group('LanClientServiceImpl', () {
    test('连接、发送消息、断开', () async {
      final client = LanClientServiceImpl(deviceId: 'lcs-test');
      await client.connect(host.localIp!, port: host.port);

      expect(client.isConnected, isTrue);
      expect(client.deviceId, 'lcs-test');

      final hostMessages = <LanMessage>[];
      final sub = host.messageStream.listen((msg) {
        if (msg.type == LanMessageType.text) {
          hostMessages.add(msg);
        }
      });

      client.sendMessage('Hello from LCS');

      await Future.delayed(const Duration(milliseconds: 300));

      expect(hostMessages.any((m) => m.content == 'Hello from LCS'), isTrue);

      await sub.cancel();
      await client.disconnect();
      expect(client.isConnected, isFalse);
    });

    test('多个 ClientService 实例共存', () async {
      final client1 = LanClientServiceImpl(deviceId: 'multi-1');
      final client2 = LanClientServiceImpl(deviceId: 'multi-2');

      await client1.connect(host.localIp!, port: host.port);
      await client2.connect(host.localIp!, port: host.port);

      expect(client1.isConnected, isTrue);
      expect(client2.isConnected, isTrue);
      expect(host.clients.length, 2);

      await client1.disconnect();
      await Future.delayed(const Duration(milliseconds: 500));
      expect(host.clients.length, 1);

      await client2.disconnect();
      await Future.delayed(const Duration(milliseconds: 500));
      expect(host.clients.length, 0);

      await LanClientServiceImpl.dispose('multi-1');
      await LanClientServiceImpl.dispose('multi-2');
    });
  });
}

// ===================================================================
// 辅助函数
// ===================================================================

/// 使用原始 WebSocket 连接到 Host
Future<WebSocketChannel> _connectRaw(LanHostServiceImpl host) async {
  final uri = Uri.parse('ws://${host.localIp}:${host.port}/ws');
  final ws = WebSocketChannel.connect(uri);
  await ws.ready;
  return ws;
}

/// 发送 clientInfo 消息注册 deviceId（模拟 LanClientServiceImpl._sendClientInfo 的格式）
Future<void> _sendClientInfo(
  WebSocketChannel ws,
  String deviceId,
  String deviceName,
) async {
  final info = jsonEncode({
    'id': 'test-id-$deviceId',
    'type': 'clientInfo',
    'fromId': deviceId,
    'fromName': deviceName,
    'content': '127.0.0.1',
    'fileName': deviceId,
    'topic': '',
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  });
  ws.sink.add(info);
  await Future.delayed(const Duration(milliseconds: 100));
}
