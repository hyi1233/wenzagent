import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/spec_item_entity.dart';
import 'package:wenzagent/src/persistence/stores/spec_store.dart';

int _testCounter = 0;

/// SpecStore 单元测试
///
/// 验证：
/// - SpecItem CRUD（保存、查询、更新状态、更新内容）
/// - 按状态过滤（findActiveByEmployee、findCompletedByEmployee）
/// - 软删除（softDelete 后不出现在 findActive 结果中）
/// - 排序（reorderSpecs 事务性）
/// - upsertFromRemote 合并策略
/// - countByStatus 统计准确性
void main() {
  late String testDbPath;
  late String deviceId;
  late SpecStore store;
  const employeeId = 'emp-spec-test';

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_spec_store_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = SpecStore(deviceId: deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  SpecItemEntity createSpec({
    String? id,
    String? empId,
    String title = '测试Spec',
    String content = '测试内容',
    String status = 'pending',
    String priority = 'medium',
    String tags = '',
    int sortOrder = 0,
    int deleted = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return SpecItemEntity(
      id: id ?? const Uuid().v4(),
      employeeId: empId ?? employeeId,
      title: title,
      content: content,
      status: status,
      priority: priority,
      tags: tags,
      sortOrder: sortOrder,
      deleted: deleted,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // 1. SpecItem CRUD
  // ═══════════════════════════════════════════════════

  group('SpecItem CRUD', () {
    test('save 后 findById 返回完整数据', () {
      final spec = createSpec(
        id: 'spec-1',
        title: 'API规格',
        content: '详细描述',
        status: 'draft',
        priority: 'high',
        tags: 'api,core',
        sortOrder: 5,
      );

      store.save(spec);

      final found = store.findById('spec-1');
      expect(found, isNotNull);
      expect(found!.id, equals('spec-1'));
      expect(found.employeeId, equals(employeeId));
      expect(found.title, equals('API规格'));
      expect(found.content, equals('详细描述'));
      expect(found.status, equals('draft'));
      expect(found.priority, equals('high'));
      expect(found.tags, equals('api,core'));
      expect(found.sortOrder, equals(5));
      expect(found.deleted, equals(0));
    });

    test('findById 不存在的 ID 返回 null', () {
      expect(store.findById('non-existent'), isNull);
    });

    test('findById 不返回已软删除的项', () {
      final spec = createSpec(id: 'spec-del');
      store.save(spec);
      store.softDelete('spec-del');

      expect(store.findById('spec-del'), isNull);
    });

    test('findByIdIncludingDeleted 返回已软删除的项', () {
      final spec = createSpec(id: 'spec-del-inc');
      store.save(spec);
      store.softDelete('spec-del-inc');

      final found = store.findByIdIncludingDeleted('spec-del-inc');
      expect(found, isNotNull);
      expect(found!.deleted, equals(1));
    });

    test('save 覆盖更新（同 ID）', () {
      final spec = createSpec(id: 'spec-update', title: '旧标题');
      store.save(spec);

      final updated = spec.copyWith(title: '新标题', status: 'in_progress');
      store.save(updated);

      final found = store.findById('spec-update');
      expect(found!.title, equals('新标题'));
      expect(found.status, equals('in_progress'));
    });

    test('save 保留时间戳精度', () {
      final ct = DateTime(2025, 6, 1, 10, 0, 0);
      final ut = DateTime(2025, 6, 2, 15, 30, 0);
      final spec = createSpec(id: 'spec-time', createTime: ct, updateTime: ut);
      store.save(spec);

      final found = store.findById('spec-time');
      expect(found!.createTime.millisecondsSinceEpoch,
          equals(ct.millisecondsSinceEpoch));
      expect(found.updateTime.millisecondsSinceEpoch,
          equals(ut.millisecondsSinceEpoch));
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. 按状态过滤
  // ═══════════════════════════════════════════════════

  group('按状态过滤', () {
    test('findActiveByEmployee 返回 draft/pending/in_progress', () {
      store.save(createSpec(id: 's-draft', status: 'draft'));
      store.save(createSpec(id: 's-pending', status: 'pending'));
      store.save(createSpec(id: 's-inprog', status: 'in_progress'));
      store.save(createSpec(id: 's-completed', status: 'completed'));

      final active = store.findActiveByEmployee(employeeId);
      expect(active.length, equals(3));
      final ids = active.map((s) => s.id).toSet();
      expect(ids, containsAll(['s-draft', 's-pending', 's-inprog']));
      expect(ids, isNot(contains('s-completed')));
    });

    test('findActiveByEmployee 不包含已软删除的项', () {
      store.save(createSpec(id: 's-active', status: 'pending'));
      store.save(createSpec(id: 's-del-active', status: 'pending'));
      store.softDelete('s-del-active');

      final active = store.findActiveByEmployee(employeeId);
      expect(active.length, equals(1));
      expect(active.first.id, equals('s-active'));
    });

    test('findActiveByEmployee 按 employeeId 过滤', () {
      store.save(createSpec(id: 's-empA', empId: 'emp-A', status: 'pending'));
      store.save(createSpec(id: 's-empB', empId: 'emp-B', status: 'pending'));

      final empA = store.findActiveByEmployee('emp-A');
      expect(empA.length, equals(1));
      expect(empA.first.id, equals('s-empA'));
    });

    test('findActiveByEmployee 按 sortOrder ASC 排序', () {
      store.save(createSpec(id: 's-3', status: 'pending', sortOrder: 3));
      store.save(createSpec(id: 's-1', status: 'pending', sortOrder: 1));
      store.save(createSpec(id: 's-2', status: 'pending', sortOrder: 2));

      final active = store.findActiveByEmployee(employeeId);
      expect(active.map((s) => s.id).toList(),
          equals(['s-1', 's-2', 's-3']));
    });

    test('findCompletedByEmployee 返回 completed 项', () {
      store.save(createSpec(id: 's-done1', status: 'completed'));
      store.save(createSpec(id: 's-done2', status: 'completed'));
      store.save(createSpec(id: 's-pending', status: 'pending'));

      final completed = store.findCompletedByEmployee(employeeId);
      expect(completed.length, equals(2));
    });

    test('findCompletedByEmployee 支持 limit 参数', () {
      for (var i = 0; i < 5; i++) {
        store.save(createSpec(id: 's-done-$i', status: 'completed'));
      }

      final completed = store.findCompletedByEmployee(employeeId, limit: 2);
      expect(completed.length, equals(2));
    });

    test('findAllByEmployee 返回所有项含已删除', () {
      store.save(createSpec(id: 's-1', status: 'pending'));
      store.save(createSpec(id: 's-2', status: 'pending'));
      store.softDelete('s-2');

      final all = store.findAllByEmployee(employeeId);
      expect(all.length, equals(2)); // 含已删除
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. 更新操作
  // ═══════════════════════════════════════════════════

  group('更新操作', () {
    test('updateStatus 更新状态', () {
      store.save(createSpec(id: 'spec-status', status: 'draft'));
      store.updateStatus('spec-status', 'in_progress');

      final found = store.findById('spec-status');
      expect(found!.status, equals('in_progress'));
    });

    test('updateContent 仅更新 title', () {
      store.save(createSpec(id: 'spec-ut', title: '原标题', content: '原内容'));
      store.updateContent('spec-ut', title: '新标题');

      final found = store.findById('spec-ut');
      expect(found!.title, equals('新标题'));
      expect(found.content, equals('原内容'));
    });

    test('updateContent 仅更新 content', () {
      store.save(createSpec(id: 'spec-uc', title: '原标题', content: '原内容'));
      store.updateContent('spec-uc', content: '新内容');

      final found = store.findById('spec-uc');
      expect(found!.title, equals('原标题'));
      expect(found.content, equals('新内容'));
    });

    test('updateContent 同时更新 title 和 content', () {
      store.save(createSpec(id: 'spec-ub', title: '原标题', content: '原内容'));
      store.updateContent('spec-ub', title: '双改标题', content: '双改内容');

      final found = store.findById('spec-ub');
      expect(found!.title, equals('双改标题'));
      expect(found.content, equals('双改内容'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. 软删除与硬删除
  // ═══════════════════════════════════════════════════

  group('软删除与硬删除', () {
    test('softDelete 后 findById 返回 null', () {
      store.save(createSpec(id: 'spec-sd'));
      store.softDelete('spec-sd');

      expect(store.findById('spec-sd'), isNull);
      expect(store.findByIdIncludingDeleted('spec-sd'), isNotNull);
      expect(store.findByIdIncludingDeleted('spec-sd')!.deleted, equals(1));
    });

    test('deleteCompletedByEmployee 硬删除已完成项', () {
      store.save(createSpec(id: 's-done', status: 'completed'));
      store.save(createSpec(id: 's-pending', status: 'pending'));

      store.deleteCompletedByEmployee(employeeId);

      expect(store.findByIdIncludingDeleted('s-done'), isNull);
      expect(store.findById('s-pending'), isNotNull);
    });

    test('deleteCompletedByEmployee 按 employeeId 过滤', () {
      store.save(
          createSpec(id: 's-empA-done', empId: 'emp-A', status: 'completed'));
      store.save(
          createSpec(id: 's-empB-done', empId: 'emp-B', status: 'completed'));

      store.deleteCompletedByEmployee('emp-A');

      expect(store.findByIdIncludingDeleted('s-empA-done'), isNull);
      expect(store.findByIdIncludingDeleted('s-empB-done'), isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. reorderSpecs 排序
  // ═══════════════════════════════════════════════════

  group('reorderSpecs', () {
    test('reorderSpecs 更新排序序号', () {
      store.save(createSpec(id: 'spec-a', sortOrder: 0));
      store.save(createSpec(id: 'spec-b', sortOrder: 1));
      store.save(createSpec(id: 'spec-c', sortOrder: 2));

      // 反转排序
      store.reorderSpecs(['spec-c', 'spec-b', 'spec-a']);

      final all = store.findActiveByEmployee(employeeId);
      final orderMap = {for (var s in all) s.id: s.sortOrder};
      expect(orderMap['spec-c'], equals(0));
      expect(orderMap['spec-b'], equals(1));
      expect(orderMap['spec-a'], equals(2));
    });

    test('reorderSpecs 部分排序不影响其他项', () {
      store.save(createSpec(id: 'spec-a', sortOrder: 0));
      store.save(createSpec(id: 'spec-b', sortOrder: 1));

      store.reorderSpecs(['spec-b', 'spec-a']);

      final found = store.findById('spec-a');
      expect(found!.sortOrder, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 6. upsertFromRemote 合并策略
  // ═══════════════════════════════════════════════════

  group('upsertFromRemote 合并策略', () {
    test('本地不存在 → 直接插入', () {
      final remote = createSpec(id: 'remote-new', title: '远程新项');
      final changed = store.upsertFromRemote(remote);

      expect(changed, isTrue);
      final found = store.findById('remote-new');
      expect(found, isNotNull);
      expect(found!.title, equals('远程新项'));
    });

    test('远程更新 → 本地更新（remote updateTime 更新）', () {
      final local = createSpec(
        id: 'spec-merge',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 1),
      );
      store.save(local);

      final remote = createSpec(
        id: 'spec-merge',
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isTrue);
      final found = store.findById('spec-merge');
      expect(found!.title, equals('远程标题'));
    });

    test('本地更新 → 不覆盖（local updateTime 更新）', () {
      final local = createSpec(
        id: 'spec-merge-local',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 3),
      );
      store.save(local);

      final remote = createSpec(
        id: 'spec-merge-local',
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isFalse);
      final found = store.findById('spec-merge-local');
      expect(found!.title, equals('本地标题'));
    });

    test('时间相同 → 不覆盖', () {
      final time = DateTime(2025, 6, 1, 12, 0, 0);
      final local = createSpec(
        id: 'spec-same-time',
        title: '本地标题',
        updateTime: time,
      );
      store.save(local);

      final remote = createSpec(
        id: 'spec-same-time',
        title: '远程标题',
        updateTime: time,
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isFalse);
    });

    test('软删除合并：远程已删除 → 本地也标记删除', () {
      final local = createSpec(
        id: 'spec-remote-del',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 1),
      );
      store.save(local);

      final remote = createSpec(
        id: 'spec-remote-del',
        title: '远程标题',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isTrue);
      expect(store.findById('spec-remote-del'), isNull);
      expect(store.findByIdIncludingDeleted('spec-remote-del')!.deleted,
          equals(1));
    });

    test('软删除合并：本地已删除 → 远程未删除也保留删除', () {
      final local = createSpec(
        id: 'spec-local-del',
        title: '本地标题',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      store.save(local);

      final remote = createSpec(
        id: 'spec-local-del',
        title: '远程标题',
        deleted: 0,
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isFalse); // mergedDeleted == existing.deleted
      expect(store.findByIdIncludingDeleted('spec-local-del')!.deleted,
          equals(1));
    });

    test('双方都已删除 → 保留删除状态', () {
      final local = createSpec(
        id: 'spec-both-del',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      store.save(local);

      final remote = createSpec(
        id: 'spec-both-del',
        deleted: 1,
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isTrue); // 远程更新时间更新
      expect(store.findByIdIncludingDeleted('spec-both-del')!.deleted,
          equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 7. upsertAllFromRemote 批量合并
  // ═══════════════════════════════════════════════════

  group('upsertAllFromRemote', () {
    test('批量合并返回变化数量', () {
      final items = [
        createSpec(id: 'batch-1', title: '新项1'),
        createSpec(id: 'batch-2', title: '新项2'),
        createSpec(id: 'batch-3', title: '新项3'),
      ];

      final changed = store.upsertAllFromRemote(items);
      expect(changed, equals(3));
    });

    test('批量合并混合新旧数据', () {
      // 预存一条旧数据
      store.save(createSpec(
        id: 'batch-old',
        title: '旧标题',
        updateTime: DateTime(2025, 6, 1),
      ));

      final items = [
        createSpec(
          id: 'batch-old',
          title: '新标题',
          updateTime: DateTime(2025, 6, 2),
        ), // 更新
        createSpec(id: 'batch-new', title: '全新项'), // 新增
      ];

      final changed = store.upsertAllFromRemote(items);
      expect(changed, equals(2));
      expect(store.findById('batch-old')!.title, equals('新标题'));
      expect(store.findById('batch-new'), isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 8. countByStatus 统计
  // ═══════════════════════════════════════════════════

  group('countByStatus', () {
    test('按状态统计准确性', () {
      store.save(createSpec(id: 's1', status: 'draft'));
      store.save(createSpec(id: 's2', status: 'pending'));
      store.save(createSpec(id: 's3', status: 'pending'));
      store.save(createSpec(id: 's4', status: 'in_progress'));
      store.save(createSpec(id: 's5', status: 'completed'));

      final counts = store.countByStatus(employeeId);
      expect(counts['draft'], equals(1));
      expect(counts['pending'], equals(2));
      expect(counts['in_progress'], equals(1));
      expect(counts['completed'], equals(1));
    });

    test('无数据时返回全零', () {
      final counts = store.countByStatus(employeeId);
      expect(counts['draft'], equals(0));
      expect(counts['pending'], equals(0));
      expect(counts['in_progress'], equals(0));
      expect(counts['completed'], equals(0));
    });

    test('软删除的不计入统计', () {
      store.save(createSpec(id: 's-active', status: 'pending'));
      store.save(createSpec(id: 's-del', status: 'pending'));
      store.softDelete('s-del');

      final counts = store.countByStatus(employeeId);
      expect(counts['pending'], equals(1));
    });

    test('按 employeeId 过滤', () {
      store.save(createSpec(id: 's-empA', empId: 'emp-A', status: 'pending'));
      store.save(createSpec(id: 's-empB', empId: 'emp-B', status: 'pending'));

      final counts = store.countByStatus('emp-A');
      expect(counts['pending'], equals(1));
    });
  });
}
