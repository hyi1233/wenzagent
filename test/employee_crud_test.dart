import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/employee_entity.dart';
import 'package:wenzagent/src/persistence/stores/employee_store.dart';
import 'package:wenzagent/src/service/employee_manager.dart';

/// 员工增删改查测试
///
/// 覆盖 EmployeeManager 和 EmployeeStore 的完整 CRUD 流程。
void main() {
  late DatabaseManager dbManager;
  late String dbDir;

  setUpAll(() {
    dbDir = p.join(
      Directory.systemTemp.path,
      'employee_crud_test_${DateTime.now().millisecondsSinceEpoch}',
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
    dbManager.db.execute('DELETE FROM employees');
  });

  EmployeeManagerImpl createManager({String deviceId = 'test-device'}) {
    return EmployeeManagerImpl(
      store: EmployeeStore(dbManager: dbManager),
      deviceId: deviceId,
    );
  }

  EmployeeStore createStore() {
    return EmployeeStore(dbManager: dbManager);
  }

  AiEmployeeEntity buildEmployee({
    required String uuid,
    required String name,
    String? avatar,
    String role = 'assistant',
    String status = 'active',
    String? description,
    String? systemPrompt,
    String? provider,
    String? model,
    String? apiKey,
    String? apiBaseUrl,
    String? deviceId,
    int enableTools = 1,
    int enableMcp = 0,
    int isPinned = 0,
    int sortOrder = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return AiEmployeeEntity(
      uuid: uuid,
      name: name,
      avatar: avatar,
      role: role,
      status: status,
      description: description,
      systemPrompt: systemPrompt,
      provider: provider,
      model: model,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
      deviceId: deviceId,
      enableTools: enableTools,
      enableMcp: enableMcp,
      isPinned: isPinned,
      sortOrder: sortOrder,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  // ================================================================
  // 创建 (Create)
  // ================================================================
  group('创建员工', () {
    test('基本创建', () async {
      final manager = createManager();
      final employee = buildEmployee(uuid: 'emp-1', name: '张三');
      final created = await manager.createEmployee(employee);

      expect(created.uuid, equals('emp-1'));
      expect(created.name, equals('张三'));
      expect(created.deviceId, equals('test-device'));
      expect(created.status, equals('active'));
      expect(created.role, equals('assistant'));
      expect(created.deleted, equals(0));
      expect(created.createTime.isNotNull, isTrue);
      expect(created.updateTime.isNotNull, isTrue);
    });

    test('deviceId 为空时自动填充', () async {
      final manager = createManager(deviceId: 'auto-device');
      final employee = buildEmployee(uuid: 'emp-auto', name: '自动填充');
      final created = await manager.createEmployee(employee);

      expect(created.deviceId, equals('auto-device'));
    });

    test('已有 deviceId 时保留原值', () async {
      final manager = createManager(deviceId: 'device-A');
      final employee = buildEmployee(
        uuid: 'emp-keep',
        name: '保留',
        deviceId: 'original-device',
      );
      final created = await manager.createEmployee(employee);

      expect(created.deviceId, equals('original-device'));
    });

    test('createEmployee 触发 created 事件', () async {
      final manager = createManager();
      final events = <EmployeeChangeEvent>[];
      manager.onEmployeeChanged.listen(events.add);

      await manager.createEmployee(buildEmployee(uuid: 'emp-event', name: '事件'));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(events.length, equals(1));
      expect(events.first.type, equals(EmployeeChangeType.created));
      expect(events.first.employeeId, equals('emp-event'));
    });
  });

  // ================================================================
  // 查询 (Read)
  // ================================================================
  group('查询员工', () {
    test('getEmployee 按 uuid 查询', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: '员工1'));

      final found = await manager.getEmployee('emp-1');
      expect(found, isNotNull);
      expect(found!.name, equals('员工1'));
    });

    test('getEmployee 查询不存在的 uuid 返回 null', () async {
      final manager = createManager();
      final found = await manager.getEmployee('not-exist');
      expect(found, isNull);
    });

    test('getEmployees 获取所有员工', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-2', name: 'B'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-3', name: 'C'));

      final list = await manager.getEmployees();
      expect(list.length, equals(3));
      expect(list.map((e) => e.uuid).toList(), containsAll(['emp-1', 'emp-2', 'emp-3']));
    });

    test('getEmployees 按 keyword 过滤（名称模糊匹配）', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'Python工程师'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-2', name: 'Java工程师'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-3', name: '产品经理'));

      final result = await manager.getEmployees(keyword: '工程师');
      expect(result.length, equals(2));
      expect(result.every((e) => e.name.contains('工程师')), isTrue);
    });

    test('getEmployees 按 description 模糊匹配', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(
        uuid: 'emp-1', name: 'A', description: '擅长Rust开发',
      ));
      await manager.createEmployee(buildEmployee(
        uuid: 'emp-2', name: 'B', description: '擅长Go开发',
      ));
      await manager.createEmployee(buildEmployee(
        uuid: 'emp-3', name: 'C', description: '设计能力',
      ));

      final result = await manager.getEmployees(keyword: '擅长');
      expect(result.length, equals(2));
    });

    test('getEmployees 按 status 过滤', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A', status: 'active'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-2', name: 'B', status: 'inactive'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-3', name: 'C', status: 'active'));

      final active = await manager.getEmployees(status: 'active');
      expect(active.length, equals(2));

      final inactive = await manager.getEmployees(status: 'inactive');
      expect(inactive.length, equals(1));
      expect(inactive.first.uuid, equals('emp-2'));
    });

    test('getEmployees 按 deviceId 隔离', () async {
      final managerA = createManager(deviceId: 'device-A');
      final managerB = createManager(deviceId: 'device-B');

      await managerA.createEmployee(buildEmployee(uuid: 'emp-a1', name: 'A的员工'));
      await managerA.createEmployee(buildEmployee(uuid: 'emp-a2', name: 'A的员工2'));
      await managerB.createEmployee(buildEmployee(uuid: 'emp-b1', name: 'B的员工'));

      final listA = await managerA.getEmployees();
      final listB = await managerB.getEmployees();

      expect(listA.length, equals(2));
      expect(listB.length, equals(1));
      expect(listA.every((e) => e.deviceId == 'device-A'), isTrue);
      expect(listB.every((e) => e.deviceId == 'device-B'), isTrue);
    });

    test('getEmployeeStats 统计信息', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));
      await manager.createEmployee(
        buildEmployee(uuid: 'emp-2', name: 'B', status: 'inactive'),
      );
      await manager.createEmployee(
        buildEmployee(uuid: 'emp-3', name: 'C', isPinned: 1),
      );

      final stats = await manager.getEmployeeStats();
      expect(stats.totalCount, equals(3));
      expect(stats.activeCount, equals(2));
      expect(stats.pinnedCount, equals(1));
    });
  });

  // ================================================================
  // 更新 (Update)
  // ================================================================
  group('更新员工', () {
    test('updateEmployee 更新名称和描述', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: '原名'));

      final employee = (await manager.getEmployee('emp-1'))!;
      final updated = employee.copyWith(
        name: '新名称',
        description: '新描述',
      );
      await manager.updateEmployee(updated);

      final result = await manager.getEmployee('emp-1');
      expect(result!.name, equals('新名称'));
      expect(result.description, equals('新描述'));
    });

    test('updateEmployee 自动更新 updateTime', () async {
      final manager = createManager();
      final created = await manager.createEmployee(
        buildEmployee(uuid: 'emp-1', name: '时间测试'),
      );
      final originalTime = created.updateTime;

      await Future.delayed(const Duration(milliseconds: 10));
      final employee = (await manager.getEmployee('emp-1'))!;
      await manager.updateEmployee(employee.copyWith(name: '更新'));

      final result = await manager.getEmployee('emp-1');
      expect(result!.updateTime.isAfter(originalTime), isTrue);
    });

    test('updateEmployee 触发 updated 事件', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));
      final events = <EmployeeChangeEvent>[];
      manager.onEmployeeChanged.listen(events.add);

      final employee = (await manager.getEmployee('emp-1'))!;
      await manager.updateEmployee(employee.copyWith(name: 'B'));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(events.length, equals(1));
      expect(events.first.type, equals(EmployeeChangeType.updated));
    });

    test('updateEmployee 更新 provider 和 model 配置', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'AI'));

      final employee = (await manager.getEmployee('emp-1'))!;
      await manager.updateEmployee(employee.copyWith(
        provider: 'claude',
        model: 'claude-3-opus',
        apiKey: 'sk-test',
        apiBaseUrl: 'https://api.example.com',
      ));

      final result = await manager.getEmployee('emp-1');
      expect(result!.provider, equals('claude'));
      expect(result.model, equals('claude-3-opus'));
      expect(result.apiKey, equals('sk-test'));
      expect(result.apiBaseUrl, equals('https://api.example.com'));
    });

    test('updateEmployee 更新 enableTools 和 enableMcp', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: '工具测试'));

      final employee = (await manager.getEmployee('emp-1'))!;
      await manager.updateEmployee(employee.copyWith(
        enableTools: 0,
        enableMcp: 1,
      ));

      final result = await manager.getEmployee('emp-1');
      expect(result!.enableTools, equals(0));
      expect(result.enableMcp, equals(1));
      expect(result.isMcpEnabled, isTrue);
    });

    test('updateCurrentDeviceId 更新会话设备', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: '漫游测试'));

      await manager.updateCurrentDeviceId('emp-1', 'other-device');

      final result = await manager.getEmployee('emp-1');
      expect(result!.currentDeviceId, equals('other-device'));
    });

    test('updateCurrentDeviceId 对不存在的员工不报错', () async {
      final manager = createManager();
      // 不应抛出异常
      await manager.updateCurrentDeviceId('not-exist', 'device-X');
    });

    test('saveEmployee 保留原始时间戳', () async {
      final manager = createManager();
      final baseTime = DateTime(2026, 1, 1);
      final employee = buildEmployee(
        uuid: 'emp-1', name: '同步',
        createTime: baseTime,
        updateTime: baseTime,
      );

      await manager.saveEmployee(employee);

      final result = await createStore().find(null, 'emp-1');
      expect(result, isNotNull);
      expect(result!.createTime, equals(baseTime));
      expect(result.updateTime, equals(baseTime));
    });
  });

  // ================================================================
  // 删除 (Delete)
  // ================================================================
  group('删除员工', () {
    test('deleteEmployee 软删除', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: '待删除'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-2', name: '保留'));

      await manager.deleteEmployee('emp-1');

      // 列表中不再出现
      final list = await manager.getEmployees();
      expect(list.length, equals(1));
      expect(list.first.uuid, equals('emp-2'));

      // 数据库中标记为已删除
      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-1'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      expect(resultSet.first['deleted'] as int, equals(1));
      expect(resultSet.first['deleted_time'], isNotNull);
    });

    test('deleteEmployee 触发 deleted 事件', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));
      final events = <EmployeeChangeEvent>[];
      manager.onEmployeeChanged.listen(events.add);

      await manager.deleteEmployee('emp-1');

      await Future.delayed(const Duration(milliseconds: 50));
      expect(events.length, equals(1));
      expect(events.first.type, equals(EmployeeChangeType.deleted));
      expect(events.first.employeeId, equals('emp-1'));
    });

    test('deleteEmployee 后 getEmployee 返回 null', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));
      await manager.deleteEmployee('emp-1');

      final found = await manager.getEmployee('emp-1');
      expect(found, isNull);
    });
  });

  // ================================================================
  // Store 层直接测试
  // ================================================================
  group('EmployeeStore', () {
    test('exists 存在返回 true', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));

      final store = createStore();
      expect(await store.exists(null, 'emp-1'), isTrue);
    });

    test('exists 不存在返回 false', () async {
      final store = createStore();
      expect(await store.exists(null, 'not-exist'), isFalse);
    });

    test('exists 软删除后返回 false', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));
      await manager.deleteEmployee('emp-1');

      final store = createStore();
      expect(await store.exists(null, 'emp-1'), isFalse);
    });

    test('count 统计数量', () async {
      final manager = createManager();
      await manager.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A', status: 'active'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-2', name: 'B', status: 'active'));
      await manager.createEmployee(buildEmployee(uuid: 'emp-3', name: 'C', status: 'inactive'));

      final store = createStore();
      expect(await store.count(null), equals(3));
      expect(await store.count(null, status: 'active'), equals(2));
      expect(await store.count('test-device'), equals(3));
      expect(await store.count('other-device'), equals(0));
    });

    test('findAll(null) 返回全部（不过滤 deviceId）', () async {
      final managerA = createManager(deviceId: 'device-A');
      final managerB = createManager(deviceId: 'device-B');
      await managerA.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));
      await managerB.createEmployee(buildEmployee(uuid: 'emp-2', name: 'B'));

      final store = createStore();
      final all = await store.findAll(null);
      expect(all.length, equals(2));
    });

    test('find(null, uuid) 不过滤 deviceId', () async {
      final managerA = createManager(deviceId: 'device-A');
      await managerA.createEmployee(buildEmployee(uuid: 'emp-1', name: 'A'));

      final managerB = createManager(deviceId: 'device-B');
      // B 的 manager 按 deviceId 过滤查不到
      final fromB = await managerB.getEmployee('emp-1');
      expect(fromB, isNull);

      // store.find(null) 可以查到
      final store = createStore();
      final found = await store.find(null, 'emp-1');
      expect(found, isNotNull);
      expect(found!.name, equals('A'));
    });
  });

  // ================================================================
  // 完整流程
  // ================================================================
  group('完整 CRUD 流程', () {
    test('创建 → 查询 → 更新 → 查询 → 删除 → 确认', () async {
      final manager = createManager();

      // 1. 创建
      final created = await manager.createEmployee(buildEmployee(
        uuid: 'emp-flow',
        name: '流程测试',
        description: '初始描述',
        provider: 'openai',
        model: 'gpt-4',
      ));
      expect(created.name, equals('流程测试'));
      expect(created.description, equals('初始描述'));

      // 2. 查询
      var found = await manager.getEmployee('emp-flow');
      expect(found, isNotNull);
      expect(found!.provider, equals('openai'));

      // 3. 更新
      await manager.updateEmployee(found.copyWith(
        name: '更新后',
        description: '新描述',
        provider: 'claude',
        model: 'claude-3-opus',
      ));

      // 4. 查询验证更新
      found = await manager.getEmployee('emp-flow');
      expect(found!.name, equals('更新后'));
      expect(found.description, equals('新描述'));
      expect(found.provider, equals('claude'));
      expect(found.model, equals('claude-3-opus'));

      // 5. 删除
      await manager.deleteEmployee('emp-flow');

      // 6. 确认删除
      found = await manager.getEmployee('emp-flow');
      expect(found, isNull);

      final list = await manager.getEmployees();
      expect(list.isEmpty, isTrue);
    });
  });
}

extension _DateTimeNotNull on DateTime {
  bool get isNotNull => true;
}
