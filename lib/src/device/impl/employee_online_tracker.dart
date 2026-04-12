import '../../service/service.dart';
import '../device_client.dart';
import 'device_agent_manager.dart';
import 'device_registry.dart';
import 'device_state_holder.dart';

/// 员工在线状态追踪器
///
/// 负责维护员工在线状态缓存并发布变化事件。
class EmployeeOnlineTracker {
  final String _deviceId;
  late final EmployeeManager _employeeManager = EmployeeManager.getInstance(_deviceId);
  late final DeviceAgentManager _agentManager = DeviceAgentManager.getInstance(_deviceId);
  late final DeviceRegistry _deviceRegistry = DeviceRegistry.getInstance(_deviceId);
  late final DeviceStateHolder _stateHolder = DeviceStateHolder.getInstance(_deviceId);

  final Map<String, bool> _employeeOnlineState = {};
  final Map<String, String> _employeeDeviceMap = {};

  EmployeeOnlineTracker._({required String deviceId}) : _deviceId = deviceId;

  // ===== 单例管理 =====

  static final Map<String, EmployeeOnlineTracker> _instances = {};

  static EmployeeOnlineTracker getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => EmployeeOnlineTracker._(deviceId: deviceId),
    );
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 公开访问 =====

  bool? isEmployeeOnline(String employeeId) => _employeeOnlineState[employeeId];

  /// 刷新所有员工的在线状态（含远程设备上的员工）
  void refreshEmployeeOnlineStates() {
    () async {
      try {
        final employees = await _employeeManager.getEmployees(allDevices: true);
        for (final employee in employees) {
          final devId = employee.currentDeviceId;
          if (devId != null && devId.isNotEmpty) {
            _employeeDeviceMap[employee.uuid] = devId;
          }
          bool online = false;
          if (devId != null && devId.isNotEmpty) {
            online = devId == _deviceId
                ? (_agentManager.getLocalAgent(employee.uuid)?.isAlive ?? false)
                : _deviceRegistry.containsDevice(devId);
          }
          _updateEmployeeOnlineState(employee.uuid, online, devId);
        }
      } catch (_) {}
    }();
  }

  /// 将指定设备的所有员工标记为离线
  void markDeviceEmployeesOffline(String offlineDeviceId) {
    if (offlineDeviceId == _deviceId) return;
    for (final e in Map<String, bool>.from(_employeeOnlineState).entries) {
      if (e.value && _employeeDeviceMap[e.key] == offlineDeviceId) {
        _employeeOnlineState[e.key] = false;
        _stateHolder.employeeOnlineController.add(EmployeeOnlineEvent(
          employeeId: e.key,
          isOnline: false,
          deviceId: offlineDeviceId,
        ));
      }
    }
  }

  /// 将所有远程员工标记为离线（基于完整员工列表，确保远程员工也被覆盖）
  void markAllRemoteEmployeesOffline() {
    () async {
      try {
        final employees = await _employeeManager.getEmployees(allDevices: true);
        for (final employee in employees) {
          final devId = employee.currentDeviceId;
          // 跳过本设备的员工
          if (devId == _deviceId) continue;
          final online = _employeeOnlineState[employee.uuid] ?? false;
          if (online) {
            _employeeOnlineState[employee.uuid] = false;
            _stateHolder.employeeOnlineController.add(
              EmployeeOnlineEvent(employeeId: employee.uuid, isOnline: false),
            );
          }
        }
      } catch (_) {}
    }();
  }

  void _updateEmployeeOnlineState(String empId, bool isOnline, String? devId) {
    if (_employeeOnlineState[empId] != isOnline) {
      _employeeOnlineState[empId] = isOnline;
      _stateHolder.employeeOnlineController.add(EmployeeOnlineEvent(
        employeeId: empId,
        isOnline: isOnline,
        deviceId: devId,
      ));
    }
  }
}
