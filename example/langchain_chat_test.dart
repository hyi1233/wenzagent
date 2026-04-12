import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// LLM ChatAdapter 使用示例
///
/// 运行前请设置环境变量:
/// ```
/// export OPENAI_API_KEY=sk-xxx
/// export OPENAI_API_URL=https://api.openai.com/v1  # 可选，用于代理或私有部署
/// ```
///
/// 然后运行:
/// ```
/// dart run example/langchain_chat_test.dart
/// ```
Future<void> main() async {
  print('================================================');
  print('  LangChain ChatAdapter 测试');
  print('================================================\n');

  // 检查 API Key
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    print('错误: 请设置环境变量 OPENAI_API_KEY');
    print('示例: export OPENAI_API_KEY=sk-xxx\n');
    exit(1);
  }

  // 可选：自定义 API URL（用于代理或私有部署）
  final apiUrl = Platform.environment['OPENAI_API_URL'];
  if (apiUrl != null && apiUrl.isNotEmpty) {
    print('使用自定义 API URL: $apiUrl\n');
  }

  try {
    // 1. 创建 LangChainChatAdapter
    print('【步骤1】创建 LlmChatAdapter...');
    final adapter = LlmChatAdapter();
    print('  ✓ Adapter 已创建\n');

    // 2. 配置 Provider (OpenAI)
    print('【步骤2】配置 OpenAI Provider...');
    final providerConfig = <String, dynamic>{
      'provider': 'openai',
      'model': 'mimo-v2-pro',  // 使用更便宜的模型
      'apiKey': apiKey,
      'options': {
        'temperature': 0.7,
        'maxTokens': 1000,
      },
    };
    
    // 如果设置了自定义 API URL
    if (apiUrl != null && apiUrl.isNotEmpty) {
      providerConfig['baseUrl'] = apiUrl;
    }
    
    await adapter.updateProvider(providerConfig);
    print('  ✓ Provider 已配置\n');

    // 3. 初始化会话
    print('【步骤3】初始化会话...');
    await adapter.initSession(employeeId: 'employee-test');
    print('  ✓ 会话已初始化: ${adapter.currentSessionUuid}\n');

    // 4. 设置系统提示词（可选）
    print('【步骤4】设置系统提示词...');
    adapter.setContext({
      'systemPrompt': '你是一个友好的助手，请用简洁的语言回答问题。',
    });
    print('  ✓ 系统提示词已设置\n');

    // 5. 发送消息并接收流式响应
    print('【步骤5】发送消息并接收流式响应...');
    print('  用户: 你好，请介绍一下你自己');
    print('  助手: ');

    await for (final response in adapter.streamMessage(
      MessageInput(content: '你好，请介绍一下你自己'),
    )) {
      if (response.error != null) {
        print('\n  错误: ${response.error}');
        break;
      }
      if (response.content != null) {
        stdout.write(response.content);
      }
      if (response.isDone) {
        print('\n  [完成]');
      }
    }
    print('');

    // 6. 查看当前会话消息
    print('【步骤6】查看当前会话消息...');
    final messages = adapter.currentMessages;
    print('  消息数: ${messages.length}');
    for (final msg in messages) {
      final role = msg['role'];
      final content = msg['content'] as String;
      final preview = content.length > 50 ? '${content.substring(0, 50)}...' : content;
      print('    [$role] $preview');
    }
    print('');

    // 7. 多轮对话
    print('【步骤7】多轮对话...');
    print('  用户: 你刚才说了什么？');
    print('  助手: ');

    await for (final response in adapter.streamMessage(
      MessageInput(content: '你刚才说了什么？'),
    )) {
      if (response.error != null) {
        print('\n  错误: ${response.error}');
        break;
      }
      if (response.content != null) {
        stdout.write(response.content);
      }
      if (response.isDone) {
        print('\n  [完成]');
      }
    }
    print('');

    // 8. 获取会话列表
    print('【步骤8】获取会话列表...');
    // TODO: getSessionsByEmployee 方法已移除
    // final sessions = await adapter.getSessionsByEmployee('employee-test');
    // print('  会话数: ${sessions.length}');
    // for (final session in sessions) {
    //   print('    - ${session['uuid']} (${session['messageCount']} 条消息)');
    // }
    print('  (方法已移除，跳过)');
    print('');

    // 9. 清理
    print('【步骤9】清理资源...');
    await adapter.dispose();
    print('  ✓ 资源已清理\n');

    print('================================================');
    print('  测试完成！');
    print('================================================\n');
  } catch (e, stackTrace) {
    print('错误: $e');
    print('堆栈: $stackTrace');
    exit(1);
  }
}
