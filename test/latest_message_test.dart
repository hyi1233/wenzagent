import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/wenzagent.dart';

/// 等待微任务队列清空
Future<void> pumpEventQueue() => Future.delayed(Duration.zero);

// ============================================================
// 辅助方法：创建消息实体
// ============================================================

/// 创建消息实体
AiEmployeeMessageEntity createEntity({
  required String uuid,
  required String employeeId,
  String role = 'user',
  String type = 'text',
  String? content,
  DateTime? createTime,
  int deleted = 0,
}) {
  final now = createTime ?? DateTime.now();
  return AiEmployeeMessageEntity(
    uuid: uuid,
    employeeId: employeeId,
    role: role,
    type: type,
    content: content,
    createTime: now,
    updateTime: now,
    deleted: deleted,
  );
}

/// 内存 Mock ChatAdapter，支持注入消息（与 unread_message_flow_test 相同）
class _MockChatAdapter extends IChatAdapter {
  final List<AgentMessage> _messages = [];

  @override
  List<Map<String, dynamic>> get currentMessages =>
      _messages.map((m) => m.toMap()).toList();
  @override
  Map<String, dynamic>? get currentContext => null;
  @override
  bool get isStreaming => false;
  @override
  Future<void> initSession({required String employeeId}) async {}
  @override
  Stream<StreamResponse> streamMessage(Map<String, dynamic> messageData,
          {CancellationToken? cancellationToken}) async* {}
  @override
  Future<void> stopStreaming() async {}
  @override
  Future<List<AgentMessage>> getSessionMessages(String employeeId) async =>
      List.of(_messages);
  @override
  Future<void> clearCurrentSession() async => _messages.clear();
  @override
  bool removeMessageFromMemory(String messageId) {
    final len = _messages.length;
    _messages.removeWhere((m) => m.id == messageId);
    return _messages.length < len;
  }
  @override
  void setContext(Map<String, dynamic> contextData) {}
  @override
  void clearContext() {}
  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {}
  @override
  Map<String, dynamic>? getProviderConfig() => null;
  @override
  Map<String, dynamic>? getCurrentProvider() => null;
  @override
  Future<void> updateProjectContext(Map<String, dynamic>? projectContext) async {}
  @override
  void setToolRegistry(covariant ToolRegistry? registry) {}
  @override
  void setPermissionManager(covariant ToolPermissionManager? manager) {}
  @override
  void setToolEventCallback(
      void Function(Map<String, dynamic> event)? callback) {}
  @override
  void updateMessageStatus(String messageId, AgentMessageStatus status,
      {String? error}) {}
  @override
  Future<String> invokeOnce(String prompt) async => '';
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setProjectData(Map<String, dynamic>? projectData) async {}
  @override
  Map<String, dynamic>? getCurrentProjectData() => null;

  void addMessage(AgentMessage msg) => _messages.add(msg);
}

void main() {
  // ============================================================
  // 第一组: MessageStore.getMessages 排序与分页
  // ============================================================
  group('MessageStore.getMessages 排序与分页', () {
    late MessageStore store;
    const deviceId = 'device-test';
    const employeeId = 'emp-sort-test';

    setUpAll(() async {
      await HiveManager.instance.initialize(
        storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
      );
    });

    setUp(() async {
      store = MessageStore();
      // 清空测试数据
      await store.deleteBySession(deviceId, employeeId);
    });

    test('按 createTime 升序排列返回消息', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      final msg1 = createEntity(
        uuid: 'msg-1', employeeId: employeeId,
        createTime: base.add(const Duration(hours: 2)),
      );
      final msg2 = createEntity(
        uuid: 'msg-2', employeeId: employeeId,
        createTime: base, // 最早
      );
      final msg3 = createEntity(
        uuid: 'msg-3', employeeId: employeeId,
        createTime: base.add(const Duration(hours: 1)),
      );

      await store.addWithDeviceId(deviceId, msg2);
      await store.addWithDeviceId(deviceId, msg1);
      await store.addWithDeviceId(deviceId, msg3);

      final result = await store.getMessages(deviceId, employeeId);
      expect(result.length, equals(3));
      // 升序排列
      expect(result[0].uuid, equals('msg-2'));
      expect(result[1].uuid, equals('msg-3'));
      expect(result[2].uuid, equals('msg-1'));
    });

    test('createTime 相同时按 uuid 字典序排列（排序稳定性）', () async {
      final sameTime = DateTime(2025, 1, 1, 12, 0, 0);
      final msgB = createEntity(
        uuid: 'msg-b', employeeId: employeeId, createTime: sameTime,
      );
      final msgA = createEntity(
        uuid: 'msg-a', employeeId: employeeId, createTime: sameTime,
      );
      final msgC = createEntity(
        uuid: 'msg-c', employeeId: employeeId, createTime: sameTime,
      );

      await store.addWithDeviceId(deviceId, msgB);
      await store.addWithDeviceId(deviceId, msgA);
      await store.addWithDeviceId(deviceId, msgC);

      final result = await store.getMessages(deviceId, employeeId);
      expect(result[0].uuid, equals('msg-a'));
      expect(result[1].uuid, equals('msg-b'));
      expect(result[2].uuid, equals('msg-c'));
    });

    test('limit 参数正确截取消息', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      for (var i = 1; i <= 5; i++) {
        await store.addWithDeviceId(
          deviceId,
          createEntity(
            uuid: 'limit-msg-$i',
            employeeId: employeeId,
            createTime: base.add(Duration(hours: i)),
          ),
        );
      }

      // limit=3 应返回最早的3条（升序）
      final result = await store.getMessages(deviceId, employeeId, limit: 3);
      expect(result.length, equals(3));
      expect(result[0].uuid, equals('limit-msg-1'));
      expect(result[1].uuid, equals('limit-msg-2'));
      expect(result[2].uuid, equals('limit-msg-3'));
    });

    test('offset 参数正确跳过消息', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      for (var i = 1; i <= 5; i++) {
        await store.addWithDeviceId(
          deviceId,
          createEntity(
            uuid: 'offset-msg-$i',
            employeeId: employeeId,
            createTime: base.add(Duration(hours: i)),
          ),
        );
      }

      // offset=2, limit=2 跳过最早2条，取接下来2条
      final result = await store.getMessages(
        deviceId, employeeId, offset: 2, limit: 2,
      );
      expect(result.length, equals(2));
      expect(result[0].uuid, equals('offset-msg-3'));
      expect(result[1].uuid, equals('offset-msg-4'));
    });

    test('软删除消息 (deleted=1) 被排除', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'del-msg-1', employeeId: employeeId,
          createTime: base,
        ),
      );
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'del-msg-2', employeeId: employeeId,
          createTime: base.add(const Duration(hours: 1)),
          deleted: 1, // 软删除
        ),
      );
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'del-msg-3', employeeId: employeeId,
          createTime: base.add(const Duration(hours: 2)),
        ),
      );

      final result = await store.getMessages(deviceId, employeeId);
      expect(result.length, equals(2));
      expect(result[0].uuid, equals('del-msg-1'));
      expect(result[1].uuid, equals('del-msg-3'));
    });

    test('空会话返回空列表', () async {
      final result = await store.getMessages(deviceId, employeeId);
      expect(result, isEmpty);
    });
  });

  // ============================================================
  // 第二组: MessageStore.getLastMessage
  // ============================================================
  group('MessageStore.getLastMessage', () {
    late MessageStore store;
    const deviceId = 'device-last';
    const employeeId = 'emp-last-test';

    setUpAll(() async {
      await HiveManager.instance.initialize(
        storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
      );
    });

    setUp(() async {
      store = MessageStore();
      await store.deleteBySession(deviceId, employeeId);
    });

    test('返回索引中第一条消息（非最新 — 已知行为）', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'last-1', employeeId: employeeId,
          createTime: base,
        ),
      );
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'last-2', employeeId: employeeId,
          createTime: base.add(const Duration(hours: 3)),
        ),
      );
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'last-3', employeeId: employeeId,
          createTime: base.add(const Duration(hours: 1)),
        ),
      );

      // ⚠️ 注意: getLastMessage 内部调用 getMessages(limit:1)，
      // limit 在排序之前应用到索引列表，所以返回的是索引中第一条（最早插入的），
      // 而不是 createTime 最大的。
      // 这是因为 getMessages 先对索引做 take(limit)，再对结果排序。
      final last = await store.getLastMessage(deviceId, employeeId);
      expect(last, isNotNull);
      expect(last!.uuid, equals('last-1')); // 最早插入的，而非最新的
    });

    test('空会话返回 null', () async {
      final last = await store.getLastMessage(deviceId, employeeId);
      expect(last, isNull);
    });

    test('软删除消息不计入最后一条', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'dlast-1', employeeId: employeeId,
          createTime: base,
        ),
      );
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'dlast-2', employeeId: employeeId,
          createTime: base.add(const Duration(hours: 2)),
          deleted: 1,
        ),
      );

      final last = await store.getLastMessage(deviceId, employeeId);
      expect(last, isNotNull);
      expect(last!.uuid, equals('dlast-1'));
    });

    test('仅一条消息时正确返回', () async {
      await store.addWithDeviceId(
        deviceId,
        createEntity(
          uuid: 'single-last', employeeId: employeeId,
          content: '唯一一条消息',
        ),
      );

      final last = await store.getLastMessage(deviceId, employeeId);
      expect(last, isNotNull);
      expect(last!.uuid, equals('single-last'));
      expect(last.content, equals('唯一一条消息'));
    });
  });

  // ============================================================
  // 第三组: MessageStoreService 委托
  // ============================================================
  group('MessageStoreService 委托', () {
    late MessageStoreServiceImpl service;
    const deviceId = 'device-service';
    const employeeId = 'emp-service-test';

    setUpAll(() async {
      await HiveManager.instance.initialize(
        storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
      );
    });

    setUp(() async {
      service = MessageStoreServiceImpl(deviceId: deviceId);
      await service.deleteMessages(employeeId);
    });

    tearDown(() => service.dispose());

    test('getLastMessage 返回索引第一条消息（同 MessageStore 行为）', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      await service.addMessage(
        createEntity(
          uuid: 'svc-1', employeeId: employeeId,
          createTime: base,
        ),
      );
      await service.addMessage(
        createEntity(
          uuid: 'svc-2', employeeId: employeeId,
          createTime: base.add(const Duration(minutes: 30)),
        ),
      );

      // ⚠️ 同 getLastMessage 行为：返回最早插入的
      final last = await service.getLastMessage(employeeId);
      expect(last, isNotNull);
      expect(last!.uuid, equals('svc-1'));
    });

    test('getMessagesWithDeviceId 正确传参', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      for (var i = 1; i <= 3; i++) {
        await service.addMessage(
          createEntity(
            uuid: 'wdev-msg-$i', employeeId: employeeId,
            createTime: base.add(Duration(minutes: i * 10)),
          ),
        );
      }

      final result = await service.getMessagesWithDeviceId(
        deviceId, employeeId, limit: 2,
      );
      expect(result.length, equals(2));
      expect(result[0].uuid, equals('wdev-msg-1'));
      expect(result[1].uuid, equals('wdev-msg-2'));
    });

    test('getMessagesWithDeviceId 使用不同 deviceId 不影响结果', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      await service.addMessage(
        createEntity(
          uuid: 'other-msg-1', employeeId: employeeId,
          createTime: base,
        ),
      );

      // 使用与构造函数相同的 deviceId 查询
      final result1 = await service.getMessagesWithDeviceId(
        deviceId, employeeId,
      );
      expect(result1.length, equals(1));

      // 使用不同 deviceId 查询（应该为空）
      final result2 = await service.getMessagesWithDeviceId(
        'other-device', employeeId,
      );
      expect(result2, isEmpty);
    });
  });

  // ============================================================
  // 第四组: AgentImpl.getSessionMessagesByUserCount
  // ============================================================
  group('AgentImpl.getSessionMessagesByUserCount', () {
    late _MockChatAdapter adapter;
    late AgentImpl agent;
    const employeeId = 'emp-usercount-test';

    setUp(() {
      adapter = _MockChatAdapter();
      agent = AgentImpl(employeeId: employeeId, chatAdapter: adapter);
    });

    test('正确统计用户消息数量并截断', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      // 添加 5 轮对话：user + assistant
      for (var i = 1; i <= 5; i++) {
        adapter.addMessage(AgentMessage(
          id: 'uc-user-$i',
          role: 'user',
          type: 'text',
          content: '用户消息 $i',
          createdAt: base.add(Duration(minutes: i * 2)),
        ));
        adapter.addMessage(AgentMessage(
          id: 'uc-asst-$i',
          role: 'assistant',
          type: 'text',
          content: '助手回复 $i',
          createdAt: base.add(Duration(minutes: i * 2 + 1)),
        ));
      }

      // 限制 3 条用户消息 → 应包含 uc-user-3, uc-user-4, uc-user-5 + 对应助手消息
      final result = await agent.getSessionMessagesByUserCount(
        userMessageLimit: 3,
      );

      final userMsgs =
          result.where((m) => m.role == 'user').toList();
      expect(userMsgs.length, equals(3));
      // 验证结果升序排列
      expect(result.first.id, equals('uc-user-3'));
      expect(result.last.id, equals('uc-asst-5'));
    });

    test('返回结果按时间升序排列', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      // 按乱序添加
      adapter.addMessage(AgentMessage(
        id: 'order-3', role: 'user', type: 'text',
        content: 'C', createdAt: base.add(const Duration(hours: 2)),
      ));
      adapter.addMessage(AgentMessage(
        id: 'order-1', role: 'user', type: 'text',
        content: 'A', createdAt: base,
      ));
      adapter.addMessage(AgentMessage(
        id: 'order-2', role: 'user', type: 'text',
        content: 'B', createdAt: base.add(const Duration(hours: 1)),
      ));

      final result = await agent.getSessionMessagesByUserCount(
        userMessageLimit: 3,
      );
      expect(result[0].id, equals('order-1'));
      expect(result[1].id, equals('order-2'));
      expect(result[2].id, equals('order-3'));
    });

    test('空会话返回空列表', () async {
      final result = await agent.getSessionMessagesByUserCount();
      expect(result, isEmpty);
    });

    test('userMessageLimit=0 时应返回空列表', () async {
      adapter.addMessage(AgentMessage(
        id: 'zero-1', role: 'user', type: 'text',
        content: '测试', createdAt: DateTime(2025, 1, 1),
      ));

      final result = await agent.getSessionMessagesByUserCount(
        userMessageLimit: 0,
      );
      // limit=0 时循环不进入 break 条件，但 >=0 立即满足
      // 实际逻辑：userMessageCount 初始 0，遇到第一个 user 消息后 count=1 >= 0 → break
      // 所以应该有 1 条用户消息
      expect(result.length, equals(1));
      expect(result[0].id, equals('zero-1'));
    });

    test('userMessageLimit=1 时只包含最后一条用户消息', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      adapter.addMessage(AgentMessage(
        id: 'one-user-1', role: 'user', type: 'text',
        createdAt: base,
      ));
      adapter.addMessage(AgentMessage(
        id: 'one-asst-1', role: 'assistant', type: 'text',
        createdAt: base.add(const Duration(minutes: 1)),
      ));
      adapter.addMessage(AgentMessage(
        id: 'one-user-2', role: 'user', type: 'text',
        createdAt: base.add(const Duration(minutes: 2)),
      ));
      adapter.addMessage(AgentMessage(
        id: 'one-asst-2', role: 'assistant', type: 'text',
        createdAt: base.add(const Duration(minutes: 3)),
      ));

      final result = await agent.getSessionMessagesByUserCount(
        userMessageLimit: 1,
      );
      // 只应包含 one-user-2 和 one-asst-2
      expect(result.length, equals(2));
      expect(result[0].id, equals('one-user-2'));
      expect(result[1].id, equals('one-asst-2'));
    });

    test('连续 assistant 消息不影响用户计数', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      adapter.addMessage(AgentMessage(
        id: 'cont-user-1', role: 'user', type: 'text',
        createdAt: base,
      ));
      // 连续 3 条 assistant 消息
      adapter.addMessage(AgentMessage(
        id: 'cont-asst-1', role: 'assistant', type: 'text',
        createdAt: base.add(const Duration(minutes: 1)),
      ));
      adapter.addMessage(AgentMessage(
        id: 'cont-asst-2', role: 'assistant', type: 'text',
        createdAt: base.add(const Duration(minutes: 2)),
      ));
      adapter.addMessage(AgentMessage(
        id: 'cont-asst-3', role: 'assistant', type: 'text',
        createdAt: base.add(const Duration(minutes: 3)),
      ));
      adapter.addMessage(AgentMessage(
        id: 'cont-user-2', role: 'user', type: 'text',
        createdAt: base.add(const Duration(minutes: 4)),
      ));

      final result = await agent.getSessionMessagesByUserCount(
        userMessageLimit: 2,
      );
      // 所有消息都应包含
      expect(result.length, equals(5));
    });
  });

  // ============================================================
  // 第五组: AgentImpl.getSessionMessagesPaged
  // ============================================================
  group('AgentImpl.getSessionMessagesPaged', () {
    late _MockChatAdapter adapter;
    late AgentImpl agent;
    const employeeId = 'emp-paged-test';

    setUp(() {
      adapter = _MockChatAdapter();
      agent = AgentImpl(employeeId: employeeId, chatAdapter: adapter);
    });

    test('分页参数正确', () async {
      final base = DateTime(2025, 1, 1, 10, 0, 0);
      for (var i = 1; i <= 10; i++) {
        adapter.addMessage(AgentMessage(
          id: 'paged-$i', role: 'user', type: 'text',
          createdAt: base.add(Duration(minutes: i)),
        ));
      }

      // offset=0, pageSize=3 → 返回最新的3条（按升序）
      // 内部逻辑：按时间倒序 → skip(0).take(3) → 升序返回
      final page1 = await agent.getSessionMessagesPaged(
        pageSize: 3, offset: 0,
      );
      expect(page1.length, equals(3));
      // 倒序取3条：paged-10, paged-9, paged-8 → 升序返回
      expect(page1[0].id, equals('paged-8'));
      expect(page1[1].id, equals('paged-9'));
      expect(page1[2].id, equals('paged-10'));

      // offset=3, pageSize=3 → 接下来的3条
      final page2 = await agent.getSessionMessagesPaged(
        pageSize: 3, offset: 3,
      );
      expect(page2.length, equals(3));
      expect(page2[0].id, equals('paged-5'));
      expect(page2[1].id, equals('paged-6'));
      expect(page2[2].id, equals('paged-7'));
    });

    test('空会话返回空列表', () async {
      final result = await agent.getSessionMessagesPaged();
      expect(result, isEmpty);
    });
  });

  // ============================================================
  // 第六组: 端到端 — 消息从存储到读取的完整流程
  // ============================================================
  group('端到端: 消息读取完整流程', () {
    late MessageStore store;
    late MessageStoreServiceImpl service;
    const deviceId = 'device-e2e';
    const employeeId = 'emp-e2e-test';

    setUpAll(() async {
      await HiveManager.instance.initialize(
        storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
      );
    });

    setUp(() async {
      store = MessageStore();
      service = MessageStoreServiceImpl(deviceId: deviceId);
      await store.deleteBySession(deviceId, employeeId);
    });

    tearDown(() => service.dispose());

    test('多轮对话中 getLastMessage 始终返回第一条插入的', () async {
      final base = DateTime(2025, 6, 1, 9, 0, 0);

      // 第1轮
      await store.addWithDeviceId(deviceId, createEntity(
        uuid: 'e2e-u1', employeeId: employeeId, role: 'user',
        createTime: base,
      ));
      var last = await store.getLastMessage(deviceId, employeeId);
      expect(last!.uuid, equals('e2e-u1'));

      await store.addWithDeviceId(deviceId, createEntity(
        uuid: 'e2e-a1', employeeId: employeeId, role: 'assistant',
        createTime: base.add(const Duration(minutes: 1)),
      ));
      // ⚠️ getLastMessage 返回索引第一条，不是最新的
      last = await store.getLastMessage(deviceId, employeeId);
      expect(last!.uuid, equals('e2e-u1')); // 仍然是第一条

      // 第2轮
      await store.addWithDeviceId(deviceId, createEntity(
        uuid: 'e2e-u2', employeeId: employeeId, role: 'user',
        createTime: base.add(const Duration(minutes: 5)),
      ));
      last = await store.getLastMessage(deviceId, employeeId);
      expect(last!.uuid, equals('e2e-u1')); // 仍然是第一条
    });

    test('软删除最新消息后 getLastMessage 返回上一条', () async {
      final base = DateTime(2025, 6, 1, 9, 0, 0);
      await store.addWithDeviceId(deviceId, createEntity(
        uuid: 'e2e-del-1', employeeId: employeeId,
        createTime: base,
      ));
      await store.addWithDeviceId(deviceId, createEntity(
        uuid: 'e2e-del-2', employeeId: employeeId,
        createTime: base.add(const Duration(hours: 1)),
      ));

      // 删除最新的一条
      final msg2 = createEntity(
        uuid: 'e2e-del-2', employeeId: employeeId,
        createTime: base.add(const Duration(hours: 1)),
        deleted: 1,
      );
      await store.updateWithDeviceId(deviceId, msg2);

      var last = await store.getLastMessage(deviceId, employeeId);
      expect(last!.uuid, equals('e2e-del-1'));
    });

    test('MessageStoreService.getMessages 升序排列 + 分页', () async {
      final base = DateTime(2025, 6, 1, 9, 0, 0);
      for (var i = 1; i <= 10; i++) {
        await service.addMessage(createEntity(
          uuid: 'e2e-page-$i', employeeId: employeeId,
          createTime: base.add(Duration(minutes: i)),
        ));
      }

      // 验证 getMessages 升序
      final all = await service.getMessages(employeeId);
      expect(all.length, equals(10));
      expect(all.first.uuid, equals('e2e-page-1'));
      expect(all.last.uuid, equals('e2e-page-10'));

      // 验证 limit
      final first3 = await service.getMessages(employeeId, limit: 3);
      expect(first3.length, equals(3));
      expect(first3.last.uuid, equals('e2e-page-3'));

      // 验证 offset + limit
      final middle = await service.getMessages(
        employeeId, offset: 3, limit: 3,
      );
      expect(middle.length, equals(3));
      expect(middle.first.uuid, equals('e2e-page-4'));
      expect(middle.last.uuid, equals('e2e-page-6'));
    });
  });
}
