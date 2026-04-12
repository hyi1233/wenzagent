import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/sync_watermark_entity.dart';

/// 同步水位线数据存储
class SyncWatermarkStore {
  final DatabaseManager _dbManager;

  SyncWatermarkStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db => _dbManager.db;

  /// 获取指定 employee 的水位线
  SyncWatermarkEntity? getWatermark(String employeeId) {
    final resultSet = _db.select(
      'SELECT * FROM sync_watermark WHERE employee_id = ?',
      [employeeId],
    );
    for (final row in resultSet) {
      return SyncWatermarkEntity.fromMap({
        'employeeId': row['employee_id'] as String,
        'lastSeq': row['last_seq'] as int,
        'updateTime': row['update_time'] as int,
      });
    }
    return null;
  }

  /// 获取指定 employee 的 last_seq，不存在返回 0
  int getLastSeq(String employeeId) {
    final watermark = getWatermark(employeeId);
    return watermark?.lastSeq ?? 0;
  }

  /// 更新或插入水位线
  void upsert(SyncWatermarkEntity entity) {
    _db.execute('''
      INSERT OR REPLACE INTO sync_watermark (employee_id, last_seq, update_time)
        VALUES (?, ?, ?)
    ''', [
      entity.employeeId,
      entity.lastSeq,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 更新指定 employee 的 last_seq
  ///
  /// 使用 MAX 语义：只在 lastSeq 大于当前值时才更新，
  /// 防止推送和拉取并发时水位线回退。
  void updateLastSeq(String employeeId, int lastSeq) {
    _db.execute('''
      INSERT INTO sync_watermark (employee_id, last_seq, update_time)
        VALUES (?, ?, ?)
        ON CONFLICT(employee_id) DO UPDATE SET
          last_seq = MAX(last_seq, excluded.last_seq),
          update_time = excluded.update_time
    ''', [
      employeeId,
      lastSeq,
      DateTime.now().millisecondsSinceEpoch,
    ]);
  }
}
