import '../../persistence/persistence.dart';
import '../../utils/logger.dart';

/// 设备配置管理器
///
/// 负责设备配置的 CRUD 操作。
class DeviceConfigManager {
  static final _log = Logger('DeviceConfigManager');

  final DeviceConfigStore _deviceConfigStore;
  final String _deviceId;

  DeviceConfigManager._({required String deviceId, required DeviceConfigStore deviceConfigStore})
      : _deviceId = deviceId,
        _deviceConfigStore = deviceConfigStore;

  // ===== 单例管理 =====

  static final Map<String, DeviceConfigManager> _instances = {};

  static DeviceConfigManager getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceConfigManager._(
        deviceId: deviceId,
        deviceConfigStore: DeviceConfigStore(deviceId: deviceId),
      ),
    );
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 公开方法 =====

  /// 获取设备配置
  Future<DeviceConfigEntity> getDeviceConfig() async =>
      await _deviceConfigStore.getOrCreate(_deviceId);

  /// 更新设备信息配置
  Future<void> updateDeviceInfo(DeviceInfoConfig deviceInfo) async {
    try {
      final existing = await _deviceConfigStore.find(_deviceId);
      if (existing != null) {
        await _deviceConfigStore.updateDeviceInfo(
          _deviceId,
          existing.deviceInfo.copyWith(
            name: deviceInfo.name,
            type: deviceInfo.type,
            description: deviceInfo.description,
            icon: deviceInfo.icon,
            os: deviceInfo.os,
            osVersion: deviceInfo.osVersion,
            appVersion: deviceInfo.appVersion,
            model: deviceInfo.model,
            manufacturer: deviceInfo.manufacturer,
            tags: deviceInfo.tags.isNotEmpty ? deviceInfo.tags : null,
            metadata: deviceInfo.metadata.isNotEmpty
                ? deviceInfo.metadata
                : null,
          ),
        );
      } else {
        await _deviceConfigStore.updateDeviceInfo(_deviceId, deviceInfo);
      }
    } catch (e) {
      _log.debug('updateDeviceInfo with merge failed, using direct update: $e');
      await _deviceConfigStore.updateDeviceInfo(_deviceId, deviceInfo);
    }
  }

  /// 更新环境变量
  Future<void> updateEnvironmentVariables(Map<String, String> vars) async =>
      _deviceConfigStore.updateEnvironmentVariables(_deviceId, vars);

  /// 设置单个环境变量
  Future<void> setEnvironmentVariable(String key, String value) async =>
      _deviceConfigStore.setEnvironmentVariable(_deviceId, key, value);

  /// 删除单个环境变量
  Future<void> deleteEnvironmentVariable(String key) async =>
      _deviceConfigStore.deleteEnvironmentVariable(_deviceId, key);
}
