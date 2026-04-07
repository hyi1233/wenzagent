# 设备配置使用指南

本文档介绍如何使用 DeviceClient 的设备信息配置和设备环境变量配置功能。

## 概述

设备配置功能允许您为每个设备存储和管理以下信息：

1. **设备信息配置**：设备名称、类型、描述、操作系统等元数据
2. **设备环境变量**：键值对形式的环境变量，可用于配置应用程序行为

## 数据模型

### DeviceConfigEntity

设备配置实体，包含以下字段：

```dart
class DeviceConfigEntity {
  final String deviceId;                    // 设备ID（主键）
  DeviceInfoConfig deviceInfo;              // 设备信息配置
  Map<String, String> environmentVariables; // 设备环境变量
  DateTime createTime;                      // 创建时间
  DateTime updateTime;                      // 更新时间
}
```

### DeviceInfoConfig

设备信息配置，包含以下字段：

```dart
class DeviceInfoConfig {
  String? name;              // 设备名称
  String? type;              // 设备类型（desktop, mobile, web, server等）
  String? description;       // 设备描述
  String? icon;              // 设备图标
  String? os;                // 操作系统
  String? osVersion;         // 操作系统版本
  String? appVersion;        // 应用版本
  String? model;             // 设备型号
  String? manufacturer;      // 制造商
  List<String> tags;         // 自定义标签
  Map<String, dynamic> metadata; // 自定义元数据
}
```

## API 使用示例

### 1. 获取设备配置

```dart
final deviceClient = DeviceClientImpl(
  deviceId: 'device-001',
  host: 'localhost',
  port: 9090,
);

// 获取设备配置（如果不存在会自动创建默认配置）
final config = await deviceClient.getDeviceConfig();
print('设备ID: ${config.deviceId}');
print('设备名称: ${config.deviceInfo.name}');
print('环境变量: ${config.environmentVariables}');
```

### 2. 更新设备信息

```dart
// 更新完整的设备信息
final deviceInfo = DeviceInfoConfig(
  name: '我的开发机',
  type: 'desktop',
  description: '用于开发的主要工作站',
  os: 'Windows',
  osVersion: '11',
  appVersion: '1.0.0',
  model: 'Dell XPS 15',
  manufacturer: 'Dell',
  tags: ['development', 'main'],
  metadata: {'location': 'office', 'user': 'developer'},
);

await deviceClient.updateDeviceInfo(deviceInfo);
```

### 3. 管理环境变量

#### 批量更新环境变量

```dart
// 批量设置多个环境变量
await deviceClient.updateEnvironmentVariables({
  'API_URL': 'https://api.example.com',
  'DEBUG_MODE': 'true',
  'MAX_CONNECTIONS': '100',
});
```

#### 设置单个环境变量

```dart
// 设置单个环境变量
await deviceClient.setEnvironmentVariable('API_KEY', 'your-api-key');
await deviceClient.setEnvironmentVariable('LOG_LEVEL', 'debug');
```

#### 删除环境变量

```dart
// 删除单个环境变量
await deviceClient.deleteEnvironmentVariable('DEBUG_MODE');
```

### 4. 读取和使用环境变量

```dart
final config = await deviceClient.getDeviceConfig();

// 获取环境变量
final apiUrl = config.environmentVariables['API_URL'];
final debugMode = config.environmentVariables['DEBUG_MODE'] == 'true';

if (debugMode) {
  print('调试模式已启用');
  print('API URL: $apiUrl');
}
```

## 完整示例

以下是一个完整的使用示例，展示如何在应用程序中使用设备配置：

```dart
import 'package:wenzagent/wenzagent.dart';

Future<void> main() async {
  // 初始化持久化层
  await HiveManager.instance.initialize();
  
  // 创建设备客户端
  final deviceClient = DeviceClientImpl(
    deviceId: 'device-001',
    deviceName: '开发机',
    host: 'localhost',
    port: 9090,
  );
  
  // 配置设备信息
  await deviceClient.updateDeviceInfo(DeviceInfoConfig(
    name: '开发工作站',
    type: 'desktop',
    os: 'Windows',
    osVersion: '11',
    appVersion: '1.0.0',
    tags: ['development', 'primary'],
  ));
  
  // 设置环境变量
  await deviceClient.updateEnvironmentVariables({
    'API_URL': 'https://api.example.com',
    'DEBUG_MODE': 'true',
    'MAX_CONNECTIONS': '100',
  });
  
  // 读取配置
  final config = await deviceClient.getDeviceConfig();
  
  print('设备配置:');
  print('  名称: ${config.deviceInfo.name}');
  print('  类型: ${config.deviceInfo.type}');
  print('  操作系统: ${config.deviceInfo.os}');
  print('  环境变量:');
  config.environmentVariables.forEach((key, value) {
    print('    $key: $value');
  });
  
  // 连接到服务器
  await deviceClient.connect();
  
  // 使用配置...
  final apiUrl = config.environmentVariables['API_URL'];
  print('使用 API URL: $apiUrl');
  
  // 清理
  await deviceClient.dispose();
}
```

## 最佳实践

1. **设备命名规范**：为设备设置有意义的名称，便于在多设备环境中识别。

2. **环境变量命名**：使用大写字母和下划线的命名方式（如 `API_URL`）。

3. **敏感信息**：不要在环境变量中存储敏感信息（如密码、密钥等），应使用安全的存储机制。

4. **标签使用**：使用标签对设备进行分类，便于筛选和管理。

5. **元数据扩展**：使用 `metadata` 字段存储自定义的设备信息，支持复杂的配置需求。

## 注意事项

1. 设备配置会自动持久化到本地存储，重启应用程序后会保留。

2. 每个设备（`deviceId`）对应唯一的配置，重复调用 `getDeviceConfig()` 会返回相同的配置对象。

3. 更新设备信息或环境变量会自动更新 `updateTime` 字段。

4. 删除不存在的环境变量不会抛出错误，而是静默忽略。

## 相关 API

- `getDeviceConfig()` - 获取设备配置
- `updateDeviceInfo(DeviceInfoConfig)` - 更新设备信息
- `updateEnvironmentVariables(Map<String, String>)` - 批量更新环境变量
- `setEnvironmentVariable(String, String)` - 设置单个环境变量
- `deleteEnvironmentVariable(String)` - 删除单个环境变量
