import 'dart:convert';

import 'package:hive/hive.dart';

import '../entities/session_entity.dart';

/// AI员工会话实体适配器
class AiEmployeeSessionAdapter extends TypeAdapter<AiEmployeeSessionEntity> {
  @override
  final int typeId = 101;

  @override
  AiEmployeeSessionEntity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    // 解析config字段
    Map<String, DeviceSessionConfig> config = {};
    if (fields[4] != null) {
      final configStr = fields[4] as String;
      if (configStr.isNotEmpty) {
        try {
          final configMap = jsonDecode(configStr) as Map<String, dynamic>;
          config = configMap.map((key, value) {
            return MapEntry(
              key,
              DeviceSessionConfig.fromMap(value as Map<String, dynamic>),
            );
          });
        } catch (_) {
          // 忽略解析错误
        }
      }
    }

    return AiEmployeeSessionEntity(
      employeeId: fields[0] as String,
      title: fields[1] as String? ?? '新对话',
      config: config,
      isArchived: fields[5] as int? ?? 0,
      isPinned: fields[6] as int? ?? 0,
      deleted: fields[7] as int? ?? 0,
      createTime: fields[8] is DateTime
          ? fields[8] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[8] as int? ?? 0),
      updateTime: fields[9] is DateTime
          ? fields[9] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[9] as int? ?? 0),
    );
  }

  @override
  void write(BinaryWriter writer, AiEmployeeSessionEntity obj) {
    // 序列化config
    final configMap = obj.config.map(
      (key, value) => MapEntry(key, value.toMap()),
    );
    final configStr = jsonEncode(configMap);

    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.employeeId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(null) // reserved for future use
      ..writeByte(3)
      ..write(null) // reserved for future use
      ..writeByte(4)
      ..write(configStr)
      ..writeByte(5)
      ..write(obj.isArchived)
      ..writeByte(6)
      ..write(obj.isPinned)
      ..writeByte(7)
      ..write(obj.deleted)
      ..writeByte(8)
      ..write(obj.createTime.millisecondsSinceEpoch)
      ..writeByte(9)
      ..write(obj.updateTime.millisecondsSinceEpoch);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiEmployeeSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
