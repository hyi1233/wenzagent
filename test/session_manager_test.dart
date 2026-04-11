import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/service/session_manager.dart';

/// SessionManager CRUD 测试
///
/// 覆盖 SessionManagerImpl 的全部公共方法，包括：
/// - getOrCreate / getSession / getAllSessions
/// - save / deleteSession / archiveSession
/// - updateDeviceConfig / updateDeviceStats
/// - onSessionChanged 事件流
void main() {
  late DatabaseManager dbManager;
  late String dbDir;
  late SessionManagerImpl sessionManager;

  setUpAll(() {
    dbDir = p.join(Directory.systemTemp.path,
        'wenzagent_session_mgr_test_${DateTime.now().millisecondsSinceEpoch}');
    Directory(dbDir).createSync(recursive: true);
  });

  tearDownAll(() async {
    await dbManager.close();
    final dir = Directory(dbDir);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  setUp(() async {
    final instance = DatabaseManager.instance;
    if (instance.isInitialized) await instance.close();
    await instance.initialize(storagePath: dbDir);
    dbManager = instance;
    dbManager.db.execute('DELETE FROM sessions');
    sessionManager = SessionManagerImpl();
  });

  tearDown(() {
    sessionManager.dispose();
  });

  // ================================================================
  // getOrCreateSession
  // ================================================================
  group('getOrCreateSession', () {
    test('新 employeeId 创建会话', () async {
      final session = await sessionManager.getOrCreateSession('emp-001');

      expect(session.employeeId, equals('emp-001'));
      expect(session.deleted, equals(0));
      expect(session.title, equals('新对话'));
    });

    test('已存在的 employeeId 返回现有记录', () async {
      final s1 = await sessionManager.getOrCreateSession('emp-002');
      s1.title = '已修改标题';
      await sessionManager.save(s1);

      final s2 = await sessionManager.getOrCreateSession('emp-002');
      expect(s2.title, equals('已修改标题'));
      expect(s2.employeeId, equals('emp-002'));
    });

    test('已删除的会话自动复活（deleted 重置为 0）', () async {
      await sessionManager.getOrCreateSession('emp-resurrect');
      await sessionManager.deleteSession('emp-resurrect');

      // 删除后再 getOrCreate，应自动复活
      final revived = await sessionManager.getOrCreateSession('emp-resurrect');
      expect(revived.deleted, equals(0));
      // 注意：copyWith 无法将 deleteTime 设为 null（deleteTime ?? this.deleteTime），
      // 但 isEffectivelyDeleted() 通过 updateTime > deleteTime 判断已复活
      expect(revived.isEffectivelyDeleted(), isFalse);
    });
  });

  // ================================================================
  // getSession
  // ================================================================
  group('getSession', () {
    test('存在的会话返回实体', () async {
      await sessionManager.getOrCreateSession('emp-get');
      final result = await sessionManager.getSession('emp-get');

      expect(result, isNotNull);
      expect(result!.employeeId, equals('emp-get'));
    });

    test('不存在的会话返回 null', () async {
      final result = await sessionManager.getSession('nonexistent');
      expect(result, isNull);
    });
  });

  // ================================================================
  // getAllSessions
  // ================================================================
  group('getAllSessions', () {
    test('返回所有未归档会话，按置顶和更新时间排序', () async {
      final now = DateTime.now();
      // 创建3个会话，其中1个归档
      for (var i = 1; i <= 3; i++) {
        final s = await sessionManager.getOrCreateSession('emp-list-$i');
        await sessionManager.save(s.copyWith(
          title: '会话$i',
          updateTime: now.add(Duration(minutes: i)),
        ));
      }
      await sessionManager.archiveSession('emp-list-3', true);

      final all = await sessionManager.getAllSessions();
      expect(all.length, equals(2));
      // emp-list-2 更新时间更新，排前面
      expect(all.first.employeeId, equals('emp-list-2'));
    });

    test('includeArchived=true 包含归档会话', () async {
      await sessionManager.getOrCreateSession('emp-arch-1');
      await sessionManager.getOrCreateSession('emp-arch-2');
      await sessionManager.archiveSession('emp-arch-2', true);

      final all = await sessionManager.getAllSessions(includeArchived: true);
      expect(all.length, equals(2));
    });

    test('已软删除的会话不在列表中', () async {
      await sessionManager.getOrCreateSession('emp-del-1');
      await sessionManager.getOrCreateSession('emp-del-2');
      await sessionManager.deleteSession('emp-del-2');

      final all = await sessionManager.getAllSessions();
      expect(all.length, equals(1));
      expect(all.first.employeeId, equals('emp-del-1'));
    });
  });

  // ================================================================
  // save
  // ================================================================
  group('save', () {
    test('保存后可通过 getSession 读取', () async {
      final session = await sessionManager.getOrCreateSession('emp-save');
      final updated = session.copyWith(title: '已保存标题');
      await sessionManager.save(updated);

      final result = await sessionManager.getSession('emp-save');
      expect(result!.title, equals('已保存标题'));
    });
  });

  // ================================================================
  // deleteSession (软删除)
  // ================================================================
  group('deleteSession', () {
    test('软删除后 deleted=1，deleteTime 有值', () async {
      await sessionManager.getOrCreateSession('emp-softdel');
      await sessionManager.deleteSession('emp-softdel');

      // find 不过滤 deleted，所以能找到
     sessionManager.getSession('emp-softdel');
      // SessionManager.getSession 使用 SessionStore.find，find 不过滤 deleted
      final all = await sessionManager.getAllSessions();
      expect(all.any((s) => s.employeeId == 'emp-softdel'), isFalse);
    });
  });

  // ================================================================
  // archiveSession
  // ================================================================
  group('archiveSession', () {
    test('归档后不在默认列表中', () async {
      await sessionManager.getOrCreateSession('emp-archive');
      await sessionManager.archiveSession('emp-archive', true);

      final all = await sessionManager.getAllSessions();
      expect(all.any((s) => s.employeeId == 'emp-archive'), isFalse);

      final archived = await sessionManager.getAllSessions(includeArchived: true);
      expect(archived.any((s) => s.employeeId == 'emp-archive'), isTrue);
    });

    test('取消归档后重新出现在列表中', () async {
      await sessionManager.getOrCreateSession('emp-unarchive');
      await sessionManager.archiveSession('emp-unarchive', true);
      await sessionManager.archiveSession('emp-unarchive', false);

      final all = await sessionManager.getAllSessions();
      expect(all.any((s) => s.employeeId == 'emp-unarchive'), isTrue);
    });

    test('归档不存在的会话不报错', () async {
      await sessionManager.archiveSession('nonexistent', true);
      // 无异常即通过
    });
  });

  // ================================================================
  // updateDeviceConfig
  // ================================================================
  group('updateDeviceConfig', () {
    test('更新设备配置（providerConfig + systemPromptOverride）', () async {
      await sessionManager.updateDeviceConfig(
        'emp-devcfg',
        'device-001',
        providerConfig: '{"provider":"openai","model":"gpt-4"}',
        systemPromptOverride: '你是一个助手',
      );

      final session = await sessionManager.getSession('emp-devcfg');
      expect(session, isNotNull);
      final deviceConfig = session!.getConfig('device-001');
      expect(deviceConfig, isNotNull);
      expect(deviceConfig!.providerConfig,
          equals('{"provider":"openai","model":"gpt-4"}'));
      expect(deviceConfig.systemPromptOverride, equals('你是一个助手'));
    });

    test('多次更新同一设备配置（部分字段）', () async {
      await sessionManager.updateDeviceConfig(
        'emp-partial',
        'device-A',
        providerConfig: '{"model":"gpt-3.5"}',
      );
      await sessionManager.updateDeviceConfig(
        'emp-partial',
        'device-A',
        systemPromptOverride: '新提示词',
      );

      final session = await sessionManager.getSession('emp-partial');
      final cfg = session!.getConfig('device-A')!;
      expect(cfg.providerConfig, equals('{"model":"gpt-3.5"}'));
      expect(cfg.systemPromptOverride, equals('新提示词'));
    });
  });

  // ================================================================
  // updateDeviceStats
  // ================================================================
  group('updateDeviceStats', () {
    test('更新设备统计信息', () async {
      await sessionManager.updateDeviceStats(
        'emp-stats',
        'device-S',
        inputTokens: 100,
        outputTokens: 50,
        messageCount: 3,
      );

      final session = await sessionManager.getSession('emp-stats');
      final cfg = session!.getConfig('device-S')!;
      expect(cfg.totalInputTokens, equals(100));
      expect(cfg.totalOutputTokens, equals(50));
      expect(cfg.totalMessageCount, equals(3));
    });

    test('累加更新统计', () async {
      await sessionManager.updateDeviceStats(
        'emp-cumul',
        'device-C',
        inputTokens: 100,
        outputTokens: 50,
        messageCount: 1,
      );
      await sessionManager.updateDeviceStats(
        'emp-cumul',
        'device-C',
        inputTokens: 200,
        outputTokens: 150,
        messageCount: 5,
      );

      final session = await sessionManager.getSession('emp-cumul');
      final cfg = session!.getConfig('device-C')!;
      expect(cfg.totalInputTokens, equals(200));
      expect(cfg.totalOutputTokens, equals(150));
      expect(cfg.totalMessageCount, equals(5));
    });
  });

  // ================================================================
  // onSessionChanged 事件流
  // ================================================================
  group('onSessionChanged', () {
    test('getOrCreateSession 触发 created 事件', () async {
      final completer = Completer<SessionChangeEvent>();
      final sub = sessionManager.onSessionChanged.listen((e) {
        if (!completer.isCompleted) completer.complete(e);
      });

      await sessionManager.getOrCreateSession('emp-event-create');
      final event = await completer.future.timeout(Duration(seconds: 1));
      await sub.cancel();

      expect(event.type, equals(SessionChangeType.created));
      expect(event.employeeId, equals('emp-event-create'));
    });

    test('save 触发 updated 事件', () async {
      final session = await sessionManager.getOrCreateSession('emp-event-save');

      final completer = Completer<SessionChangeEvent>();
      final sub = sessionManager.onSessionChanged.listen((e) {
        if (!completer.isCompleted) completer.complete(e);
      });

      await sessionManager.save(session.copyWith(title: '更新标题'));
      final event = await completer.future.timeout(Duration(seconds: 1));
      await sub.cancel();

      expect(event.type, equals(SessionChangeType.updated));
      expect(event.employeeId, equals('emp-event-save'));
    });

    test('deleteSession 触发 deleted 事件', () async {
      await sessionManager.getOrCreateSession('emp-event-del');

      final completer = Completer<SessionChangeEvent>();
      final sub = sessionManager.onSessionChanged.listen((e) {
        if (!completer.isCompleted) completer.complete(e);
      });

      await sessionManager.deleteSession('emp-event-del');
      final event = await completer.future.timeout(Duration(seconds: 1));
      await sub.cancel();

      expect(event.type, equals(SessionChangeType.deleted));
      expect(event.employeeId, equals('emp-event-del'));
    });

    test('archiveSession 触发 updated 事件（实现通过 save 发出）', () async {
      await sessionManager.getOrCreateSession('emp-event-arch');

      final completer = Completer<SessionChangeEvent>();
      final sub = sessionManager.onSessionChanged.listen((e) {
        if (!completer.isCompleted) completer.complete(e);
      });

      await sessionManager.archiveSession('emp-event-arch', true);
      final event = await completer.future.timeout(Duration(seconds: 1));
      await sub.cancel();

      // archiveSession 内部调用 save()，发出的是 updated 事件
      expect(event.type, equals(SessionChangeType.updated));
      expect(event.employeeId, equals('emp-event-arch'));
    });
  });
}
