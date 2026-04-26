import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/sync_watermark_entity.dart';
import 'package:wenzagent/src/persistence/stores/sync_watermark_store.dart';

int _testCounter = 0;

/// SyncWatermarkStore 单元测试
///
/// 验证：
/// - getWatermark / getLastSeq 基本读写
/// - updateLastSeq 的 MAX 语义（防回退）
/// - resetLastSeq 强制重置（不受 MAX 限制）
/// - clearSeq 生命周期（set → get → clear → null）
/// - upsert 完整覆写
/// - 不存在时的默认值
void main() {
  late String testDbPath;
  late String deviceId;
  late SyncWatermarkStore store;
  const employeeId = 'emp-sync-test';

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_sync_wm_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = SyncWatermarkStore(deviceId: deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 1. 基本读写
  // ═══════════════════════════════════════════════════

  group('基本读写', () {
    test('getWatermark 不存在时返回 null', () {
      final wm = store.getWatermark(employeeId);
      expect(wm, isNull);
    });

    test('getLastSeq 不存在时返回 0', () {
      final seq = store.getLastSeq(employeeId);
      expect(seq, equals(0));
    });

    test('upsert + getWatermark 完整往返', () {
      final entity = SyncWatermarkEntity(
        employeeId: employeeId,
        deviceId: '',
        lastSeq: 100,
        clearSeq: 50,
        updateTime: DateTime(2025, 6, 15, 10, 0, 0),
      );

      store.upsert(entity);

      final found = store.getWatermark(employeeId);
      expect(found, isNotNull);
      expect(found!.employeeId, equals(employeeId));
      expect(found.deviceId, equals(''));
      expect(found.lastSeq, equals(100));
      expect(found.clearSeq, equals(50));
      expect(found.updateTime.millisecondsSinceEpoch,
          equals(entity.updateTime.millisecondsSinceEpoch));
    });

    test('upsert + getLastSeq 返回 lastSeq', () {
      store.upsert(SyncWatermarkEntity(
        employeeId: employeeId,
        lastSeq: 42,
        updateTime: DateTime.now(),
      ));

      expect(store.getLastSeq(employeeId), equals(42));
    });

    test('upsert 按 employeeId + deviceId 隔离', () {
      store.upsert(SyncWatermarkEntity(
        employeeId: employeeId,
        deviceId: 'devA',
        lastSeq: 100,
        updateTime: DateTime.now(),
      ));
      store.upsert(SyncWatermarkEntity(
        employeeId: employeeId,
        deviceId: 'devB',
        lastSeq: 200,
        updateTime: DateTime.now(),
      ));

      expect(store.getLastSeq(employeeId, deviceId: 'devA'), equals(100));
      expect(store.getLastSeq(employeeId, deviceId: 'devB'), equals(200));
      expect(store.getLastSeq(employeeId), equals(0)); // 默认 deviceId=''
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. updateLastSeq MAX 语义
  // ═══════════════════════════════════════════════════

  group('updateLastSeq - MAX 语义', () {
    test('首次 updateLastSeq 创建记录', () {
      store.updateLastSeq(employeeId, 10);

      final wm = store.getWatermark(employeeId);
      expect(wm, isNotNull);
      expect(wm!.lastSeq, equals(10));
    });

    test('更大的值会更新', () {
      store.updateLastSeq(employeeId, 10);
      store.updateLastSeq(employeeId, 20);

      expect(store.getLastSeq(employeeId), equals(20));
    });

    test('更小的值不会回退（MAX 语义）', () {
      store.updateLastSeq(employeeId, 100);
      store.updateLastSeq(employeeId, 50);

      expect(store.getLastSeq(employeeId), equals(100));
    });

    test('相同的值不变化', () {
      store.updateLastSeq(employeeId, 100);
      store.updateLastSeq(employeeId, 100);

      expect(store.getLastSeq(employeeId), equals(100));
    });

    test('多次递增更新', () {
      for (var i = 1; i <= 10; i++) {
        store.updateLastSeq(employeeId, i * 10);
      }

      expect(store.getLastSeq(employeeId), equals(100));
    });

    test('乱序更新取最大值', () {
      store.updateLastSeq(employeeId, 30);
      store.updateLastSeq(employeeId, 10);
      store.updateLastSeq(employeeId, 50);
      store.updateLastSeq(employeeId, 20);
      store.updateLastSeq(employeeId, 40);

      expect(store.getLastSeq(employeeId), equals(50));
    });

    test('MAX 语义按 deviceId 隔离', () {
      store.updateLastSeq(employeeId, 100, deviceId: 'devA');
      store.updateLastSeq(employeeId, 50, deviceId: 'devA');
      store.updateLastSeq(employeeId, 200, deviceId: 'devB');

      expect(store.getLastSeq(employeeId, deviceId: 'devA'), equals(100));
      expect(store.getLastSeq(employeeId, deviceId: 'devB'), equals(200));
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. resetLastSeq 强制重置
  // ═══════════════════════════════════════════════════

  group('resetLastSeq - 强制重置', () {
    test('resetLastSeq 默认 enforceMax=true 不会降低水位线', () {
      store.updateLastSeq(employeeId, 100);
      expect(store.getLastSeq(employeeId), equals(100));

      // 默认 enforceMax=true，不会降低
      store.resetLastSeq(employeeId, 0);
      expect(store.getLastSeq(employeeId), equals(100));
    });

    test('resetLastSeq enforceMax=true 更大值会更新', () {
      store.updateLastSeq(employeeId, 100);
      store.resetLastSeq(employeeId, 200);

      expect(store.getLastSeq(employeeId), equals(200));
    });

    test('resetLastSeq enforceMax=false 可以降为更小值', () {
      store.updateLastSeq(employeeId, 100);
      expect(store.getLastSeq(employeeId), equals(100));

      store.resetLastSeq(employeeId, 0, enforceMax: false);
      expect(store.getLastSeq(employeeId), equals(0));
    });

    test('resetLastSeq enforceMax=false 设为 0 后可重新递增', () {
      store.updateLastSeq(employeeId, 100);
      store.resetLastSeq(employeeId, 0, enforceMax: false);
      store.updateLastSeq(employeeId, 10);

      expect(store.getLastSeq(employeeId), equals(10));
    });

    test('resetLastSeq enforceMax=false 设为任意值', () {
      store.updateLastSeq(employeeId, 200);
      store.resetLastSeq(employeeId, 50, enforceMax: false);

      expect(store.getLastSeq(employeeId), equals(50));
    });

    test('resetLastSeq 不存在的记录也能创建', () {
      store.resetLastSeq(employeeId, 0);

      expect(store.getLastSeq(employeeId), equals(0));
    });

    test('resetLastSeq 后 updateLastSeq 的 MAX 语义仍生效', () {
      store.updateLastSeq(employeeId, 100);
      store.resetLastSeq(employeeId, 0, enforceMax: false);
      store.updateLastSeq(employeeId, 50);

      // 50 > 0，所以更新
      expect(store.getLastSeq(employeeId), equals(50));

      // 但 30 < 50，不更新
      store.updateLastSeq(employeeId, 30);
      expect(store.getLastSeq(employeeId), equals(50));
    });

    test('resetLastSeq enforceMax 按 deviceId 隔离', () {
      store.updateLastSeq(employeeId, 100, deviceId: 'devA');
      store.updateLastSeq(employeeId, 200, deviceId: 'devB');

      // devA: 不会降低
      store.resetLastSeq(employeeId, 50, deviceId: 'devA');
      expect(store.getLastSeq(employeeId, deviceId: 'devA'), equals(100));

      // devB: 不会降低
      store.resetLastSeq(employeeId, 150, deviceId: 'devB');
      expect(store.getLastSeq(employeeId, deviceId: 'devB'), equals(200));
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. clearSeq 生命周期
  // ═══════════════════════════════════════════════════

  group('clearSeq 生命周期', () {
    test('初始状态 clearSeq 为 null', () {
      expect(store.getClearSeq(employeeId), isNull);
    });

    test('setClearSeq 设置值后可读取', () {
      store.setClearSeq(employeeId, 100);

      expect(store.getClearSeq(employeeId), equals(100));
    });

    test('setClearSeq 更大值会更新（MAX 语义）', () {
      store.setClearSeq(employeeId, 50);
      store.setClearSeq(employeeId, 100);

      expect(store.getClearSeq(employeeId), equals(100));
    });

    test('setClearSeq 更小值不会回退', () {
      store.setClearSeq(employeeId, 100);
      store.setClearSeq(employeeId, 50);

      expect(store.getClearSeq(employeeId), equals(100));
    });

    test('clearClearSeq 清除标记', () {
      store.setClearSeq(employeeId, 100);
      expect(store.getClearSeq(employeeId), equals(100));

      store.clearClearSeq(employeeId);
      expect(store.getClearSeq(employeeId), isNull);
    });

    test('clearClearSeq 不存在的记录不报错', () {
      // 不应抛异常
      store.clearClearSeq('non-existent');
    });

    test('clearClearSeq 后可重新设置', () {
      store.setClearSeq(employeeId, 100);
      store.clearClearSeq(employeeId);
      store.setClearSeq(employeeId, 200);

      expect(store.getClearSeq(employeeId), equals(200));
    });

    test('clearSeq 按 deviceId 隔离', () {
      store.setClearSeq(employeeId, 100, deviceId: 'devA');
      store.setClearSeq(employeeId, 200, deviceId: 'devB');

      expect(store.getClearSeq(employeeId, deviceId: 'devA'), equals(100));
      expect(store.getClearSeq(employeeId, deviceId: 'devB'), equals(200));
      expect(store.getClearSeq(employeeId), isNull); // 默认 deviceId=''
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. upsert 完整覆写
  // ═══════════════════════════════════════════════════

  group('upsert 完整覆写', () {
    test('upsert 覆写 updateLastSeq 设置的值', () {
      store.updateLastSeq(employeeId, 100);

      store.upsert(SyncWatermarkEntity(
        employeeId: employeeId,
        lastSeq: 50, // 比 100 小
        updateTime: DateTime.now(),
      ));

      // upsert 使用 INSERT OR REPLACE，直接覆写
      expect(store.getLastSeq(employeeId), equals(50));
    });

    test('upsert 保留 clearSeq', () {
      store.setClearSeq(employeeId, 100);

      store.upsert(SyncWatermarkEntity(
        employeeId: employeeId,
        lastSeq: 50,
        clearSeq: 100,
        updateTime: DateTime.now(),
      ));

      expect(store.getClearSeq(employeeId), equals(100));
    });

    test('upsert 清除 clearSeq（传 null）', () {
      store.setClearSeq(employeeId, 100);

      store.upsert(SyncWatermarkEntity(
        employeeId: employeeId,
        lastSeq: 50,
        clearSeq: null,
        updateTime: DateTime.now(),
      ));

      expect(store.getClearSeq(employeeId), isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 6. 综合场景
  // ═══════════════════════════════════════════════════

  group('综合场景', () {
    test('清空会话后重置水位线的完整流程', () {
      // 1. 正常同步消息，水位线递增
      store.updateLastSeq(employeeId, 100);
      store.updateLastSeq(employeeId, 200);
      expect(store.getLastSeq(employeeId), equals(200));

      // 2. 清空会话：设置 clearSeq + 重置 lastSeq 为 maxSeq（而非0）
      store.setClearSeq(employeeId, 200);
      store.resetLastSeq(employeeId, 200); // 清空后水位线 = maxSeq
      expect(store.getClearSeq(employeeId), equals(200));
      expect(store.getLastSeq(employeeId), equals(200));

      // 3. 客户端处理完清空后，清除 clearSeq
      store.clearClearSeq(employeeId);
      expect(store.getClearSeq(employeeId), isNull);

      // 4. 新消息到来（seq > 200），水位线继续递增
      store.updateLastSeq(employeeId, 210);
      store.updateLastSeq(employeeId, 220);
      expect(store.getLastSeq(employeeId), equals(220));
    });

    test('多设备水位线完全隔离', () {
      store.updateLastSeq(employeeId, 100, deviceId: 'devA');
      store.updateLastSeq(employeeId, 200, deviceId: 'devB');
      store.setClearSeq(employeeId, 50, deviceId: 'devA');

      // devA: lastSeq=100, clearSeq=50
      expect(store.getLastSeq(employeeId, deviceId: 'devA'), equals(100));
      expect(store.getClearSeq(employeeId, deviceId: 'devA'), equals(50));

      // devB: lastSeq=200, clearSeq=null
      expect(store.getLastSeq(employeeId, deviceId: 'devB'), equals(200));
      expect(store.getClearSeq(employeeId, deviceId: 'devB'), isNull);

      // 重置 devA 不影响 devB（使用 enforceMax: false 模拟旧行为）
      store.resetLastSeq(employeeId, 0, deviceId: 'devA', enforceMax: false);
      expect(store.getLastSeq(employeeId, deviceId: 'devA'), equals(0));
      expect(store.getLastSeq(employeeId, deviceId: 'devB'), equals(200));
    });
  });
}
