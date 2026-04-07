import 'dart:io';

import 'package:test/test.dart';

import 'package:wenzagent/src/persistence/entities/device_config_entity.dart';
import 'package:wenzagent/src/persistence/hive_manager.dart';
import 'package:wenzagent/src/persistence/stores/device_config_store.dart';
import 'package:wenzagent/src/device/device_client.dart';
import 'package:wenzagent/src/device/impl/device_client_impl.dart';

/// 设备配置功能测试
///
/// 测试场景：
/// 1. DeviceConfigEntity 的创建和序列化
/// 2. DeviceConfigStore 的存储和查询
/// 3. DeviceClient 的设备配置 API
void main() {
  group('设备配置实体测试', () {
    test('创建默认设备信息配置', () {
      final deviceInfo = DeviceInfoConfig();

      expect(deviceInfo.name, isNull);
      expect(deviceInfo.type, isNull);
      expect(deviceInfo.description, isNull);
      expect(deviceInfo.tags, isEmpty);
      expect(deviceInfo.metadata, isEmpty);
    });

    test('创建完整设备信息配置', () {
      final deviceInfo = DeviceInfoConfig(
        name: '测试设备',
        type: 'desktop',
        description: '这是一个测试设备',
        icon: 'desktop_icon',
        os: 'Windows',
        osVersion: '11',
        appVersion: '1.0.0',
        model: 'Dell XPS 15',
        manufacturer: 'Dell',
        tags: ['development', 'test'],
        metadata: {'location': 'office', 'user': 'developer'},
      );

      expect(deviceInfo.name, equals('测试设备'));
      expect(deviceInfo.type, equals('desktop'));
      expect(deviceInfo.os, equals('Windows'));
      expect(deviceInfo.tags, containsAll(['development', 'test']));
      expect(deviceInfo.metadata['location'], equals('office'));
    });

    test('DeviceInfoConfig 序列化和反序列化', () {
      final original = DeviceInfoConfig(
        name: '我的设备',
        type: 'mobile',
        os: 'Android',
        osVersion: '13',
        tags: ['production'],
        metadata: {'key': 'value'},
      );

      final map = original.toMap();
      final restored = DeviceInfoConfig.fromMap(map);

      expect(restored.name, equals(original.name));
      expect(restored.type, equals(original.type));
      expect(restored.os, equals(original.os));
      expect(restored.tags, equals(original.tags));
      expect(restored.metadata, equals(original.metadata));
    });

    test('创建设备配置实体', () {
      final now = DateTime.now();
      final config = DeviceConfigEntity(
        deviceId: 'device-001',
        createTime: now,
        updateTime: now,
      );

      expect(config.deviceId, equals('device-001'));
      expect(config.environmentVariables, isEmpty);
      expect(config.deviceInfo, isNotNull);
    });

    test('DeviceConfigEntity 序列化和反序列化', () {
      final now = DateTime.now();
      final original = DeviceConfigEntity(
        deviceId: 'device-002',
        deviceInfo: DeviceInfoConfig(
          name: '开发机',
          type: 'desktop',
          os: 'macOS',
        ),
        environmentVariables: {
          'API_URL': 'https://api.example.com',
          'DEBUG_MODE': 'true',
        },
        createTime: now,
        updateTime: now,
      );

      final map = original.toMap();
      final restored = DeviceConfigEntity.fromMap(map);

      expect(restored.deviceId, equals(original.deviceId));
      expect(restored.deviceInfo.name, equals('开发机'));
      expect(restored.deviceInfo.os, equals('macOS'));
      expect(restored.environmentVariables['API_URL'], equals('https://api.example.com'));
      expect(restored.environmentVariables['DEBUG_MODE'], equals('true'));
    });

    test('DeviceConfigEntity copyWith', () {
      final original = DeviceConfigEntity(
        deviceId: 'device-003',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final updated = original.copyWith(
        deviceInfo: DeviceInfoConfig(name: '新名称'),
      );

      expect(updated.deviceId, equals(original.deviceId));
      expect(updated.deviceInfo.name, equals('新名称'));
      expect(updated.createTime, equals(original.createTime));
    });
  });

  group('设备配置存储测试', () {
    late DeviceConfigStore store;
    late String testPath;

    setUpAll(() async {
      // 创建临时测试目录
      testPath = '${Directory.systemTemp.path}/wenzagent_test_${DateTime.now().millisecondsSinceEpoch}';
      await Directory(testPath).create(recursive: true);

      // 初始化 Hive
      await HiveManager.instance.initialize(storagePath: testPath);
    });

    tearDownAll(() async {
      // 关闭 Hive
      await HiveManager.instance.close();

      // 清理测试目录
      try {
        await Directory(testPath).delete(recursive: true);
      } catch (_) {}
    });

    setUp(() {
      store = DeviceConfigStore();
    });

    test('创建和获取设备配置', () async {
      final config = await store.getOrCreate('device-test-001');

      expect(config, isNotNull);
      expect(config.deviceId, equals('device-test-001'));
      expect(config.deviceInfo, isNotNull);
      expect(config.environmentVariables, isEmpty);
    });

    test('重复获取返回相同配置', () async {
      final config1 = await store.getOrCreate('device-test-002');
      config1.deviceInfo.name = '测试设备';
      await store.save(config1);

      final config2 = await store.getOrCreate('device-test-002');

      expect(config2.deviceId, equals('device-test-002'));
      expect(config2.deviceInfo.name, equals('测试设备'));
    });

    test('更新设备信息', () async {
      final deviceInfo = DeviceInfoConfig(
        name: '更新后的设备',
        type: 'server',
        os: 'Linux',
        tags: ['production', 'main'],
      );

      await store.updateDeviceInfo('device-test-003', deviceInfo);

      final config = await store.find('device-test-003');
      expect(config, isNotNull);
      expect(config!.deviceInfo.name, equals('更新后的设备'));
      expect(config.deviceInfo.type, equals('server'));
      expect(config.deviceInfo.tags, containsAll(['production', 'main']));
    });

    test('更新环境变量', () async {
      final envVars = {
        'API_URL': 'https://test.example.com',
        'LOG_LEVEL': 'debug',
      };

      await store.updateEnvironmentVariables('device-test-004', envVars);

      final config = await store.find('device-test-004');
      expect(config, isNotNull);
      expect(config!.environmentVariables['API_URL'], equals('https://test.example.com'));
      expect(config.environmentVariables['LOG_LEVEL'], equals('debug'));
    });

    test('设置单个环境变量', () async {
      await store.setEnvironmentVariable('device-test-005', 'NEW_VAR', 'new_value');

      final config = await store.find('device-test-005');
      expect(config, isNotNull);
      expect(config!.environmentVariables['NEW_VAR'], equals('new_value'));
    });

    test('删除单个环境变量', () async {
      // 先设置环境变量
      await store.updateEnvironmentVariables('device-test-006', {
        'VAR1': 'value1',
        'VAR2': 'value2',
      });

      // 删除一个
      await store.deleteEnvironmentVariable('device-test-006', 'VAR1');

      final config = await store.find('device-test-006');
      expect(config, isNotNull);
      expect(config!.environmentVariables.containsKey('VAR1'), isFalse);
      expect(config.environmentVariables['VAR2'], equals('value2'));
    });

    test('获取所有设备配置', () async {
      // 创建多个设备配置
      await store.getOrCreate('device-test-all-001');
      await store.getOrCreate('device-test-all-002');
      await store.getOrCreate('device-test-all-003');

      final configs = await store.findAll();
      expect(configs.length, greaterThanOrEqualTo(3));
    });

    test('删除设备配置', () async {
      await store.getOrCreate('device-test-delete');
      
      var config = await store.find('device-test-delete');
      expect(config, isNotNull);

      await store.delete('device-test-delete');
      
      config = await store.find('device-test-delete');
      expect(config, isNull);
    });
  });

  group('DeviceClient 设备配置集成测试', () {
    late DeviceClient deviceClient;
    late String testPath;

    setUpAll(() async {
      // 创建临时测试目录
      testPath = '${Directory.systemTemp.path}/wenzagent_device_test_${DateTime.now().millisecondsSinceEpoch}';
      await Directory(testPath).create(recursive: true);

      // 初始化 Hive
      await HiveManager.instance.initialize(storagePath: testPath);
    });

    tearDownAll(() async {
      // 关闭 Hive
      await HiveManager.instance.close();

      // 清理测试目录
      try {
        await Directory(testPath).delete(recursive: true);
      } catch (_) {}
    });

    setUp(() {
      deviceClient = DeviceClientImpl(
        deviceId: 'test-device-001',
        deviceName: '测试设备',
        host: 'localhost',
        port: 9090,
      );
    });

    tearDown(() async {
      await deviceClient.dispose();
    });

    test('获取设备配置', () async {
      final config = await deviceClient.getDeviceConfig();

      expect(config, isNotNull);
      expect(config.deviceId, equals('test-device-001'));
    });

    test('更新设备信息', () async {
      final deviceInfo = DeviceInfoConfig(
        name: '集成测试设备',
        type: 'desktop',
        os: 'Windows',
        osVersion: '11',
        appVersion: '2.0.0',
        tags: ['test', 'integration'],
      );

      await deviceClient.updateDeviceInfo(deviceInfo);

      final config = await deviceClient.getDeviceConfig();
      expect(config.deviceInfo.name, equals('集成测试设备'));
      expect(config.deviceInfo.type, equals('desktop'));
      expect(config.deviceInfo.tags, containsAll(['test', 'integration']));
    });

    test('批量更新环境变量', () async {
      final envVars = {
        'DATABASE_URL': 'postgresql://localhost:5432/test',
        'REDIS_URL': 'redis://localhost:6379',
        'MAX_CONNECTIONS': '50',
      };

      await deviceClient.updateEnvironmentVariables(envVars);

      final config = await deviceClient.getDeviceConfig();
      expect(config.environmentVariables['DATABASE_URL'], equals('postgresql://localhost:5432/test'));
      expect(config.environmentVariables['REDIS_URL'], equals('redis://localhost:6379'));
      expect(config.environmentVariables['MAX_CONNECTIONS'], equals('50'));
    });

    test('设置单个环境变量', () async {
      await deviceClient.setEnvironmentVariable('NEW_API_KEY', 'test-key-12345');

      final config = await deviceClient.getDeviceConfig();
      expect(config.environmentVariables['NEW_API_KEY'], equals('test-key-12345'));
    });

    test('删除单个环境变量', () async {
      // 先设置环境变量
      await deviceClient.setEnvironmentVariable('TEMP_VAR', 'temp_value');

      // 删除
      await deviceClient.deleteEnvironmentVariable('TEMP_VAR');

      final config = await deviceClient.getDeviceConfig();
      expect(config.environmentVariables.containsKey('TEMP_VAR'), isFalse);
    });

    test('完整流程测试', () async {
      // 1. 获取初始配置
      var config = await deviceClient.getDeviceConfig();
      expect(config.deviceId, equals('test-device-001'));

      // 2. 更新设备信息
      await deviceClient.updateDeviceInfo(DeviceInfoConfig(
        name: '完整测试设备',
        type: 'server',
        os: 'Ubuntu',
        osVersion: '22.04',
      ));

      // 3. 设置环境变量
      await deviceClient.updateEnvironmentVariables({
        'APP_ENV': 'production',
        'LOG_LEVEL': 'info',
      });

      await deviceClient.setEnvironmentVariable('API_TIMEOUT', '30');

      // 4. 验证配置
      config = await deviceClient.getDeviceConfig();
      expect(config.deviceInfo.name, equals('完整测试设备'));
      expect(config.deviceInfo.type, equals('server'));
      expect(config.environmentVariables['APP_ENV'], equals('production'));
      expect(config.environmentVariables['LOG_LEVEL'], equals('info'));
      expect(config.environmentVariables['API_TIMEOUT'], equals('30'));

      // 5. 删除环境变量
      await deviceClient.deleteEnvironmentVariable('LOG_LEVEL');

      config = await deviceClient.getDeviceConfig();
      expect(config.environmentVariables.containsKey('LOG_LEVEL'), isFalse);
      expect(config.environmentVariables['APP_ENV'], equals('production'));

      print('\n========== 完整流程测试通过 ==========');
      print('设备ID: ${config.deviceId}');
      print('设备名称: ${config.deviceInfo.name}');
      print('设备类型: ${config.deviceInfo.type}');
      print('操作系统: ${config.deviceInfo.os}');
      print('环境变量:');
      config.environmentVariables.forEach((key, value) {
        print('  $key: $value');
      });
    });
  });
}
