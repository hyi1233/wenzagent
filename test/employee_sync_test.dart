import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/employee_entity.dart';
import 'package:wenzagent/src/persistence/stores/employee_store.dart';
import 'package:wenzagent/src/service/employee_manager.dart';

/// 员工信息同步测试
///
/// 模拟 hostSyncEmployees RPC 同步逻辑（host_rpc_methods.dart 186-241行），
/// 测试各种同步场景下的数据合并正确性：
/// 1. 新员工同步（本地不存在）
/// 2. 更新时间较新的远程数据覆盖本地
/// 3. 更新时间较旧的远程数据不覆盖本地
/// 4. 删除状态合并（deleteTime 独立比较）
/// 5. 双向同步一致性
/// 6. 批量同步
///
/// 关键：同步查找 existing 时不按 deviceId 过滤（与 RPC 逻辑一致），
/// 因此验证时统一使用 EmployeeStore.find(null, uuid) 查询。
void main() {
  late DatabaseManager dbManager;
  late String dbDir;

  setUpAll(() {
    dbDir = p.join(
      Directory.systemTemp.path,
      'employee_sync_test_${DateTime.now().millisecondsSinceEpoch}',
    );
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
    dbManager.db.execute('DELETE FROM employees');
  });

  EmployeeManagerImpl createManager(String deviceId) {
    return EmployeeManagerImpl(
      store: EmployeeStore(dbManager: dbManager),
      deviceId: deviceId,
    );
  }

  EmployeeStore createStore() {
    return EmployeeStore(dbManager: dbManager);
  }

  /// 直接通过 store 查询，不按 deviceId 过滤
  Future<AiEmployeeEntity?> findEmployee(String uuid) {
    return createStore().find(null, uuid);
  }

  /// 模拟 hostSyncEmployees RPC 合并逻辑
  ///
  /// 与 host_rpc_methods.dart 186-241 行完全一致：
  /// - 查找 existing 不按 deviceId 过滤
  /// - deleteTime 独立比较
  /// - 数据按 updateTime 合并
  Future<int> simulateSyncEmployees(
    EmployeeManager localManager,
    EmployeeStore store,
    List<AiEmployeeEntity> remoteEmployees,
  ) async {
    for (final employee in remoteEmployees) {
      // 关键：使用 store.find(null, uuid) 查找，不按 deviceId 过滤
      final existing = await store.find(null, employee.uuid);
      if (existing == null) {
        await localManager.saveEmployee(employee);
      } else {
        final localDT = existing.deletedTime;
        final remoteDT = employee.deletedTime;
        DateTime? mergedDeleteTime;
        int mergedDeleted;

        if (localDT == null && remoteDT == null) {
          mergedDeleteTime = null;
          mergedDeleted = 0;
        } else if (localDT == null) {
          mergedDeleteTime = remoteDT;
          mergedDeleted = employee.deleted;
        } else if (remoteDT == null) {
          mergedDeleteTime = localDT;
          mergedDeleted = existing.deleted;
        } else {
          if (localDT.isAfter(remoteDT)) {
            mergedDeleteTime = localDT;
            mergedDeleted = existing.deleted;
          } else {
            mergedDeleteTime = remoteDT;
            mergedDeleted = employee.deleted;
          }
        }

        final shouldUpdateData =
            employee.updateTime.isAfter(existing.updateTime);
        final shouldUpdateDelete =
            mergedDeleteTime != localDT || mergedDeleted != existing.deleted;

        if (shouldUpdateData || shouldUpdateDelete) {
          final base = shouldUpdateData ? employee : existing;
          await localManager.updateEmployee(base.copyWith(
            deleted: mergedDeleted,
            deletedTime: mergedDeleteTime,
          ));
        }
      }
    }
    return remoteEmployees.length;
  }

  AiEmployeeEntity createEmployee({
    required String uuid,
    required String name,
    String? deviceId,
    String? description,
    DateTime? createTime,
    DateTime? updateTime,
    int deleted = 0,
    DateTime? deletedTime,
    String? provider,
    String? model,
  }) {
    final now = DateTime.now();
    return AiEmployeeEntity(
      uuid: uuid,
      deviceId: deviceId,
      name: name,
      description: description,
      provider: provider ?? 'openai',
      model: model ?? 'gpt-4',
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
      deleted: deleted,
      deletedTime: deletedTime,
    );
  }

  // ================================================================
  // 基础同步场景
  // ================================================================
  group('基础同步', () {
    test('新员工同步到本地（本地不存在）', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final now = DateTime.now();

      final remoteEmployee = createEmployee(
        uuid: 'emp-new',
        name: '新员工',
        deviceId: 'device-B',
        createTime: now,
        updateTime: now,
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final employee = await findEmployee('emp-new');
      expect(employee, isNotNull);
      expect(employee!.name, equals('新员工'));
      expect(employee.deviceId, equals('device-B'));
    });

    test('远程数据更新时间更新 → 覆盖本地', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final baseTime = DateTime(2026, 1, 1);

      await localManager.createEmployee(
        createEmployee(
          uuid: 'emp-update',
          name: '本地原名',
          createTime: baseTime,
          updateTime: baseTime,
        ),
      );

      final remoteEmployee = createEmployee(
        uuid: 'emp-update',
        name: '远程新名',
        description: '远程更新了描述',
        updateTime: DateTime(2026, 1, 2),
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final merged = await findEmployee('emp-update');
      expect(merged!.name, equals('远程新名'));
      expect(merged.description, equals('远程更新了描述'));
    });

    test('远程数据更新时间更旧 → 不覆盖本地', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final baseTime = DateTime(2026, 1, 1);

      await localManager.createEmployee(
        createEmployee(
          uuid: 'emp-stale',
          name: '本地新名',
          createTime: baseTime,
          updateTime: DateTime(2026, 1, 2),
        ),
      );

      final remoteEmployee = createEmployee(
        uuid: 'emp-stale',
        name: '远程旧名',
        updateTime: baseTime,
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final merged = await findEmployee('emp-stale');
      expect(merged!.name, equals('本地新名'));
    });

    test('更新时间相同 → 不覆盖本地', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final sameTime = DateTime(2026, 1, 1, 12, 0, 0);

      await localManager.createEmployee(
        createEmployee(
          uuid: 'emp-same-time',
          name: '本地名称',
          createTime: sameTime,
          updateTime: sameTime,
        ),
      );

      final remoteEmployee = createEmployee(
        uuid: 'emp-same-time',
        name: '远程名称',
        createTime: sameTime,
        updateTime: sameTime,
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final merged = await findEmployee('emp-same-time');
      expect(merged!.name, equals('本地名称'));
    });
  });

  // ================================================================
  // 删除状态合并
  // ================================================================
  group('删除状态合并', () {
    test('双方都未删除 → deleted 保持 0', () async {
      final localManager = createManager('device-A');
      final store = createStore();

      await localManager.createEmployee(
        createEmployee(uuid: 'emp-del-none', name: '员工'),
      );

      final remote = (await findEmployee('emp-del-none'))!;
      await simulateSyncEmployees(localManager, store, [remote]);

      final merged = await findEmployee('emp-del-none');
      expect(merged!.deleted, equals(0));
      expect(merged.deletedTime, isNull);
    });

    test('远程已删除，本地未删除 → 同步删除状态', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final now = DateTime.now();

      await localManager.createEmployee(
        createEmployee(uuid: 'emp-remote-del', name: '员工'),
      );

      final remoteEmployee = createEmployee(
        uuid: 'emp-remote-del',
        name: '员工',
        deleted: 1,
        deletedTime: now,
        updateTime: now,
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      // 但 findAll 过滤 deleted=0，所以需要直接查 SQL
      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-remote-del'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      expect(resultSet.first['deleted'] as int, equals(1));
    });

    test('本地已删除，远程未删除 → 保留本地删除状态', () async {
      final localManager = createManager('device-A');
      final store = createStore();

      await localManager.createEmployee(
        createEmployee(uuid: 'emp-local-del', name: '员工'),
      );
      await localManager.deleteEmployee('emp-local-del');

      final remoteEmployee = createEmployee(
        uuid: 'emp-local-del',
        name: '员工',
        deleted: 0,
        deletedTime: null,
        updateTime: DateTime.now().add(const Duration(hours: 1)),
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-local-del'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      expect(resultSet.first['deleted'] as int, equals(1));
      expect(resultSet.first['deleted_time'], isNotNull);
    });

    test('双方都已删除 → 取 deleteTime 更大的一方', () async {
      final localManager = createManager('device-A');
      final store = createStore();

      await localManager.createEmployee(
        createEmployee(uuid: 'emp-both-del', name: '员工'),
      );
      await localManager.deleteEmployee('emp-both-del');

      final localDeleted = (await store.find(null, 'emp-both-del'))!;
      final localDeleteTime = localDeleted.deletedTime!;

      final laterDeleteTime = localDeleteTime.add(const Duration(hours: 1));
      final remoteEmployee = createEmployee(
        uuid: 'emp-both-del',
        name: '员工',
        deleted: 1,
        deletedTime: laterDeleteTime,
        updateTime: DateTime.now().add(const Duration(hours: 2)),
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-both-del'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      final mergedDT = DateTime.fromMillisecondsSinceEpoch(
        resultSet.first['deleted_time'] as int,
      );
      expect(mergedDT, equals(laterDeleteTime));
    });

    test('本地删除时间更晚 → 保留本地删除状态', () async {
      final localManager = createManager('device-A');
      final store = createStore();

      await localManager.createEmployee(
        createEmployee(uuid: 'emp-both-del2', name: '员工'),
      );

      await Future.delayed(const Duration(milliseconds: 10));
      await localManager.deleteEmployee('emp-both-del2');

      final localDeleted =
          (await store.find(null, 'emp-both-del2'))!;
      final localDeleteTime = localDeleted.deletedTime!;

      final earlierDeleteTime =
          localDeleteTime.subtract(const Duration(hours: 1));
      final remoteEmployee = createEmployee(
        uuid: 'emp-both-del2',
        name: '员工',
        deleted: 1,
        deletedTime: earlierDeleteTime,
        updateTime: DateTime.now().add(const Duration(hours: 1)),
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-both-del2'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      final mergedDT = DateTime.fromMillisecondsSinceEpoch(
        resultSet.first['deleted_time'] as int,
      );
      expect(mergedDT, equals(localDeleteTime));
    });
  });

  // ================================================================
  // 数据 + 删除状态联合合并
  // ================================================================
  group('数据与删除状态联合合并', () {
    test('远程数据更新 + 未删除 → 更新数据，保留 deleted=0', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final baseTime = DateTime(2026, 1, 1);

      await localManager.createEmployee(
        createEmployee(
          uuid: 'emp-combined',
          name: '原名',
          createTime: baseTime,
          updateTime: baseTime,
        ),
      );

      final remoteEmployee = createEmployee(
        uuid: 'emp-combined',
        name: '新名',
        updateTime: DateTime(2026, 1, 2),
        deleted: 0,
        deletedTime: null,
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final merged = await findEmployee('emp-combined');
      expect(merged!.name, equals('新名'));
      expect(merged.deleted, equals(0));
    });

    test('远程数据更新 + 已删除 → 更新数据并标记删除', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final baseTime = DateTime(2026, 1, 1);
      final deleteTime = DateTime(2026, 1, 2);

      await localManager.createEmployee(
        createEmployee(
          uuid: 'emp-data-del',
          name: '原名',
          createTime: baseTime,
          updateTime: baseTime,
        ),
      );

      final remoteEmployee = createEmployee(
        uuid: 'emp-data-del',
        name: '新名',
        updateTime: DateTime(2026, 1, 3),
        deleted: 1,
        deletedTime: deleteTime,
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-data-del'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      expect(resultSet.first['name'] as String, equals('新名'));
      expect(resultSet.first['deleted'] as int, equals(1));
      final mergedDT = DateTime.fromMillisecondsSinceEpoch(
        resultSet.first['deleted_time'] as int,
      );
      expect(mergedDT, equals(deleteTime));
    });

    test('远程数据更旧但删除状态变化 → 只更新删除状态', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final baseTime = DateTime(2026, 1, 1);

      await localManager.createEmployee(
        createEmployee(
          uuid: 'emp-del-only',
          name: '本地新名',
          createTime: baseTime,
          updateTime: DateTime(2026, 1, 3),
        ),
      );

      final remoteEmployee = createEmployee(
        uuid: 'emp-del-only',
        name: '远程旧名',
        updateTime: DateTime(2026, 1, 2),
        deleted: 1,
        deletedTime: DateTime(2026, 1, 2),
      );

      await simulateSyncEmployees(localManager, store, [remoteEmployee]);

      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-del-only'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      // 数据不应被覆盖（远程 updateTime 更旧）
      expect(resultSet.first['name'] as String, equals('本地新名'));
      // 但删除状态应更新
      expect(resultSet.first['deleted'] as int, equals(1));
      expect(resultSet.first['deleted_time'], isNotNull);
    });
  });

  // ================================================================
  // 双向同步
  // ================================================================
  group('双向同步', () {
    test('A→B 同步后 B 能查到 A 的员工', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');
      final store = createStore();

      final empA = await managerA.createEmployee(
        createEmployee(uuid: 'emp-a2b', name: 'A创建的'),
      );

      await simulateSyncEmployees(managerB, store, [empA]);

      final onB = await findEmployee('emp-a2b');
      expect(onB, isNotNull);
      expect(onB!.name, equals('A创建的'));
      expect(onB.deviceId, equals('device-A'));
    });

    test('B→A 同步后 A 能查到 B 的员工', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');
      final store = createStore();

      final empB = await managerB.createEmployee(
        createEmployee(uuid: 'emp-b2a', name: 'B创建的'),
      );

      await simulateSyncEmployees(managerA, store, [empB]);

      final onA = await findEmployee('emp-b2a');
      expect(onA, isNotNull);
      expect(onA!.name, equals('B创建的'));
      expect(onA.deviceId, equals('device-B'));
    });

    test('双向同步后数据库中只有一份记录', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');
      final store = createStore();

      final empA = await managerA.createEmployee(
        createEmployee(uuid: 'emp-dedup', name: '去重测试'),
      );

      // A→B
      await simulateSyncEmployees(managerB, store, [empA]);
      // B→A（模拟回传）
      final fromB = await findEmployee('emp-dedup');
      expect(fromB, isNotNull);
      await simulateSyncEmployees(managerA, store, [fromB!]);

      final all = await store.findAll(null);
      expect(all.where((e) => e.uuid == 'emp-dedup').length, equals(1));
    });

    test('双方各自修改后同步 → updateTime 更新的胜出', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');
      final store = createStore();

      final empA = await managerA.createEmployee(
        createEmployee(uuid: 'emp-conflict', name: '原名'),
      );

      // 同步到 B
      await simulateSyncEmployees(managerB, store, [empA]);

      // A 更新（先）
      await Future.delayed(const Duration(milliseconds: 10));
      final empOnA = (await findEmployee('emp-conflict'))!;
      await managerA.updateEmployee(empOnA.copyWith(name: 'A改的名字'));

      // B 更新（后，updateTime 更新）
      await Future.delayed(const Duration(milliseconds: 10));
      final empOnB = (await findEmployee('emp-conflict'))!;
      await managerB.updateEmployee(empOnB.copyWith(name: 'B改的名字'));

      // A→B 同步
      final latestA = (await findEmployee('emp-conflict'))!;
      await simulateSyncEmployees(managerB, store, [latestA]);

      // B→A 同步
      final latestB = (await findEmployee('emp-conflict'))!;
      await simulateSyncEmployees(managerA, store, [latestB]);

      // 两端最终一致
      final finalA = (await findEmployee('emp-conflict'))!;
      final finalB = (await findEmployee('emp-conflict'))!;
      expect(finalA.name, equals(finalB.name));
      // updateTime 更新的 B 改的名字应胜出
      expect(finalA.name, equals('B改的名字'));
    });
  });

  // ================================================================
  // 批量同步
  // ================================================================
  group('批量同步', () {
    test('批量同步多个员工', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final now = DateTime.now();

      final remoteEmployees = List.generate(
        10,
        (i) => createEmployee(
          uuid: 'emp-batch-$i',
          name: '批量员工$i',
          deviceId: 'device-B',
          createTime: now,
          updateTime: now,
        ),
      );

      final count =
          await simulateSyncEmployees(localManager, store, remoteEmployees);
      expect(count, equals(10));

      final all = await store.findAll(null);
      expect(all.length, equals(10));

      for (var i = 0; i < 10; i++) {
        final emp = await findEmployee('emp-batch-$i');
        expect(emp, isNotNull);
        expect(emp!.name, equals('批量员工$i'));
      }
    });

    test('批量同步中部分已存在、部分新增', () async {
      final localManager = createManager('device-A');
      final store = createStore();

      await localManager.createEmployee(
        createEmployee(uuid: 'emp-existing-1', name: '本地1'),
      );
      await localManager.createEmployee(
        createEmployee(uuid: 'emp-existing-2', name: '本地2'),
      );

      final now = DateTime.now();
      final remoteEmployees = [
        createEmployee(
            uuid: 'emp-existing-1',
            name: '远程更新1',
            updateTime: now.add(const Duration(hours: 1))),
        createEmployee(
            uuid: 'emp-existing-2',
            name: '远程更新2',
            updateTime: now.add(const Duration(hours: 1))),
        createEmployee(uuid: 'emp-new-1', name: '新增1', deviceId: 'device-B'),
        createEmployee(uuid: 'emp-new-2', name: '新增2', deviceId: 'device-B'),
        createEmployee(uuid: 'emp-new-3', name: '新增3', deviceId: 'device-B'),
      ];

      await simulateSyncEmployees(localManager, store, remoteEmployees);

      final all = await store.findAll(null);
      expect(all.length, equals(5));

      final updated1 = await findEmployee('emp-existing-1');
      expect(updated1!.name, equals('远程更新1'));

      expect(await findEmployee('emp-new-1'), isNotNull);
      expect(await findEmployee('emp-new-2'), isNotNull);
      expect(await findEmployee('emp-new-3'), isNotNull);
    });
  });

  // ================================================================
  // 空列表与边界情况
  // ================================================================
  group('边界情况', () {
    test('同步空列表不影响现有数据', () async {
      final localManager = createManager('device-A');
      final store = createStore();

      await localManager.createEmployee(
        createEmployee(uuid: 'emp-keep', name: '保留'),
      );

      await simulateSyncEmployees(localManager, store, []);

      final all = await store.findAll(null);
      expect(all.length, equals(1));
      expect(all.first.name, equals('保留'));
    });

    test('重复同步同一员工不产生副作用', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final now = DateTime.now();

      final remote = createEmployee(
        uuid: 'emp-repeat',
        name: '重复',
        deviceId: 'device-B',
        createTime: now,
        updateTime: now,
      );

      await simulateSyncEmployees(localManager, store, [remote]);
      await simulateSyncEmployees(localManager, store, [remote]);
      await simulateSyncEmployees(localManager, store, [remote]);

      final all = await store.findAll(null);
      expect(all.where((e) => e.uuid == 'emp-repeat').length, equals(1));
    });

    test('同步带有完整字段的新员工', () async {
      final localManager = createManager('device-A');
      final store = createStore();
      final now = DateTime.now();

      final fullEmployee = AiEmployeeEntity(
        uuid: 'emp-full-fields',
        deviceId: 'device-B',
        name: '全字段员工',
        avatar: 'https://example.com/avatar.png',
        role: 'coder',
        status: 'active',
        description: '这是一个测试员工',
        systemPrompt: '你是一个编程助手',
        provider: 'claude',
        model: 'claude-3-opus',
        apiKey: 'sk-test-key',
        apiBaseUrl: 'https://api.example.com',
        modelConfig: '{"temperature": 0.7}',
        enableTools: 1,
        enableMcp: 1,
        projectUuid: 'proj-123',
        projectName: '测试项目',
        projectContext: '项目上下文信息',
        workPath: '/path/to/project',
        mcpConfig: '{"servers":[]}',
        permissionConfig: '{"allowedTools": ["*"]}',
        autoApprove: 1,
        sortOrder: 10,
        isPinned: 1,
        createTime: now,
        updateTime: now,
      );

      await simulateSyncEmployees(localManager, store, [fullEmployee]);

      final employee = await findEmployee('emp-full-fields');
      expect(employee, isNotNull);

      final e = employee!;
      expect(e.name, equals('全字段员工'));
      expect(e.avatar, equals('https://example.com/avatar.png'));
      expect(e.role, equals('coder'));
      expect(e.provider, equals('claude'));
      expect(e.model, equals('claude-3-opus'));
      expect(e.enableTools, equals(1));
      expect(e.enableMcp, equals(1));
      expect(e.isPinned, equals(1));
      expect(e.sortOrder, equals(10));
      expect(e.deviceId, equals('device-B'));
    });

    test('同步后再删除再同步 → 删除状态正确', () async {
      final localManager = createManager('device-A');
      final store = createStore();

      // 同步新员工
      await simulateSyncEmployees(
        localManager,
        store,
        [createEmployee(uuid: 'emp-lifecycle', name: '生命周期')],
      );
      expect(await findEmployee('emp-lifecycle'), isNotNull);

      // 本地删除
      await localManager.deleteEmployee('emp-lifecycle');
      expect(
        (await store.findAll(null)).any((e) => e.uuid == 'emp-lifecycle'),
        isFalse,
      );

      // 远程再同步一次（未删除版本，updateTime 更新）
      await simulateSyncEmployees(
        localManager,
        store,
        [
          createEmployee(
            uuid: 'emp-lifecycle',
            name: '生命周期',
            updateTime: DateTime.now().add(const Duration(hours: 1)),
          ),
        ],
      );

      // 本地删除状态应保留
      final resultSet = dbManager.db.select(
        'SELECT deleted FROM employees WHERE uuid = ?', ['emp-lifecycle'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      expect(resultSet.first['deleted'] as int, equals(1));
    });
  });
}
