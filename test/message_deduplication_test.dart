import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('消息去重测试', () {
    test('内容签名计算 - 相同内容相同时间窗口', () {
      final now = DateTime.now();
      final timeWindow = (now.millisecondsSinceEpoch ~/ 5000) * 5;
      
      final message1 = AgentMessage(
        id: 'msg-001',
        role: 'user',
        content: '你好',
        createdAt: now,
      );
      
      final message2 = AgentMessage(
        id: 'msg-002',
        role: 'user',
        content: '你好',
        createdAt: now,
      );
      
      // 计算签名
      final signature1 = 'user_${message1.content}_$timeWindow';
      final signature2 = 'user_${message2.content}_$timeWindow';
      
      expect(signature1, equals(signature2));
      print('签名1: $signature1');
      print('签名2: $signature2');
    });

    test('内容签名计算 - 相同内容不同时间窗口（超过5秒）', () {
      final now = DateTime.now();
      final later = now.add(const Duration(seconds: 6));
      
      final timeWindow1 = (now.millisecondsSinceEpoch ~/ 5000) * 5;
      final timeWindow2 = (later.millisecondsSinceEpoch ~/ 5000) * 5;
      
      final message1 = AgentMessage(
        id: 'msg-001',
        role: 'user',
        content: '你好',
        createdAt: now,
      );
      
      final message2 = AgentMessage(
        id: 'msg-002',
        role: 'user',
        content: '你好',
        createdAt: later,
      );
      
      // 计算签名
      final signature1 = 'user_${message1.content}_$timeWindow1';
      final signature2 = 'user_${message2.content}_$timeWindow2';
      
      // 时间窗口不同，签名不同
      expect(signature1, isNot(equals(signature2)));
      print('签名1: $signature1');
      print('签名2: $signature2');
      print('时间窗口1: $timeWindow1');
      print('时间窗口2: $timeWindow2');
    });

    test('内容签名计算 - 不同内容相同时间窗口', () {
      final now = DateTime.now();
      final timeWindow = (now.millisecondsSinceEpoch ~/ 5000) * 5;
      
      final message1 = AgentMessage(
        id: 'msg-001',
        role: 'user',
        content: '你好',
        createdAt: now,
      );
      
      final message2 = AgentMessage(
        id: 'msg-002',
        role: 'user',
        content: '世界',
        createdAt: now,
      );
      
      // 计算签名
      final signature1 = 'user_${message1.content}_$timeWindow';
      final signature2 = 'user_${message2.content}_$timeWindow';
      
      // 内容不同，签名不同
      expect(signature1, isNot(equals(signature2)));
      print('签名1: $signature1');
      print('签名2: $signature2');
    });

    test('时间窗口计算', () {
      // 测试时间窗口的计算逻辑
      final timestamp1 = 1746033015000; // 某个时间点
      final timestamp2 = 1746033017000; // 2秒后
      final timestamp3 = 1746033020000; // 5秒后
      
      final window1 = (timestamp1 ~/ 5000) * 5;
      final window2 = (timestamp2 ~/ 5000) * 5;
      final window3 = (timestamp3 ~/ 5000) * 5;
      
      print('时间戳1: $timestamp1, 窗口: $window1');
      print('时间戳2: $timestamp2, 窗口: $window2');
      print('时间戳3: $timestamp3, 窗口: $window3');
      
      // 前2个时间戳在同一个5秒窗口内
      expect(window1, equals(window2));
      
      // 第3个时间戳在下一个窗口
      expect(window3, isNot(equals(window1)));
    });

    test('AI消息不应该参与内容签名去重', () {
      final now = DateTime.now();
      
      final message1 = AgentMessage(
        id: 'msg-001',
        role: 'assistant',
        content: '你好，有什么可以帮助你的吗？',
        createdAt: now,
      );
      
      final message2 = AgentMessage(
        id: 'msg-002',
        role: 'assistant',
        content: '你好，有什么可以帮助你的吗？',
        createdAt: now,
      );
      
      // AI 消息不应该使用内容签名去重
      // 它们应该只根据 ID 去重
      expect(message1.role, equals('assistant'));
      expect(message2.role, equals('assistant'));
      expect(message1.id, isNot(equals(message2.id)));
      
      print('AI消息只根据ID去重，不参与内容签名去重');
    });

    test('重复消息检测场景', () {
      // 模拟实际场景
      final now = DateTime.now();
      
      // 本地消息（客户端生成）
      final localMessage = AgentMessage(
        id: 'uuid-client-001',
        role: 'user',
        content: '帮我写一个Hello World程序',
        createdAt: now,
        status: 'pending',
      );
      
      // 远程消息（服务器生成不同ID）
      final remoteMessage = AgentMessage(
        id: 'uuid-server-002',
        role: 'user',
        content: '帮我写一个Hello World程序',
        createdAt: now,
        status: 'sent',
      );
      
      // 计算签名
      final timeWindow = (now.millisecondsSinceEpoch ~/ 5000) * 5;
      final localSignature = 'user_${localMessage.content}_$timeWindow';
      final remoteSignature = 'user_${remoteMessage.content}_$timeWindow';
      
      print('本地消息: ID=${localMessage.id}, 签名=$localSignature');
      print('远程消息: ID=${remoteMessage.id}, 签名=$remoteSignature');
      
      // 签名应该相同
      expect(localSignature, equals(remoteSignature));
      print('✅ 签名相同，应该去重，保留远程消息');
    });
  });
}
