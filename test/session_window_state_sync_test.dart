import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/agent_event.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';
import 'package:wenzagent/src/shared/chat_message.dart';

// ===== Mock 层 =====

/// 内存模拟 MessageStoreService
///
/// 仅实现 CachedAgentProxy 实际调用的方法，
/// 其他方法抛 UnimplementedError。
class MockMessageStoreService implements MessageStoreService {
  final Map<String, ChatMessage> _messages = {};
  int _lastSeq = 0;
  int _maxSeq = 0;

  @override
  Future<List<ChatMessage>> getMessages(String deviceId, String employeeId,
          {int? limit, int? offset}) =>
      _getAll();

  @override
  Future<List<ChatMessage>> getMessagesWithDeviceId(
          String deviceId, String employeeId,
          {int? limit, int? offset}) =>
      _getAll();

  Future<List<ChatMessage>> _getAll() async =>
      _messages.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));

  @override
  Future<ChatMessage?> getMessage(String deviceId, String uuid) async =>
      _messages[uuid];

  @override
  Future<ChatMessage> addMessage(String deviceId, ChatMessage message,
      {bool updateWatermark = true}) async {
    _messages[message.id] = message;
    if (updateWatermark) {
      final seq = message.seq > 0 ? message.seq : ++_maxSeq;
      if (seq > _lastSeq) _lastSeq = seq;
      if (seq > _maxSeq) _maxSeq = seq;
    }
    return message;
  }

  @override
  Future<void> addMessages(String deviceId, List<ChatMessage> messages) async {
    for (final m in messages) {
      _messages[m.id] = m;
    }
  }

  @override
  Future<void> updateMessage(String deviceId, ChatMessage message,
      {bool updateWatermark = true}) async {
    _messages[message.id] = message;
  }

  @override
  Future<void> updateMessageStatus(
    String deviceId,
    String uuid,
    MessageStatus status, {
    String? error,
  }) async {
    final existing = _messages[uuid];
    if (existing != null) {
      _messages[uuid] = existing.copyWith(status: status);
    }
  }

  @override
  Future<void> batchUpdateMessages(
      String deviceId, List<ChatMessage> messages) async {
    for (final m in messages) {
      _messages[m.id] = m;
    }
  }

  @override
  Future<void> deleteMessages(String deviceId, String employeeId) async {
    _messages.clear();
    _lastSeq = 0;
  }

  @override
  Future<void> softDeleteMessage(String deviceId, String uuid) async {
    final existing = _messages[uuid];
    if (existing != null) {
      _messages[uuid] = existing.copyWith(deleted: true);
    }
  }

  @override
  Future<void> softDeleteBySession(String deviceId, String employeeId) async {
    for (final id in _messages.keys.toList()) {
      _messages[id] = _messages[id]!.copyWith(deleted: true);
    }
  }

  @override
  int deleteMessagesBeforeSeq(
      String deviceId, String employeeId, int beforeSeq) {
    final toDelete = _messages.entries
        .where((e) => e.value.seq > 0 && e.value.seq < beforeSeq)
        .map((e) => e.key)
        .toList();
    for (final id in toDelete) {
      _messages.remove(id);
    }
    return toDelete.length;
  }

  @override
  int getMaxSeq(String deviceId, String employeeId) => _maxSeq;

  @override
  Future<void> hardDeleteMessage(String deviceId, String uuid) async {
    _messages.remove(uuid);
  }

  @override
  Future<ChatMessage?> getLastMessage(String deviceId, String employeeId) =>
      _getAll().then((list) => list.isEmpty ? null : list.last);

  @override
  int getUnreadCount(String deviceId, String employeeId) =>
      _messages.values.where((m) => !m.isRead && m.role.name == 'assistant').length;

  @override
  int getTotalUnreadCount({String deviceId = ''}) => 0;

  @override
  SessionSummaryEntity? getLatestMessageSummary(
          String deviceId, String employeeId) =>
      null;

  @override
  List<SessionSummaryEntity> getAllSummaries({String deviceId = ''}) => [];

  @override
  int markAsReadInDb(String deviceId, String employeeId) {
    int count = 0;
    for (final id in _messages.keys.toList()) {
      final m = _messages[id]!;
      if (!m.isRead) {
        _messages[id] = m.copyWith(isRead: true);
        count++;
      }
    }
    return count;
  }

  @override
  int markAsReadBySeqInDb(String deviceId, String employeeId, int readSeq) {
    int count = 0;
    for (final id in _messages.keys.toList()) {
      final m = _messages[id]!;
      if (!m.isRead && m.seq > 0 && m.seq <= readSeq) {
        _messages[id] = m.copyWith(isRead: true);
        count++;
      }
    }
    return count;
  }

  @override
  List<String> getUnreadMessageIds(String deviceId, String employeeId) =>
      _messages.entries
          .where((e) => !e.value.isRead && e.value.role.name == 'assistant')
          .map((e) => e.key)
          .toList();

  @override
  List<String> getStaleLocalToolCallMessages(
          String deviceId, String employeeId) =>
      [];

  @override
  Stream<MessageChangeEvent> get onMessageChanged => Stream.empty();

  @override
  int getLastSeq(String deviceId, String employeeId) => _lastSeq;

  @override
  void updateLastSeq(String deviceId, String employeeId, int lastSeq) {
    if (lastSeq > _lastSeq) _lastSeq = lastSeq;
  }

  @override
  void resetLastSeq(String deviceId, String employeeId, int lastSeq) {
    _lastSeq = lastSeq;
  }

  @override
  void upsertSummaryFromRemote(SessionSummaryEntity remote) {}
}

/// Mock RPC 调用函数
typedef MockRpcHandler = Future<Map<String, dynamic>> Function(
    String method, Map<String, dynamic> params);

Future<Map<String, dynamic>> _defaultMockRpc(
    String method, Map<String, dynamic> params) async {
  switch (method) {
    case 'agentGetState':
      return AgentStateSnapshot.idle().toMap();
    case 'agentGetPendingPermission':
      return {};
    case 'agentGetPendingConfirm':
      return {};
    case 'agentGetProvider':
      return {};
    case 'agentGetProjectUuid':
      return {'projectUuid': null};
    case 'agentGetSkills':
      return {'skills': []};
    case 'agentGetMcpConfigs':
      return {'mcpConfigs': []};
    case 'agentGetMaxSeq':
      return {'maxSeq': 0};
    case 'agentGetClearSeq':
      return {'clearSeq': 0};
    case 'agentGetMessagesAfterSeq':
      return {'messages': []};
    case 'agentGetSessionSummary':
      return {};
    case 'agentGetActiveSpecs':
      return {'specs': []};
    case 'agentGetCompletedSpecs':
      return {'specs': []};
    case 'agentGetCurrentTopics':
      return {'topics': []};
    case 'agentGetPendingTopics':
      return {'topics': []};
    case 'agentGetCompletedTopics':
      return {'topics': []};
    case 'agentGetTaskItemsByTopic':
      return {'taskItems': []};
    default:
      return {};
  }
}

// ===== 测试 Fixture =====

class TestFixture {
  late final StreamController<AgentEvent> remoteEventController;
  late final MockMessageStoreService messageStore;
  late MockRpcHandler rpcHandler;
  late AgentProxy proxy;
  late CachedAgentProxy cachedProxy;

  final String employeeId = 'emp-test-001';
  final String deviceId = 'device-client-001';

  TestFixture() {
    rpcHandler = _defaultMockRpc;
  }

  /// 创建并初始化测试环境
  Future<void> setUp() async {
    remoteEventController = StreamController<AgentEvent>.broadcast();
    messageStore = MockMessageStoreService();

    proxy = AgentProxy.remote(
      employeeId: employeeId,
      deviceId: 'device-server-001',
      rpcCall: (method, params) => rpcHandler(method, params),
      remoteEventStream: remoteEventController.stream,
    );

    cachedProxy = CachedAgentProxy(
      proxy: proxy,
      messageStore: messageStore,
      deviceId: deviceId,
      employeeId: employeeId,
      markReadQueueStore: _NoopMarkReadQueueStore(),
    );

    await cachedProxy.initialize();
  }

  /// 清理测试环境
  Future<void> tearDown() async {
    await cachedProxy.dispose();
    await proxy.dispose();
    await remoteEventController.close();
  }

  /// 发送远程事件（模拟 LAN 广播）
  void sendRemoteEvent(AgentEvent event) {
    remoteEventController.add(event);
  }

  /// 发送状态变更事件
  void sendAgentStatusChanged({
    required String status,
    String? currentProcessingMessageId,
    List<String>? queuedMessageIds,
  }) {
    final data = <String, dynamic>{'status': status};
    if (currentProcessingMessageId != null) {
      data['currentProcessingMessageId'] = currentProcessingMessageId;
    }
    if (queuedMessageIds != null) {
      data['queuedMessageIds'] = queuedMessageIds;
    }
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.agentStatusChanged,
      data: data,
      employeeId: employeeId,
    ));
  }

  /// 发送消息状态变更事件
  void sendMessageStatusChanged({
    required String messageId,
    required String status,
    String? error,
  }) {
    final data = <String, dynamic>{
      'messageId': messageId,
      'status': status,
    };
    if (error != null) data['error'] = error;
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.messageStatusChanged,
      data: data,
      employeeId: employeeId,
    ));
  }

  /// 发送消息开始处理事件
  void sendMessageStarted({required String messageId}) {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.messageStarted,
      data: {'messageId': messageId},
      employeeId: employeeId,
    ));
  }

  /// 发送工具调用开始事件
  void sendToolCallStart({
    required String toolCallId,
    required String toolName,
    Map<String, dynamic>? arguments,
  }) {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.toolCallStart,
      data: {
        'toolCallId': toolCallId,
        'toolName': toolName,
        if (arguments != null) 'arguments': arguments,
      },
      employeeId: employeeId,
    ));
  }

  /// 发送工具调用结果事件
  void sendToolCallResult({
    required String toolCallId,
    String? result,
    bool isError = false,
  }) {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.toolCallResult,
      data: {
        'toolCallId': toolCallId,
        if (result != null) 'result': result,
        'isError': isError,
      },
      employeeId: employeeId,
    ));
  }

  /// 发送权限请求事件
  void sendPermissionRequest(AgentPermissionRequest request) {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.toolPermissionRequest,
      data: request.toMap(),
      employeeId: employeeId,
    ));
  }

  /// 发送权限响应事件
  void sendPermissionResponse({
    required String requestId,
    String? decision,
    String? scope,
  }) {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.toolPermissionResponse,
      data: {
        'requestId': requestId,
        if (decision != null) 'decision': decision,
        if (scope != null) 'scope': scope,
      },
      employeeId: employeeId,
    ));
  }

  /// 发送确认请求事件
  void sendConfirmRequest(AgentConfirmRequest request) {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.confirmRequest,
      data: request.toMap(),
      employeeId: employeeId,
    ));
  }

  /// 发送确认响应事件
  void sendConfirmResponse({required String requestId}) {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.confirmResponse,
      data: {'requestId': requestId},
      employeeId: employeeId,
    ));
  }

  /// 发送会话清空事件
  void sendSessionCleared() {
    sendRemoteEvent(AgentEvent(
      type: AgentEventType.sessionCleared,
      data: {},
      employeeId: employeeId,
    ));
  }

  /// 等待事件处理完成（让 microtask 和 Timer 执行）
  Future<void> flush() async {
    await Future.delayed(const Duration(milliseconds: 50));
  }

  /// 等待去抖定时器触发（500ms）
  Future<void> flushDebounce() async {
    await Future.delayed(const Duration(milliseconds: 600));
  }
}

/// 空操作 MarkReadQueueStore（避免依赖 SQLite）
class _NoopMarkReadQueueStore extends MarkReadQueueStore {
  _NoopMarkReadQueueStore() : super(deviceId: '');

  @override
  void enqueue({
    required String employeeId,
    required String readerDeviceId,
    List<String>? messageIds,
  }) {}

  @override
  List<MarkReadQueueEntry> getPending({String? employeeId}) => [];

  @override
  void removeAll(List<int> ids) {}

  @override
  void clear({String? employeeId}) {}
}

// ===== 测试主体 =====

void main() {
  group('会话窗口状态同步测试', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    // ============================================================
    // 1. Event 路径 - 聊天状态同步
    // ============================================================

    group('Event路径 - 聊天状态同步', () {
      test('agentStatusChanged(processing) 更新 currentProcessingMessageId', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-001',
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-001'));
      });

      test('agentStatusChanged(processing) 含 queuedMessageIds', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-001',
          queuedMessageIds: ['msg-002', 'msg-003'],
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-001'));
        expect(fixture.cachedProxy.queuedMessageIds, equals(['msg-002', 'msg-003']));
      });

      test('agentStatusChanged(streaming) 保留 currentProcessingMessageId', () async {
        // 先进入 processing
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-001',
        );
        await fixture.flush();
        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-001'));

        // 再变为 streaming，必须携带 currentProcessingMessageId
        // 因为 _RemoteOps 会创建新的 AgentStateSnapshot 并通过 _stateController 广播
        // _handleStateChange 会用 snapshot 的值覆盖缓存
        fixture.sendAgentStatusChanged(
          status: 'streaming',
          currentProcessingMessageId: 'msg-001',
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-001'));
      });

      test('agentStatusChanged(waitingPermission) 保留 currentProcessingMessageId', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-001',
        );
        await fixture.flush();

        // waitingPermission 必须携带 currentProcessingMessageId
        // 因为 _handleStateChange 会用 snapshot 的值覆盖缓存
        fixture.sendAgentStatusChanged(
          status: 'waitingPermission',
          currentProcessingMessageId: 'msg-001',
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-001'));
      });

      test('agentStatusChanged(idle) 清除 currentProcessingMessageId 和 queuedMessageIds', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-001',
          queuedMessageIds: ['msg-002'],
        );
        await fixture.flush();
        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-001'));
        expect(fixture.cachedProxy.queuedMessageIds, equals(['msg-002']));

        fixture.sendAgentStatusChanged(status: 'idle');
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);
      });

      test('messageStarted 事件更新 currentProcessingMessageId', () async {
        fixture.sendMessageStarted(messageId: 'msg-started-001');
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-started-001'));
      });

      test('messageStatusChanged(completed) 清除 callingToolIdsCache', () async {
        // 先添加工具调用
        fixture.sendToolCallStart(toolCallId: 'call-001', toolName: 'read_file');
        await fixture.flush();
        expect(fixture.cachedProxy.callingToolIds, contains('call-001'));

        // 消息完成
        fixture.sendMessageStatusChanged(messageId: 'msg-001', status: 'completed');
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('messageStatusChanged(failed) 清除 callingToolIdsCache', () async {
        fixture.sendToolCallStart(toolCallId: 'call-002', toolName: 'execute_command');
        await fixture.flush();
        expect(fixture.cachedProxy.callingToolIds, contains('call-002'));

        fixture.sendMessageStatusChanged(messageId: 'msg-002', status: 'failed', error: 'timeout');
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('messageStatusChanged(interrupted) 清除 callingToolIdsCache', () async {
        fixture.sendToolCallStart(toolCallId: 'call-003', toolName: 'write_file');
        await fixture.flush();

        fixture.sendMessageStatusChanged(messageId: 'msg-003', status: 'interrupted');
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('不同 employeeId 的事件被过滤', () async {
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.agentStatusChanged,
          data: {
            'status': 'processing',
            'currentProcessingMessageId': 'msg-other',
          },
          employeeId: 'emp-other-001',
        ));
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
      });
    });

    // ============================================================
    // 2. Event 路径 - 权限申请同步
    // ============================================================

    group('Event路径 - 权限申请同步', () {
      test('toolPermissionRequest 事件新增权限请求到缓存', () async {
        final request = AgentPermissionRequest(
          requestId: 'perm-001',
          type: 'file_write',
          description: '写入文件 /tmp/test.txt',
          functionName: 'write_file',
          permissionArgKey: 'path',
          permissionArgValue: '/tmp/test.txt',
        );

        fixture.sendPermissionRequest(request);
        await fixture.flush();

        final cached = fixture.cachedProxy.getPendingPermissionRequest();
        expect(cached, isNotNull);
        expect(cached!.requestId, equals('perm-001'));
        expect(cached.type, equals('file_write'));
        expect(cached.functionName, equals('write_file'));
      });

      test('toolPermissionResponse 事件从缓存移除权限请求', () async {
        final request = AgentPermissionRequest(
          requestId: 'perm-002',
          type: 'command_execute',
          description: '执行命令 ls',
          functionName: 'execute_command',
        );

        fixture.sendPermissionRequest(request);
        await fixture.flush();
        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNotNull);

        fixture.sendPermissionResponse(
          requestId: 'perm-002',
          decision: 'allow',
          scope: 'once',
        );
        await fixture.flush();

        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNull);
      });

      test('多个权限请求独立管理', () async {
        final req1 = AgentPermissionRequest(
          requestId: 'perm-multi-001',
          type: 'file_write',
          description: '写文件A',
          functionName: 'write_file',
        );
        final req2 = AgentPermissionRequest(
          requestId: 'perm-multi-002',
          type: 'command_execute',
          description: '执行命令',
          functionName: 'execute_command',
        );

        fixture.sendPermissionRequest(req1);
        await fixture.flush();
        fixture.sendPermissionRequest(req2);
        await fixture.flush();

        // 第一个请求应该是第一个被缓存的
        var cached = fixture.cachedProxy.getPendingPermissionRequest();
        expect(cached, isNotNull);

        // 响应第一个
        fixture.sendPermissionResponse(requestId: 'perm-multi-001', decision: 'deny');
        await fixture.flush();

        // 第二个仍在缓存中
        cached = fixture.cachedProxy.getPendingPermissionRequest();
        expect(cached, isNotNull);
        expect(cached!.requestId, equals('perm-multi-002'));
      });

      test('respondToPermission 清除缓存', () async {
        final request = AgentPermissionRequest(
          requestId: 'perm-respond-001',
          type: 'file_read',
          description: '读取文件',
          functionName: 'read_file',
        );

        fixture.sendPermissionRequest(request);
        await fixture.flush();
        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNotNull);

        await fixture.cachedProxy.respondToPermission(
          'perm-respond-001',
          PermissionDecision.allow,
        );

        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNull);
      });
    });

    // ============================================================
    // 3. Event 路径 - Confirm 请求同步
    // ============================================================

    group('Event路径 - Confirm请求同步', () {
      test('confirmRequest 事件新增确认请求到缓存', () async {
        final request = AgentConfirmRequest(
          requestId: 'confirm-001',
          title: '请选择部署方案',
          message: '请选择部署方式',
          options: [
            const ConfirmOption(key: 'plan_a', label: '方案A：Docker'),
            const ConfirmOption(key: 'plan_b', label: '方案B：本地部署'),
          ],
          defaultOption: 'plan_a',
        );

        fixture.sendConfirmRequest(request);
        await fixture.flush();

        final cached = fixture.cachedProxy.getPendingConfirmRequest();
        expect(cached, isNotNull);
        expect(cached!.requestId, equals('confirm-001'));
        expect(cached.title, equals('请选择部署方案'));
        expect(cached.options, hasLength(2));
        expect(cached.defaultOption, equals('plan_a'));
      });

      test('confirmResponse 事件从缓存移除确认请求', () async {
        final request = AgentConfirmRequest(
          requestId: 'confirm-002',
          title: '确认删除',
          message: '是否确认删除此文件？',
          options: [
            const ConfirmOption(key: 'yes', label: '确认'),
            const ConfirmOption(key: 'no', label: '取消'),
          ],
        );

        fixture.sendConfirmRequest(request);
        await fixture.flush();
        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNotNull);

        fixture.sendConfirmResponse(requestId: 'confirm-002');
        await fixture.flush();

        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNull);
      });

      test('respondToConfirm 清除缓存', () async {
        final request = AgentConfirmRequest(
          requestId: 'confirm-respond-001',
          title: '确认操作',
          message: '是否继续？',
          options: [
            const ConfirmOption(key: 'ok', label: '继续'),
            const ConfirmOption(key: 'cancel', label: '取消'),
          ],
        );

        fixture.sendConfirmRequest(request);
        await fixture.flush();
        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNotNull);

        await fixture.cachedProxy.respondToConfirm('confirm-respond-001', 'ok');

        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNull);
      });

      test('多个 Confirm 请求独立管理', () async {
        final req1 = AgentConfirmRequest(
          requestId: 'confirm-multi-001',
          title: '选择A',
          message: '选择A方案',
          options: [
            const ConfirmOption(key: 'a', label: 'A'),
            const ConfirmOption(key: 'b', label: 'B'),
          ],
        );
        final req2 = AgentConfirmRequest(
          requestId: 'confirm-multi-002',
          title: '选择B',
          message: '选择B方案',
          options: [
            const ConfirmOption(key: 'c', label: 'C'),
            const ConfirmOption(key: 'd', label: 'D'),
          ],
        );

        fixture.sendConfirmRequest(req1);
        await fixture.flush();
        fixture.sendConfirmRequest(req2);
        await fixture.flush();

        // 响应第一个
        fixture.sendConfirmResponse(requestId: 'confirm-multi-001');
        await fixture.flush();

        final cached = fixture.cachedProxy.getPendingConfirmRequest();
        expect(cached, isNotNull);
        expect(cached!.requestId, equals('confirm-multi-002'));
      });
    });

    // ============================================================
    // 4. Event 路径 - 工具调用 ID 同步
    // ============================================================

    group('Event路径 - 工具调用ID同步', () {
      test('toolCallStart 事件添加 toolCallId 到缓存', () async {
        fixture.sendToolCallStart(
          toolCallId: 'call-tool-001',
          toolName: 'read_file',
          arguments: {'path': '/tmp/test.txt'},
        );
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, contains('call-tool-001'));
      });

      test('多个 toolCallStart 事件累加 toolCallId', () async {
        fixture.sendToolCallStart(toolCallId: 'call-multi-001', toolName: 'read_file');
        await fixture.flush();
        fixture.sendToolCallStart(toolCallId: 'call-multi-002', toolName: 'write_file');
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, containsAll(['call-multi-001', 'call-multi-002']));
        expect(fixture.cachedProxy.callingToolIds, hasLength(2));
      });

      test('toolCallResult 事件从缓存移除 toolCallId', () async {
        fixture.sendToolCallStart(toolCallId: 'call-result-001', toolName: 'read_file');
        await fixture.flush();
        expect(fixture.cachedProxy.callingToolIds, contains('call-result-001'));

        fixture.sendToolCallResult(
          toolCallId: 'call-result-001',
          result: 'File contents here',
        );
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, isNot(contains('call-result-001')));
      });

      test('toolCallResult 后剩余的 toolCallId 仍保留', () async {
        fixture.sendToolCallStart(toolCallId: 'call-remain-001', toolName: 'read_file');
        await fixture.flush();
        fixture.sendToolCallStart(toolCallId: 'call-remain-002', toolName: 'write_file');
        await fixture.flush();

        fixture.sendToolCallResult(toolCallId: 'call-remain-001', result: 'ok');
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, isNot(contains('call-remain-001')));
        expect(fixture.cachedProxy.callingToolIds, contains('call-remain-002'));
      });
    });

    // ============================================================
    // 5. Event 路径 - 队列消息 ID 同步
    // ============================================================

    group('Event路径 - 队列消息ID同步', () {
      test('agentStatusChanged 含 queuedMessageIds 更新缓存', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-current',
          queuedMessageIds: ['msg-q1', 'msg-q2', 'msg-q3'],
        );
        await fixture.flush();

        expect(fixture.cachedProxy.queuedMessageIds,
            equals(['msg-q1', 'msg-q2', 'msg-q3']));
      });

      test('idle 状态清空 queuedMessageIds', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          queuedMessageIds: ['msg-q1'],
        );
        await fixture.flush();
        expect(fixture.cachedProxy.queuedMessageIds, equals(['msg-q1']));

        fixture.sendAgentStatusChanged(status: 'idle');
        await fixture.flush();

        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);
      });

      test('连续状态变更正确更新 queuedMessageIds', () async {
        // 第一次：3个排队
        fixture.sendAgentStatusChanged(
          status: 'processing',
          queuedMessageIds: ['msg-q1', 'msg-q2', 'msg-q3'],
        );
        await fixture.flush();
        expect(fixture.cachedProxy.queuedMessageIds, hasLength(3));

        // 第二次：1个排队（其他已处理）
        fixture.sendAgentStatusChanged(
          status: 'processing',
          queuedMessageIds: ['msg-q3'],
        );
        await fixture.flush();
        expect(fixture.cachedProxy.queuedMessageIds, equals(['msg-q3']));
      });
    });

    // ============================================================
    // 6. Query 路径 - syncFromRemote 拉取状态
    // ============================================================

    group('Query路径 - syncFromRemote 拉取状态快照', () {
      test('getStateSnapshotAsync RPC 返回的状态快照正确', () async {
        // 创建带自定义 rpcHandler 的 fixture
        final customFixture = TestFixture();
        customFixture.rpcHandler = (method, params) async {
          if (method == 'agentGetState') {
            return AgentStateSnapshot(
              status: AgentStatus.processing,
              currentProcessingMessageId: 'msg-rpc-001',
              queuedMessageIds: ['msg-rpc-002'],
            ).toMap();
          }
          return _defaultMockRpc(method, params);
        };
        await customFixture.setUp();

        try {
          // 直接调用 getStateSnapshotAsync 验证 RPC 返回值
          final snapshot = await customFixture.proxy.getStateSnapshotAsync();
          expect(snapshot.status, equals(AgentStatus.processing));
          expect(snapshot.currentProcessingMessageId, equals('msg-rpc-001'));
          expect(snapshot.queuedMessageIds, equals(['msg-rpc-002']));
        } finally {
          await customFixture.tearDown();
        }
      });

      test('getPendingPermissionRequestAsync RPC 缓存权限请求', () async {
        final permissionRequest = AgentPermissionRequest(
          requestId: 'perm-rpc-001',
          type: 'file_write',
          description: 'RPC写入文件',
          functionName: 'write_file',
        );

        final customFixture = TestFixture();
        customFixture.rpcHandler = (method, params) async {
          if (method == 'agentGetPendingPermission') {
            return {'request': permissionRequest.toMap()};
          }
          return _defaultMockRpc(method, params);
        };
        await customFixture.setUp();

        try {
          // 手动触发 _queryPendingPermission（通过 waitingPermission 状态变更）
          customFixture.sendAgentStatusChanged(status: 'waitingPermission');
          await customFixture.flush();

          // 等待 RPC 查询完成
          await Future.delayed(const Duration(milliseconds: 200));

          final cached = customFixture.cachedProxy.getPendingPermissionRequest();
          expect(cached, isNotNull);
          expect(cached!.requestId, equals('perm-rpc-001'));
        } finally {
          await customFixture.tearDown();
        }
      });

      test('getPendingConfirmRequestAsync RPC 缓存确认请求', () async {
        final confirmRequest = AgentConfirmRequest(
          requestId: 'confirm-rpc-001',
          title: 'RPC确认',
          message: '请确认操作',
          options: [
            const ConfirmOption(key: 'yes', label: '是'),
            const ConfirmOption(key: 'no', label: '否'),
          ],
        );

        final customFixture = TestFixture();
        customFixture.rpcHandler = (method, params) async {
          if (method == 'agentGetPendingConfirm') {
            return {'request': confirmRequest.toMap()};
          }
          return _defaultMockRpc(method, params);
        };
        await customFixture.setUp();

        try {
          customFixture.sendAgentStatusChanged(status: 'waitingPermission');
          await customFixture.flush();

          await Future.delayed(const Duration(milliseconds: 200));

          final cached = customFixture.cachedProxy.getPendingConfirmRequest();
          expect(cached, isNotNull);
          expect(cached!.requestId, equals('confirm-rpc-001'));
        } finally {
          await customFixture.tearDown();
        }
      });

      test('syncFromRemote 无异常时正常完成', () async {
        // 使用默认 mock（所有 RPC 返回空数据）
        await fixture.cachedProxy.syncFromRemote();

        // 不应抛出异常
        expect(fixture.cachedProxy.isDisposed, isFalse);
      });
    });

    // ============================================================
    // 7. updateRemoteStateCache 直接更新
    // ============================================================

    group('updateRemoteStateCache 直接更新', () {
      test('设置 currentProcessingMessageId', () {
        fixture.cachedProxy.updateRemoteStateCache(
          currentProcessingMessageId: 'msg-direct-001',
        );
        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-direct-001'));
      });

      test('清除 currentProcessingMessageId (clearProcessing)', () {
        fixture.cachedProxy.updateRemoteStateCache(
          currentProcessingMessageId: 'msg-direct-001',
        );
        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-direct-001'));

        fixture.cachedProxy.updateRemoteStateCache(clearProcessing: true);
        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
      });

      test('设置 queuedMessageIds', () {
        fixture.cachedProxy.updateRemoteStateCache(
          queuedMessageIds: ['msg-q-direct-1', 'msg-q-direct-2'],
        );
        expect(fixture.cachedProxy.queuedMessageIds,
            equals(['msg-q-direct-1', 'msg-q-direct-2']));
      });

      test('清除 queuedMessageIds (clearQueued)', () {
        fixture.cachedProxy.updateRemoteStateCache(
          queuedMessageIds: ['msg-q-direct-1'],
        );
        fixture.cachedProxy.updateRemoteStateCache(clearQueued: true);
        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);
      });

      test('设置 callingToolIds', () {
        fixture.cachedProxy.updateRemoteStateCache(
          callingToolIds: ['call-direct-1', 'call-direct-2'],
        );
        expect(fixture.cachedProxy.callingToolIds,
            equals(['call-direct-1', 'call-direct-2']));
      });

      test('清除 callingToolIds (clearCallingToolIds)', () {
        fixture.cachedProxy.updateRemoteStateCache(
          callingToolIds: ['call-direct-1'],
        );
        fixture.cachedProxy.updateRemoteStateCache(clearCallingToolIds: true);
        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('addRemoteCallingToolId 去重添加', () {
        fixture.cachedProxy.updateRemoteStateCache(
          callingToolIds: ['call-add-1'],
        );
        fixture.cachedProxy.addRemoteCallingToolId('call-add-1'); // 已存在
        expect(fixture.cachedProxy.callingToolIds, equals(['call-add-1']));

        fixture.cachedProxy.addRemoteCallingToolId('call-add-2'); // 新增
        expect(fixture.cachedProxy.callingToolIds,
            equals(['call-add-1', 'call-add-2']));
      });

      test('removeRemoteCallingToolId 精确移除', () {
        fixture.cachedProxy.updateRemoteStateCache(
          callingToolIds: ['call-rm-1', 'call-rm-2', 'call-rm-3'],
        );
        fixture.cachedProxy.removeRemoteCallingToolId('call-rm-2');
        expect(fixture.cachedProxy.callingToolIds,
            equals(['call-rm-1', 'call-rm-3']));
      });
    });

    // ============================================================
    // 8. 会话清空保护
    // ============================================================

    group('会话清空保护', () {
      test('sessionCleared 事件设置保护标志，跳过去抖同步', () async {
        // 先进入 processing
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-before-clear',
        );
        await fixture.flush();

        // 触发会话清空
        fixture.sendSessionCleared();
        await fixture.flush();

        // 保护期内 idle 状态不应触发同步
        fixture.sendAgentStatusChanged(status: 'idle');
        await fixture.flush();

        // currentProcessingMessageId 应被 idle 清空
        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
      });

      test('sessionCleared 事件清除权限和确认缓存', () async {
        // 先添加权限和确认请求
        fixture.sendPermissionRequest(AgentPermissionRequest(
          requestId: 'perm-clear-001',
          type: 'file_write',
          description: '写入',
          functionName: 'write_file',
        ));
        await fixture.flush();

        fixture.sendConfirmRequest(AgentConfirmRequest(
          requestId: 'confirm-clear-001',
          title: '确认',
          message: '确认操作',
          options: [
            const ConfirmOption(key: 'a', label: 'A'),
            const ConfirmOption(key: 'b', label: 'B'),
          ],
        ));
        await fixture.flush();

        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNotNull);
        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNotNull);

        // 触发会话清空
        fixture.sendSessionCleared();
        await fixture.flush();

        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNull);
        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNull);
      });

      test('保护期过后恢复正常同步', () async {
        fixture.sendSessionCleared();
        await fixture.flush();

        // 等待保护期结束（2秒）
        await Future.delayed(const Duration(seconds: 3));

        // 保护期结束后，状态变更应正常处理
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-after-guard',
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-after-guard'));
      });
    });

    // ============================================================
    // 9. AgentStateSnapshot 序列化
    // ============================================================

    group('AgentStateSnapshot 序列化', () {
      test('toMap/fromMap 往返一致', () {
        final snapshot = AgentStateSnapshot(
          status: AgentStatus.processing,
          currentProcessingMessageId: 'msg-snap-001',
          queuedMessageIds: ['msg-q1', 'msg-q2'],
          isStreaming: true,
          queueLength: 2,
        );

        final map = snapshot.toMap();
        final restored = AgentStateSnapshot.fromMap(map);

        expect(restored.status, equals(AgentStatus.processing));
        expect(restored.currentProcessingMessageId, equals('msg-snap-001'));
        expect(restored.queuedMessageIds, equals(['msg-q1', 'msg-q2']));
        expect(restored.isStreaming, isTrue);
        expect(restored.queueLength, equals(2));
      });

      test('idle() 工厂方法创建空闲快照', () {
        final snapshot = AgentStateSnapshot.idle();

        expect(snapshot.status, equals(AgentStatus.idle));
        expect(snapshot.currentProcessingMessageId, isNull);
        expect(snapshot.queuedMessageIds, isEmpty);
        expect(snapshot.isStreaming, isFalse);
        expect(snapshot.queueLength, equals(0));
      });

      test('fromMap 处理缺失字段', () {
        final restored = AgentStateSnapshot.fromMap({});

        expect(restored.status, equals(AgentStatus.idle));
        expect(restored.currentProcessingMessageId, isNull);
        expect(restored.queuedMessageIds, isEmpty);
        expect(restored.isStreaming, isFalse);
        expect(restored.queueLength, equals(0));
      });
    });

    // ============================================================
    // 10. AgentPermissionRequest 序列化
    // ============================================================

    group('AgentPermissionRequest 序列化', () {
      test('toMap/fromMap 往返一致', () {
        final request = AgentPermissionRequest(
          requestId: 'req-serial-001',
          type: 'command_execute',
          description: '执行命令',
          functionName: 'execute_command',
          permissionPattern: 'rm *',
          permissionType: 'dangerous',
          data: {'command': 'rm -rf /tmp'},
          permissionArgKey: 'command',
          permissionArgValue: 'rm -rf /tmp',
          suggestedPattern: 'rm /tmp/*',
        );

        final map = request.toMap();
        final restored = AgentPermissionRequest.fromMap(map);

        expect(restored.requestId, equals('req-serial-001'));
        expect(restored.type, equals('command_execute'));
        expect(restored.description, equals('执行命令'));
        expect(restored.functionName, equals('execute_command'));
        expect(restored.permissionPattern, equals('rm *'));
        expect(restored.permissionType, equals('dangerous'));
        expect(restored.data, equals({'command': 'rm -rf /tmp'}));
        expect(restored.permissionArgKey, equals('command'));
        expect(restored.permissionArgValue, equals('rm -rf /tmp'));
        expect(restored.suggestedPattern, equals('rm /tmp/*'));
      });

      test('fromMap 处理 null 可选字段', () {
        final map = <String, dynamic>{
          'requestId': 'req-null-001',
          'type': 'file_read',
          'description': '读取文件',
          'functionName': 'read_file',
        };

        final restored = AgentPermissionRequest.fromMap(map);
        expect(restored.requestId, equals('req-null-001'));
        expect(restored.permissionPattern, isNull);
        expect(restored.permissionType, isNull);
        expect(restored.data, isNull);
        expect(restored.permissionArgKey, isNull);
        expect(restored.permissionArgValue, isNull);
        expect(restored.suggestedPattern, isNull);
      });
    });

    // ============================================================
    // 11. AgentConfirmRequest 序列化
    // ============================================================

    group('AgentConfirmRequest 序列化', () {
      test('toMap/fromMap 往返一致', () {
        final request = AgentConfirmRequest(
          requestId: 'confirm-serial-001',
          title: '选择部署方案',
          message: '请选择部署方式',
          options: [
            const ConfirmOption(key: 'docker', label: 'Docker部署', description: '使用Docker容器化部署'),
            const ConfirmOption(key: 'local', label: '本地部署', description: '直接在本机部署'),
          ],
          defaultOption: 'docker',
          data: {'environment': 'production'},
        );

        final map = request.toMap();
        final restored = AgentConfirmRequest.fromMap(map);

        expect(restored.requestId, equals('confirm-serial-001'));
        expect(restored.title, equals('选择部署方案'));
        expect(restored.message, equals('请选择部署方式'));
        expect(restored.options, hasLength(2));
        expect(restored.options[0].key, equals('docker'));
        expect(restored.options[0].label, equals('Docker部署'));
        expect(restored.options[0].description, equals('使用Docker容器化部署'));
        expect(restored.defaultOption, equals('docker'));
        expect(restored.data, equals({'environment': 'production'}));
      });

      test('fromMap 处理无 defaultOption 和 data', () {
        final map = <String, dynamic>{
          'requestId': 'confirm-min-001',
          'title': '确认',
          'message': '是否继续？',
          'options': [
            {'key': 'yes', 'label': '是'},
            {'key': 'no', 'label': '否'},
          ],
        };

        final restored = AgentConfirmRequest.fromMap(map);
        expect(restored.requestId, equals('confirm-min-001'));
        expect(restored.defaultOption, isNull);
        expect(restored.data, isNull);
        expect(restored.options, hasLength(2));
      });
    });

    // ============================================================
    // 12. AgentStatus 枚举
    // ============================================================

    group('AgentStatus 枚举', () {
      test('fromString 正确解析所有状态', () {
        expect(AgentStatus.fromString('idle'), equals(AgentStatus.idle));
        expect(AgentStatus.fromString('processing'), equals(AgentStatus.processing));
        expect(AgentStatus.fromString('streaming'), equals(AgentStatus.streaming));
        expect(AgentStatus.fromString('waitingPermission'), equals(AgentStatus.waitingPermission));
        expect(AgentStatus.fromString('disposed'), equals(AgentStatus.disposed));
      });

      test('fromString 未知值默认 idle', () {
        expect(AgentStatus.fromString('unknown'), equals(AgentStatus.idle));
        expect(AgentStatus.fromString(''), equals(AgentStatus.idle));
      });
    });

    // ============================================================
    // 13. AgentEvent 过滤与路由
    // ============================================================

    group('AgentEvent 过滤与路由', () {
      test('streamDelta 事件不影响缓存状态', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-before-delta',
        );
        await fixture.flush();

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.streamDelta,
          data: {'content': 'Hello world'},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        // 缓存状态不变
        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-before-delta'));
      });

      test('thinkingDelta 事件不影响缓存状态', () async {
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.thinkingDelta,
          data: {'content': '思考中...'},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
      });

      test('unknown 事件被忽略', () async {
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.unknown,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
      });
    });

    // ============================================================
    // 14. 综合场景 - 完整消息处理生命周期
    // ============================================================

    group('综合场景 - 完整消息处理生命周期', () {
      test('用户发送消息 → 处理中 → 工具调用 → 完成', () async {
        // 1. Agent 开始处理
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-lifecycle-001',
          queuedMessageIds: [],
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-lifecycle-001'));
        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);

        // 2. Agent 开始流式输出
        fixture.sendAgentStatusChanged(status: 'streaming');
        await fixture.flush();

        // 3. Agent 调用工具
        fixture.sendToolCallStart(toolCallId: 'call-lifecycle-001', toolName: 'read_file');
        await fixture.flush();
        expect(fixture.cachedProxy.callingToolIds, contains('call-lifecycle-001'));

        // 4. 工具返回结果
        fixture.sendToolCallResult(toolCallId: 'call-lifecycle-001', result: 'file content');
        await fixture.flush();
        expect(fixture.cachedProxy.callingToolIds, isNot(contains('call-lifecycle-001')));

        // 5. 又调用一个工具
        fixture.sendToolCallStart(toolCallId: 'call-lifecycle-002', toolName: 'write_file');
        await fixture.flush();
        fixture.sendToolCallResult(toolCallId: 'call-lifecycle-002', result: 'ok');
        await fixture.flush();

        // 6. 消息处理完成
        fixture.sendMessageStatusChanged(messageId: 'msg-lifecycle-001', status: 'completed');
        await fixture.flush();

        // 完成后 callingToolIds 被清空
        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('多消息排队 → 逐个处理 → 全部完成', () async {
        // 1. 3条消息排队
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-queue-001',
          queuedMessageIds: ['msg-queue-002', 'msg-queue-003'],
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-queue-001'));
        expect(fixture.cachedProxy.queuedMessageIds,
            equals(['msg-queue-002', 'msg-queue-003']));

        // 2. 第一条完成，开始第二条
        fixture.sendMessageStatusChanged(messageId: 'msg-queue-001', status: 'completed');
        await fixture.flush();

        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-queue-002',
          queuedMessageIds: ['msg-queue-003'],
        );
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, equals('msg-queue-002'));
        expect(fixture.cachedProxy.queuedMessageIds, equals(['msg-queue-003']));

        // 3. 第二条完成，开始第三条
        fixture.sendMessageStatusChanged(messageId: 'msg-queue-002', status: 'completed');
        await fixture.flush();

        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-queue-003',
          queuedMessageIds: [],
        );
        await fixture.flush();

        // 4. 全部完成，回到 idle
        fixture.sendMessageStatusChanged(messageId: 'msg-queue-003', status: 'completed');
        await fixture.flush();

        fixture.sendAgentStatusChanged(status: 'idle');
        await fixture.flush();

        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);
        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('处理中遇到权限请求 → 授权 → 继续 → 完成', () async {
        // 1. 开始处理
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-perm-flow-001',
        );
        await fixture.flush();

        // 2. 工具调用需要权限
        fixture.sendToolCallStart(toolCallId: 'call-perm-001', toolName: 'execute_command');
        await fixture.flush();
        expect(fixture.cachedProxy.callingToolIds, contains('call-perm-001'));

        // 3. Agent 等待权限
        fixture.sendAgentStatusChanged(status: 'waitingPermission');
        await fixture.flush();

        // 4. 权限请求到达
        final permRequest = AgentPermissionRequest(
          requestId: 'perm-flow-001',
          type: 'command_execute',
          description: '执行命令 ls -la',
          functionName: 'execute_command',
        );
        fixture.sendPermissionRequest(permRequest);
        await fixture.flush();

        var cachedPerm = fixture.cachedProxy.getPendingPermissionRequest();
        expect(cachedPerm, isNotNull);
        expect(cachedPerm!.requestId, equals('perm-flow-001'));

        // 5. 用户授权
        await fixture.cachedProxy.respondToPermission(
          'perm-flow-001',
          PermissionDecision.allow,
        );
        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNull);

        // 6. 工具返回结果
        fixture.sendToolCallResult(toolCallId: 'call-perm-001', result: 'output...');
        await fixture.flush();

        // 7. 继续处理
        fixture.sendAgentStatusChanged(status: 'streaming');
        await fixture.flush();

        // 8. 完成
        fixture.sendMessageStatusChanged(messageId: 'msg-perm-flow-001', status: 'completed');
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('处理中遇到确认请求 → 选择 → 继续 → 完成', () async {
        // 1. 开始处理
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-confirm-flow-001',
        );
        await fixture.flush();

        // 2. Agent 等待确认
        fixture.sendAgentStatusChanged(status: 'waitingPermission');
        await fixture.flush();

        // 3. 确认请求到达
        final confirmRequest = AgentConfirmRequest(
          requestId: 'confirm-flow-001',
          title: '选择部署方案',
          message: '请选择部署方式',
          options: [
            const ConfirmOption(key: 'docker', label: 'Docker'),
            const ConfirmOption(key: 'local', label: '本地'),
          ],
        );
        fixture.sendConfirmRequest(confirmRequest);
        await fixture.flush();

        var cachedConfirm = fixture.cachedProxy.getPendingConfirmRequest();
        expect(cachedConfirm, isNotNull);
        expect(cachedConfirm!.requestId, equals('confirm-flow-001'));

        // 4. 用户选择
        await fixture.cachedProxy.respondToConfirm('confirm-flow-001', 'docker');
        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNull);

        // 5. 继续
        fixture.sendAgentStatusChanged(status: 'streaming');
        await fixture.flush();

        // 6. 完成
        fixture.sendMessageStatusChanged(messageId: 'msg-confirm-flow-001', status: 'completed');
        await fixture.flush();

        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });
    });

    // ============================================================
    // 15. dispose 清理
    // ============================================================

    group('资源清理', () {
      test('dispose 后所有缓存被清空', () async {
        fixture.sendAgentStatusChanged(
          status: 'processing',
          currentProcessingMessageId: 'msg-dispose-001',
          queuedMessageIds: ['msg-q'],
        );
        fixture.sendToolCallStart(toolCallId: 'call-dispose-001', toolName: 'test');
        fixture.sendPermissionRequest(AgentPermissionRequest(
          requestId: 'perm-dispose-001',
          type: 'file_write',
          description: 'test',
          functionName: 'write_file',
        ));
        fixture.sendConfirmRequest(AgentConfirmRequest(
          requestId: 'confirm-dispose-001',
          title: 'test',
          message: 'test',
          options: [
            const ConfirmOption(key: 'a', label: 'A'),
            const ConfirmOption(key: 'b', label: 'B'),
          ],
        ));
        await fixture.flush();

        await fixture.cachedProxy.dispose();

        expect(fixture.cachedProxy.isDisposed, isTrue);
        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);
        expect(fixture.cachedProxy.callingToolIds, isEmpty);
        expect(fixture.cachedProxy.getPendingPermissionRequest(), isNull);
        expect(fixture.cachedProxy.getPendingConfirmRequest(), isNull);
      });
    });
  });
}
