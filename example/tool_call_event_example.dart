/// 工具调用事件处理示例
/// 
/// 本示例展示如何在远程模式下正确处理工具调用事件，
/// 确保界面能够实时显示工具调用的进度和结果。

import 'package:wenzagent/wenzagent.dart';

/// 示例：远程工具调用事件监听
class RemoteToolCallExample {
  final DeviceClient deviceClient;
  
  RemoteToolCallExample({required this.deviceClient});
  
  /// 监听远程Agent的工具调用事件
  void setupToolCallListener(String employeeId) {
    // 监听所有Agent事件
    deviceClient.onAgentEvent.listen((event) {
      final type = event['type'] as String?;
      final eventEmployeeId = event['employeeId'] as String?;
      
      // 过滤出特定员工的事件
      if (eventEmployeeId != employeeId) return;
      
      switch (type) {
        case 'toolCallStart':
          _handleToolCallStart(event['data'] as Map<String, dynamic>?);
        case 'toolCallResult':
          _handleToolCallResult(event['data'] as Map<String, dynamic>?);
        case 'agentStatusChanged':
          print('Agent状态变更: ${event['data']}');
        case 'messageStatusChanged':
          print('消息状态变更: ${event['data']}');
      }
    });
  }
  
  /// 处理工具调用开始事件
  void _handleToolCallStart(Map<String, dynamic>? data) {
    if (data == null) return;
    
    final toolCallId = data['toolCallId'] as String?;
    final name = data['name'] as String?;
    final arguments = data['arguments'] as String?;
    
    print('🔧 工具调用开始:');
    print('  - ID: $toolCallId');
    print('  - 工具名: $name');
    print('  - 参数: $arguments');
    print('  - 状态: 执行中...');
    
    // 在实际应用中，这里可以更新UI，显示加载状态
  }
  
  /// 处理工具调用结果事件
  void _handleToolCallResult(Map<String, dynamic>? data) {
    if (data == null) return;
    
    final toolCallId = data['toolCallId'] as String?;
    final name = data['name'] as String?;
    final result = data['result'] as String?;
    final isError = data['isError'] as bool? ?? false;
    
    print('✅ 工具调用完成:');
    print('  - ID: $toolCallId');
    print('  - 工具名: $name');
    print('  - 结果: $result');
    print('  - 是否错误: $isError');
    
    // 在实际应用中，这里可以更新UI，显示结果
  }
  
  /// 完整示例：创建远程会话并发送消息
  Future<void> createRemoteSessionAndChat() async {
    try {
      // 1. 连接到服务器
      await deviceClient.connect();
      print('✅ 已连接到服务器');
      
      // 2. 获取或创建远程Agent
      const employeeId = 'employee-123';
      const remoteDeviceId = 'device-remote';
      
      final proxy = await deviceClient.getOrCreateAgentProxy(
        employeeId: employeeId,
        deviceId: remoteDeviceId,
      );
      
      print('✅ 已创建远程Agent代理: ${proxy.employeeId}');
      
      // 3. 设置事件监听器
      setupToolCallListener(employeeId);
      
      // 4. 发送消息并监听响应流
      final input = MessageInput(
        content: '请帮我搜索关于Dart语言的信息',
      );
      
      print('📤 发送消息: ${input.content}');
      
      await for (final response in proxy.sendMessage(input)) {
        // 处理流式响应
        switch (response.type) {
          case StreamResponseType.chunk:
            // 文本块
            stdout.write(response.content);
          case StreamResponseType.toolCallStart:
            // 工具调用开始（也会通过onAgentEvent接收）
            final data = response.data;
            print('\n🔧 [流式] 工具调用开始: ${data?['name']}');
          case StreamResponseType.toolCallResult:
            // 工具调用结果（也会通过onAgentEvent接收）
            final data = response.data;
            print('\n✅ [流式] 工具调用结果: ${data?['name']}');
          case StreamResponseType.done:
            print('\n✅ 消息完成');
          case StreamResponseType.error:
            print('\n❌ 错误: ${response.error}');
        }
      }
      
    } catch (e) {
      print('❌ 错误: $e');
    }
  }
}

/// 示例：界面组件如何处理工具调用事件
class ToolCallUIHandler {
  /// 工具调用状态
  final Map<String, ToolCallState> _toolCallStates = {};
  
  /// 处理Agent事件（用于UI更新）
  void handleAgentEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final data = event['data'] as Map<String, dynamic>?;
    
    switch (type) {
      case 'toolCallStart':
        _onToolCallStart(data);
      case 'toolCallResult':
        _onToolCallResult(data);
    }
  }
  
  void _onToolCallStart(Map<String, dynamic>? data) {
    if (data == null) return;
    
    final toolCallId = data['toolCallId'] as String? ?? '';
    final name = data['name'] as String? ?? 'Unknown';
    final arguments = data['arguments'] as String?;
    
    // 更新工具调用状态
    _toolCallStates[toolCallId] = ToolCallState(
      id: toolCallId,
      name: name,
      arguments: arguments,
      status: ToolCallStatus.running,
      startTime: DateTime.now(),
    );
    
    // 触发UI更新（在实际应用中使用setState或状态管理）
    print('UI更新: 显示工具调用 $name (运行中)');
  }
  
  void _onToolCallResult(Map<String, dynamic>? data) {
    if (data == null) return;
    
    final toolCallId = data['toolCallId'] as String? ?? '';
    final result = data['result'] as String?;
    final isError = data['isError'] as bool? ?? false;
    
    // 更新工具调用状态
    final existingState = _toolCallStates[toolCallId];
    if (existingState != null) {
      _toolCallStates[toolCallId] = existingState.copyWith(
        result: result,
        status: isError ? ToolCallStatus.error : ToolCallStatus.success,
        endTime: DateTime.now(),
      );
      
      // 触发UI更新
      print('UI更新: 工具调用 ${existingState.name} 完成 (${isError ? "失败" : "成功"})');
    }
  }
  
  /// 获取所有运行中的工具调用
  List<ToolCallState> getRunningToolCalls() {
    return _toolCallStates.values
        .where((state) => state.status == ToolCallStatus.running)
        .toList();
  }
  
  /// 获取所有工具调用历史
  List<ToolCallState> getAllToolCalls() {
    return _toolCallStates.values.toList();
  }
}

/// 工具调用状态
class ToolCallState {
  final String id;
  final String name;
  final String? arguments;
  final String? result;
  final ToolCallStatus status;
  final DateTime startTime;
  final DateTime? endTime;
  
  ToolCallState({
    required this.id,
    required this.name,
    this.arguments,
    this.result,
    required this.status,
    required this.startTime,
    this.endTime,
  });
  
  ToolCallState copyWith({
    String? id,
    String? name,
    String? arguments,
    String? result,
    ToolCallStatus? status,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return ToolCallState(
      id: id ?? this.id,
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
      result: result ?? this.result,
      status: status ?? this.status,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }
  
  Duration? get duration {
    if (endTime != null) {
      return endTime!.difference(startTime);
    }
    return null;
  }
}

/// 工具调用状态枚举
enum ToolCallStatus {
  running,
  success,
  error,
}

/// 使用示例
void main() async {
  // 创建DeviceClient
  final deviceClient = DeviceClient(
    deviceId: 'device-local',
    host: 'localhost',
    port: 9090,
  );
  
  // 创建示例实例
  final example = RemoteToolCallExample(deviceClient: deviceClient);
  
  // 运行完整示例
  await example.createRemoteSessionAndChat();
  
  // 清理
  await deviceClient.dispose();
}
