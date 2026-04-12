import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/stores/message_store.dart';
import 'package:wenzagent/src/persistence/stores/sync_watermark_store.dart';
import 'package:wenzagent/src/shared/shared.dart';

/// 消息收发与 LSN 增量同步测试
///
/// 模拟 Host（消息源）和 Client（接收方）两个设备共享同一个数据库，
/// 测试以下场景：
///
/// 1. 消息发送后 seq 自增分配
/// 2. LSN 增量拉取：只拉取 seq > lastSeq 的消息
/// 3. 水位线更新与持久化
/// 4. 水位线 MAX 语义：并发更新不回退
/// 5. 分批拉取（batch=20）场景
/// 6. 全量同步后水位线初始化
void main() {
  late DatabaseManager dbManager;
  late String dbDir;
  late MessageStore hostMessageStore;
  late MessageStore clientMessageStore;
  late SyncWatermarkStore clientWatermarkStore;
  const employeeId = 'test-employee-001';
  const hostDeviceId = 'host-device';
  const clientDeviceId = 'client-device';

  setUpAll(() {
    dbDir = p.join(
      Directory.systemTemp.path,
      'msg_lsn_test_${DateTime.now().millisecondsSinceEpoch}',
    );
    Directory(dbDir).createSync(recursive: true);
  });

  tearDownAll(() async {
    await dbManager.close();
    final dir = Directory(dbDir);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  setUp(() async {
    final instance = DatabaseManager.getInstance('test');
    if (instance.isInitialized) await instance.close();
    await instance.initialize(storagePath: dbDir);
    dbManager = instance;

    // 清空所有表
    dbManager.db.execute('DELETE FROM sync_watermark');
    dbManager.db.execute('DELETE FROM messages');

    // Host 端：消息存储（seq 自动分配）
    hostMessageStore = MessageStore(dbManager: dbManager);

    // Client 端：独立的消息存储和水位线
    clientMessageStore = MessageStore(dbManager: dbManager);
    clientWatermarkStore = SyncWatermarkStore(dbManager: dbManager);
  });

  /// 辅助：创建测试消息
  ChatMessage createMessage({
    required String uuid,
    required String role,
    String content = '',
    String type = 'text',
    String processingStatus = 'completed',
    String? empId,
  }) {
    return ChatMessage(
      id: uuid,
      employeeId: empId ?? employeeId,
      role: MessageRole.fromString(role),
      type: type,
      content: content,
      status: MessageStatus.fromString(processingStatus),
      createdAt: DateTime.now(),
    );
  }

  /// 辅助：模拟 Host 发送消息（写入 messages 表，自动分配 seq）
  Future<ChatMessage> hostSend(String role, String content) async {
    final uuid = const Uuid().v4();
    final message = createMessage(uuid: uuid, role: role, content: content);
    await hostMessageStore.add(message);
    return message;
  }

  /// 辅助：模拟 Client 增量拉取（基于水位线）
  Future<List<ChatMessage>> clientPull({int limit = 20}) async {
    final lastSeq = clientWatermarkStore.getLastSeq(employeeId);
    return hostMessageStore.getMessagesAfterSeq(employeeId, lastSeq, limit: limit);
  }

  /// 辅助：模拟 Client 更新水位线
  void clientUpdateWatermark(int lastSeq) {
    clientWatermarkStore.updateLastSeq(employeeId, lastSeq);
  }

  // ================================================================
  // 基础消息发送
  // ================================================================
  group('消息发送与 seq 分配', () {
    test('消息发送后自动分配递增 seq', () async {
      final msg1 = await hostSend('user', '你好');
      final msg2 = await hostSend('assistant', '你好！有什么可以帮你的？');
      final msg3 = await hostSend('user', '请介绍一下自己');

      expect(msg1.seq, greaterThan(0));
      expect(msg2.seq, greaterThan(msg1.seq));
      expect(msg3.seq, greaterThan(msg2.seq));
    });

    test('同一 uuid 消息覆盖更新保留原 seq', () async {
      final uuid = const Uuid().v4();

      // 第一次添加
      final message = createMessage(uuid: uuid, role: 'assistant', content: '草稿');
      await hostMessageStore.add(message);
      final seq1 = message.seq;

      // 更新同一条消息（同 uuid）
      final updated = message.copyWith(
        content: '正式版本',
        status: MessageStatus.completed,
        updatedAt: DateTime.now(),
      );
      await hostMessageStore.update(updated);

      // 从数据库读取验证
      final messages = await hostMessageStore.getMessages(null, employeeId);
      final stored = messages.firstWhere((m) => m.id == uuid);
      expect(stored.seq, equals(seq1), reason: '更新后 seq 应保持不变');
      expect(stored.content, equals('正式版本'));
    });

    test('发送 25 条消息，seq 从 1 到 25 连续递增', () async {
      for (int i = 0; i < 25; i++) {
        final role = i.isEven ? 'user' : 'assistant';
        await hostSend(role, '消息 $i');
      }

      final maxSeq = hostMessageStore.getMaxSeq();
      expect(maxSeq, equals(25));
    });
  });

  // ================================================================
  // LSN 增量拉取
  // ================================================================
  group('LSN 增量拉取', () {
    test('初始水位线为 0，拉取全部消息', () async {
      await hostSend('user', '你好');
      await hostSend('assistant', '你好！');

      final lastSeq = clientWatermarkStore.getLastSeq(employeeId);
      expect(lastSeq, equals(0));

      final pulled = await clientPull();
      expect(pulled.length, equals(2));
    });

    test('水位线更新后，只拉取新增消息', () async {
      // Host 发送 3 条
      await hostSend('user', '消息1');
      await hostSend('assistant', '回复1');
      await hostSend('user', '消息2');

      // Client 第一次拉取
      final batch1 = await clientPull();
      expect(batch1.length, equals(3));
      clientUpdateWatermark(batch1.last.seq);

      // 验证水位线
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(3));

      // Host 再发 2 条
      await hostSend('assistant', '回复2');
      await hostSend('user', '消息3');

      // Client 第二次拉取
      final batch2 = await clientPull();
      expect(batch2.length, equals(2));
      expect(batch2.first.seq, equals(4));
      expect(batch2.last.seq, equals(5));
    });

    test('增量拉取按 seq 升序排列', () async {
      for (int i = 0; i < 5; i++) {
        await hostSend('user', '消息$i');
      }

      final pulled = await clientPull();
      for (int i = 1; i < pulled.length; i++) {
        expect(pulled[i].seq, greaterThan(pulled[i - 1].seq));
      }
    });

    test('拉取 limit=2 分批获取', () async {
      for (int i = 0; i < 5; i++) {
        await hostSend('user', '消息$i');
      }

      // 第一批：seq 1~2
      final batch1 = await hostMessageStore.getMessagesAfterSeq(employeeId, 0, limit: 2);
      expect(batch1.length, equals(2));

      // 第二批：seq 3~4
      final batch2 = await hostMessageStore.getMessagesAfterSeq(
        employeeId, batch1.last.seq, limit: 2,
      );
      expect(batch2.length, equals(2));

      // 第三批：seq 5
      final batch3 = await hostMessageStore.getMessagesAfterSeq(
        employeeId, batch2.last.seq, limit: 2,
      );
      expect(batch3.length, equals(1));

      // 第四批：空
      final batch4 = await hostMessageStore.getMessagesAfterSeq(
        employeeId, batch3.last.seq, limit: 2,
      );
      expect(batch4.length, equals(0));
    });
  });

  // ================================================================
  // 水位线持久化
  // ================================================================
  group('水位线持久化', () {
    test('水位线更新后持久化到 sync_watermark 表', () async {
      await hostSend('user', '你好');
      await hostSend('assistant', '回复');

      final pulled = await clientPull();
      clientUpdateWatermark(pulled.last.seq);

      // 从 sync_watermark 表直接查询验证
      final watermark = clientWatermarkStore.getWatermark(employeeId);
      expect(watermark, isNotNull);
      expect(watermark!.lastSeq, equals(2));
    });

    test('水位线在 DatabaseManager 重新初始化后保留', () async {
      await hostSend('user', '你好');
      final pulled = await clientPull();
      clientUpdateWatermark(pulled.last.seq);

      // 关闭并重新初始化数据库（模拟进程重启）
      await dbManager.close();
      final newInstance = DatabaseManager.getInstance('test');
      await newInstance.initialize(storagePath: dbDir);

      // 重新创建 watermarkStore 验证
      final newWatermarkStore = SyncWatermarkStore(dbManager: newInstance);
      expect(newWatermarkStore.getLastSeq(employeeId), equals(1),
          reason: '重启后水位线应保留');
    });
  });

  // ================================================================
  // 水位线 MAX 语义
  // ================================================================
  group('水位线 MAX 语义（防回退）', () {
    test('updateLastSeq 只升不降', () async {
      // 更新到 10
      clientWatermarkStore.updateLastSeq(employeeId, 10);
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(10));

      // 尝试用 5 覆盖（应被 MAX 忽略）
      clientWatermarkStore.updateLastSeq(employeeId, 5);
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(10),
          reason: '小值不应覆盖大值');
    });

    test('并发模拟：先更新大值再小值，水位线保持大值', () async {
      // 模拟两个并发来源
      clientWatermarkStore.updateLastSeq(employeeId, 100);
      clientWatermarkStore.updateLastSeq(employeeId, 50);
      clientWatermarkStore.updateLastSeq(employeeId, 80);

      expect(clientWatermarkStore.getLastSeq(employeeId), equals(100),
          reason: '应保持最大值');
    });

    test('从 0 递增更新水位线', () async {
      for (int i = 1; i <= 5; i++) {
        clientWatermarkStore.updateLastSeq(employeeId, i);
        expect(clientWatermarkStore.getLastSeq(employeeId), equals(i));
      }
    });
  });

  // ================================================================
  // 端到端：发送 + 增量拉取 + 水位线
  // ================================================================
  group('端到端场景', () {
    test('完整流程：Host 发 5 条 → Client 分 2 批拉取 → 验证水位线', () async {
      // Host 发送 5 条
      for (int i = 1; i <= 5; i++) {
        await hostSend('user', '第${i}条消息');
      }

      // Client 第一次拉取（limit=3）
      final batch1 = await hostMessageStore.getMessagesAfterSeq(employeeId, 0, limit: 3);
      expect(batch1.length, equals(3));
      clientUpdateWatermark(batch1.last.seq);

      // Client 第二次拉取（limit=3）
      final batch2 = await hostMessageStore.getMessagesAfterSeq(
        employeeId, batch1.last.seq, limit: 3,
      );
      expect(batch2.length, equals(2));

      // 合并更新水位线
      clientUpdateWatermark(batch2.last.seq);
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(5));

      // 再拉一次，应为空
      final batch3 = await hostMessageStore.getMessagesAfterSeq(
        employeeId, batch2.last.seq, limit: 3,
      );
      expect(batch3.length, equals(0));
    });

    test('Host 发消息 → Client 已拉到 seq=3 → Host 再发 → Client 只拉新增', () async {
      // 初始 3 条
      await hostSend('user', 'A');
      await hostSend('assistant', 'A回复');
      await hostSend('user', 'B');

      // Client 全量拉取
      final init = await clientPull();
      expect(init.length, equals(3));
      clientUpdateWatermark(init.last.seq); // lastSeq = 3

      // Host 继续发 2 条
      await hostSend('assistant', 'B回复');
      await hostSend('user', 'C');

      // Client 增量拉取
      final delta = await clientPull();
      expect(delta.length, equals(2));
      expect(delta.first.seq, equals(4));
      expect(delta.last.seq, equals(5));
    });

    test('跨 employee 隔离：不同员工的消息和水位线独立', () async {
      const empA = 'employee-A';
      const empB = 'employee-B';

      // Host 为 empA 发 2 条
      final msgA1 = createMessage(uuid: const Uuid().v4(), role: 'user', content: 'A的消息1', empId: empA);
      await hostMessageStore.add(msgA1);

      final msgA2 = createMessage(uuid: const Uuid().v4(), role: 'assistant', content: 'A回复', empId: empA);
      await hostMessageStore.add(msgA2);

      // Host 为 empB 发 3 条
      for (int i = 0; i < 3; i++) {
        final msg = createMessage(uuid: const Uuid().v4(), role: 'user', content: 'B的消息$i', empId: empB);
        await hostMessageStore.add(msg);
      }

      // 拉取 empA 的消息
      final empAMessages = await hostMessageStore.getMessagesAfterSeq(empA, 0);
      expect(empAMessages.length, equals(2));

      // 拉取 empB 的消息
      final empBMessages = await hostMessageStore.getMessagesAfterSeq(empB, 0);
      expect(empBMessages.length, equals(3));

      // 水位线独立
      clientWatermarkStore.updateLastSeq(empA, 2);
      clientWatermarkStore.updateLastSeq(empB, 3);

      expect(clientWatermarkStore.getLastSeq(empA), equals(2));
      expect(clientWatermarkStore.getLastSeq(empB), equals(3));

      // empA 拉取新增为空
      final empANew = await hostMessageStore.getMessagesAfterSeq(empA, 2);
      expect(empANew.length, equals(0));
    });

    test('空消息列表拉取不报错', () async {
      // 没有消息，拉取应为空
      final pulled = await clientPull();
      expect(pulled.length, equals(0));

      // 水位线仍为 0
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(0));
    });
  });

  // ================================================================
  // getMaxSeq 场景
  // ================================================================
  group('getMaxSeq', () {
    test('空表返回 0', () {
      expect(hostMessageStore.getMaxSeq(), equals(0));
    });

    test('有消息后返回最大 seq', () async {
      await hostSend('user', 'A');
      await hostSend('assistant', '回复A');
      await hostSend('user', 'B');

      expect(hostMessageStore.getMaxSeq(), equals(3));
    });

    test('getMaxSeqForEmployee 按 employee 隔离', () async {
      const empA = 'max-emp-A';
      const empB = 'max-emp-B';

      final msgA = createMessage(uuid: const Uuid().v4(), role: 'user', content: 'A', empId: empA);
      await hostMessageStore.add(msgA);

      final msgB = createMessage(uuid: const Uuid().v4(), role: 'user', content: 'B', empId: empB);
      await hostMessageStore.add(msgB);

      // empA 和 empB 各只有 1 条，maxSeq 各为 1（同一个表自增）
      expect(hostMessageStore.getMaxSeqForEmployee(empA), equals(1));
      expect(hostMessageStore.getMaxSeqForEmployee(empB), equals(2));
    });
  });

  // ================================================================
  // 软删除同步
  // ================================================================
  group('软删除同步', () {
    test('softDeleteForSync 更新消息 seq，使其可被增量拉取', () async {
      // Host 发送 3 条
      await hostSend('user', '保留');
      final msgToDelete = await hostSend('assistant', '待删除');
      await hostSend('user', '保留2');

      // Client 拉取全部并更新水位线
      final init = await clientPull();
      expect(init.length, equals(3));
      clientUpdateWatermark(init.last.seq); // lastSeq = 3

      // Host 软删除第 2 条
      hostMessageStore.softDeleteForSync(msgToDelete.id);

      // 验证：被删除消息获得新 seq
      final deletedMsg = await hostMessageStore.find(null, msgToDelete.id);
      expect(deletedMsg!.deleted, isTrue);
      expect(deletedMsg.seq, greaterThan(3), reason: '删除后 seq 应大于原值');

      // Client 增量拉取：应能拉到删除事件
      final delta = await clientPull();
      expect(delta.length, equals(1));
      expect(delta.first.deleted, isTrue);
      expect(delta.first.id, equals(msgToDelete.id));
    });

    test('softDeleteBySessionForSync 批量删除并更新 seq', () async {
      // Host 发送 5 条
      final ids = <String>[];
      for (int i = 0; i < 5; i++) {
        final msg = await hostSend('user', '消息$i');
        ids.add(msg.id);
      }

      // Client 拉取全部并更新水位线
      final init = await clientPull();
      expect(init.length, equals(5));
      clientUpdateWatermark(init.last.seq); // lastSeq = 5

      // Host 清空会话（softDeleteBySessionForSync）
      await hostMessageStore.softDeleteBySessionForSync(employeeId);

      // Client 增量拉取：应能拉到 5 条删除事件
      final delta = await clientPull();
      expect(delta.length, equals(5));
      expect(delta.every((m) => m.deleted), isTrue,
          reason: '所有消息都应是删除状态');

      // 验证 seq 都大于 5
      expect(delta.every((m) => m.seq > 5), isTrue,
          reason: '删除事件的 seq 都应大于之前的水位线');
    });

    test('getMessagesAfterSeq 不过滤 deleted（包含删除事件）', () async {
      await hostSend('user', 'A');
      await hostSend('assistant', 'B');

      // 软删除第 1 条（更新 seq）
      final all = await hostMessageStore.getMessages(null, employeeId);
      hostMessageStore.softDeleteForSync(all.first.id);

      // getMessagesAfterSeq 应包含被删除的消息
      final pulled = await hostMessageStore.getMessagesAfterSeq(employeeId, 0);
      expect(pulled.length, equals(2));

      // 其中一条 deleted=true
      final deletedCount = pulled.where((m) => m.deleted).length;
      expect(deletedCount, equals(1));
    });

    test('普通 update deleted 不更新 seq（非同步删除）', () async {
      await hostSend('user', 'A');
      final all = await hostMessageStore.getMessages(null, employeeId);
      final msg = all.first;
      final originalSeq = msg.seq;

      await hostMessageStore.update(msg.copyWith(
        deleted: true,
        updatedAt: DateTime.now(),
      ));

      final updated = await hostMessageStore.find(null, msg.id);
      expect(updated!.seq, equals(originalSeq), reason: '普通更新 seq 不变');
      expect(updated.deleted, isTrue);
    });

    test('完整流程：Host 删 → Client 增量拉取 → 本地也删除', () async {
      // 1. Host 发 5 条
      for (int i = 1; i <= 5; i++) {
        await hostSend('user', '消息$i');
      }

      // 2. Client 全量拉取并更新水位线
      final batch1 = await clientPull();
      expect(batch1.length, equals(5));
      clientUpdateWatermark(batch1.last.seq); // lastSeq = 5

      // 3. Client 将消息存到本地消息表
      for (final msg in batch1) {
        await clientMessageStore.add(msg);
      }
      var clientMessages = await clientMessageStore.getMessages(null, employeeId);
      expect(clientMessages.length, equals(5));

      // 4. Host 删除 seq=2 和 seq=4
      final hostAll = await hostMessageStore.getMessages(null, employeeId);
      final toDelete = hostAll.where((m) => m.seq == 2 || m.seq == 4).toList();
      for (final msg in toDelete) {
        hostMessageStore.softDeleteForSync(msg.id);
      }

      // 5. Client 增量拉取
      final delta = await clientPull();
      expect(delta.length, equals(2));
      expect(delta.every((m) => m.deleted), isTrue);

      // 6. Client 更新水位线
      clientUpdateWatermark(delta.last.seq);

      // 7. 模拟 Client 同步删除：从本地也删除
      for (final msg in delta) {
        await clientMessageStore.softDeleteForSync(msg.id);
      }

      // 8. 验证 Client 本地只剩 3 条有效消息
      clientMessages = await clientMessageStore.getMessages(null, employeeId);
      final activeMessages = clientMessages.where((m) => !m.deleted).toList();
      expect(activeMessages.length, equals(3));
    });
  });

  // ================================================================
  // 清空重新同步（水位线 > 服务端 maxSeq）
  // ================================================================
  group('清空重新同步', () {
    test('Client 水位线大于 Host maxSeq 时应清空本地并重新同步', () async {
      // 1. Host 发 5 条消息
      for (int i = 1; i <= 5; i++) {
        await hostSend('user', '消息$i');
      }

      // 2. Client 全量拉取并更新水位线
      final batch = await clientPull();
      expect(batch.length, equals(5));
      clientUpdateWatermark(batch.last.seq); // lastSeq = 5

      // 3. 验证：Client 水位线 > Host maxSeq
      final clientLastSeq = clientWatermarkStore.getLastSeq(employeeId);
      final hostMaxSeq = hostMessageStore.getMaxSeq();
      expect(clientLastSeq, equals(5));
      expect(hostMaxSeq, equals(5));

      // 4. 模拟 Host 端清空数据（服务端数据被清除），
      //    同时清空 Client 本地数据和水位线，模拟完整重置流程
      dbManager.db.execute('DELETE FROM messages');
      dbManager.db.execute('DELETE FROM sync_watermark');

      // 5. 验证清空后的状态
      expect(hostMessageStore.getMaxSeq(), equals(0));
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(0));

      // 6. Host 重新发 3 条消息（模拟重新同步）
      for (int i = 1; i <= 3; i++) {
        await hostSend('user', '新消息$i');
      }

      // 7. Client 基于水位线 0 全量拉取（等同于重新同步）
      final newBatch = await clientPull();
      expect(newBatch.length, equals(3));

      // 8. 更新水位线
      clientUpdateWatermark(newBatch.last.seq);
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(3));
    });

    test('水位线等于 maxSeq 时不触发清空（正常情况）', () async {
      // Host 发 3 条
      await hostSend('user', 'A');
      await hostSend('assistant', '回复A');
      await hostSend('user', 'B');

      // Client 拉取并更新水位线
      final batch = await clientPull();
      clientUpdateWatermark(batch.last.seq); // lastSeq = 3

      // Host maxSeq 也为 3
      final maxSeq = hostMessageStore.getMaxSeq();
      expect(maxSeq, equals(3));

      // lastSeq == maxSeq，不触发清空
      final clientLastSeq = clientWatermarkStore.getLastSeq(employeeId);
      expect(clientLastSeq <= maxSeq, isTrue,
          reason: '水位线不超过 maxSeq，不应清空');
    });

    test('水位线为 0 且 maxSeq 为 0 时不触发清空（初始状态）', () async {
      // 两者都是 0，属于正常初始状态
      final clientLastSeq = clientWatermarkStore.getLastSeq(employeeId);
      final hostMaxSeq = hostMessageStore.getMaxSeq();
      expect(clientLastSeq, equals(0));
      expect(hostMaxSeq, equals(0));

      // 条件 lastSeq > 0 && lastSeq > maxSeq 不满足，不应清空
      expect(clientLastSeq > 0, isFalse,
          reason: '水位线为 0 时不触发清空条件');
    });

    test('清空重新同步后，增量拉取正常工作', () async {
      // 1. 初始同步
      for (int i = 1; i <= 3; i++) {
        await hostSend('user', '旧消息$i');
      }
      var batch = await clientPull();
      clientUpdateWatermark(batch.last.seq); // lastSeq = 3

      // 2. Host 清空，同时重置水位线
      dbManager.db.execute('DELETE FROM messages');
      dbManager.db.execute('DELETE FROM sync_watermark');

      // 3. Host 发新数据
      await hostSend('user', '新A');
      await hostSend('assistant', '新回复');

      // 4. 重新同步
      batch = await clientPull();
      expect(batch.length, equals(2));
      clientUpdateWatermark(batch.last.seq); // lastSeq = 2

      // 5. Host 再发 1 条
      await hostSend('user', '新B');

      // 6. 增量拉取正常
      final delta = await clientPull();
      expect(delta.length, equals(1));
      expect(delta.first.seq, equals(3));
    });

    test('清空重新同步后水位线持久化正确', () async {
      // 1. 初始同步
      await hostSend('user', 'A');
      var batch = await clientPull();
      clientUpdateWatermark(batch.last.seq); // lastSeq = 1

      // 2. Host 清空，同时重置水位线
      dbManager.db.execute('DELETE FROM messages');
      dbManager.db.execute('DELETE FROM sync_watermark');

      // 3. 重新同步
      for (int i = 1; i <= 3; i++) {
        await hostSend('user', '新$i');
      }
      batch = await clientPull();
      clientUpdateWatermark(batch.last.seq); // lastSeq = 3

      // 4. 模拟进程重启：水位线应为 3
      await dbManager.close();
      final newInstance = DatabaseManager.getInstance('test');
      await newInstance.initialize(storagePath: dbDir);

      final newWatermarkStore = SyncWatermarkStore(dbManager: newInstance);
      expect(newWatermarkStore.getLastSeq(employeeId), equals(3),
          reason: '重启后水位线应为重新同步后的值');
    });
  });
}
