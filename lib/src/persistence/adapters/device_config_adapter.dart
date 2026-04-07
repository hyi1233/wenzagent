import 'dart:convert';

import 'package:hive/hive.dart';

import '../entities/device_config_entity.dart';

/// 设备配置实体适配器
class DeviceConfigAdapter extends TypeAdapter<DeviceConfigEntity> {
  @override
  final int typeId = 104;

  @override
  DeviceConfigEntity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    // 解析 deviceInfo
    DeviceInfoConfig deviceInfo = DeviceInfoConfig();
    if (fields[1] != null) {
      try {
        final deviceInfoStr = fields[1] as String;
        if (deviceInfoStr.isNotEmpty) {
          final deviceInfoMap = jsonDecode(deviceInfoStr) as Map<String, dynamic>;
          deviceInfo = DeviceInfoConfig.fromMap(deviceInfoMap);
        }
      } catch (_) {
        // 忽略解析错误
      }
    }

    // 解析 environmentVariables
    Map<String, String> environmentVariables = {};
    if (fields[2] != null) {
      try {
        final envStr = fields[2] as String;
        if (envStr.isNotEmpty) {
          final envMap = jsonDecode(envStr) as Map<String, dynamic>;
          environmentVariables = Map<String, String>.from(envMap);
        }
      } catch (_) {
        // 忽略解析错误
      }
    }

    return DeviceConfigEntity(
      deviceId: fields[0] as String,
      deviceInfo: deviceInfo,
      environmentVariables: environmentVariables,
      createTime: fields[3] is DateTime
          ? fields[3] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[3] as int? ?? 0),
      updateTime: fields[4] is DateTime
          ? fields[4] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[4] as int? ?? 0),
    );
  }

  @override
  void write(BinaryWriter writer, DeviceConfigEntity obj) {
    // 序列化 deviceInfo
    final deviceInfoStr = jsonEncode(obj.deviceInfo.toMap());

    // 序列化 environmentVariables
    final envStr = jsonEncode(obj.environmentVariables);

    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.deviceId)
      ..writeByte(1)
      ..write(deviceInfoStr)
      ..writeByte(2)
      ..write(envStr)
      ..writeByte(3)
      ..write(obj.createTime.millisecondsSinceEpoch)
      ..writeByte(4)
      ..write(obj.updateTime.millisecondsSinceEpoch);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
