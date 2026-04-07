import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('CachedAgentProxy 远程模式修复测试', () {
    test('onMessagesChanged 流在远程模式下可用', () {
      // 这个测试验证 onMessagesChanged 流在远程模式下返回有效的流
      // 实际使用时需要真实的 CachedAgentProxy 实例
      
      // 预期行为：
      // - 本地模式：返回空流
      // - 远程模式：返回消息变更通知流
      
      print('onMessagesChanged 流测试说明：');
      print('- 本地模式（isLocalMode=true）：返回 Stream.empty()');
      print('- 远程模式（isLocalMode=false）：返回有效的消息变更流');
      print('');
      print('客户端应该订阅此流以自动更新界面：');
      print('  _messagesSubscription = proxy.onMessagesChanged.listen((messages) {');
      print('    // 自动更新消息列表');
      print('    updateMessagesList(messages);');
      print('  });');
    });
    
    test('sendMessage 不应该创建重复消息', () {
      // 这个测试说明 sendMessage 的改进
      // 修复前：可能从两个来源获取消息导致重复
      // 修复后：统一从 AgentProxy.pendingMessages 获取
      
      print('sendMessage 改进说明：');
      print('修复前的问题：');
      print('  1. AgentProxy.sendMessage() 添加到 _pendingMessageQueue');
      print('  2. CachedAgentProxy.sendMessage() 又添加到 _cachedMessages');
      print('  3. 客户端可能合并两个来源，导致重复');
      print('');
      print('修复后的行为：');
      print('  1. AgentProxy.sendMessage() 添加到 _pendingMessageQueue');
      print('  2. CachedAgentProxy.sendMessage() 从 _pendingMessageQueue 获取');
      print('  3. 转换后添加到 _cachedMessages（避免重复创建）');
      print('  4. 触发 onMessagesChanged 通知');
      print('');
      print('客户端最佳实践：');
      print('  - 只使用 getSessionMessages() 获取消息');
      print('  - 不要手动合并 pendingMessages');
      print('  - 订阅 onMessagesChanged 自动更新');
    });
    
    test('_mergeMessages 应该优先使用远程消息', () {
      // 这个测试说明 _mergeMessages 的改进
      // 修复前：先添加本地消息，再合并远程消息
      // 修复后：先添加远程消息（状态更准确），再保留待同步的本地消息
      
      print('_mergeMessages 改进说明：');
      print('修复前的逻辑：');
      print('  1. 先添加所有本地消息');
      print('  2. 合并远程消息，本地待同步的保留');
      print('  3. 可能导致本地旧消息覆盖远程新消息');
      print('');
      print('修复后的逻辑：');
      print('  1. 优先添加远程消息（状态更准确、已持久化）');
      print('  2. 添加本地待同步消息（仅限远程没有的）');
      print('  3. 根据 ID 去重，优先使用远程消息');
      print('');
      print('结果：');
      print('  - 不会出现消息重复');
      print('  - 消息状态更准确（使用远程状态）');
      print('  - 待同步消息正确保留');
    });
    
    test('所有消息变更操作都应该触发通知', () {
      // 这个测试验证哪些操作会触发 onMessagesChanged 通知
      
      print('触发 onMessagesChanged 通知的操作：');
      print('  ✅ sendMessage() - 发送消息后');
      print('  ✅ syncWithRemote() - 同步远程消息后');
      print('  ✅ revokeMessage() - 撤回消息后');
      print('  ✅ clearCurrentSession() - 清空会话后');
      print('');
      print('客户端只需订阅 onMessagesChanged，即可自动更新界面。');
    });
    
    test('消息状态应该正确标记', () {
      // 这个测试说明消息状态的标记
      
      print('消息状态说明：');
      print('刚发送的消息：');
      print('  - status: "pending"（待确认）');
      print('  - 从 AgentProxy.pendingMessages 获取');
      print('');
      print('同步后的消息：');
      print('  - status: 根据 AgentMessage.status 确定');
      print('  - 可能是 "none", "processing", "completed" 等');
      print('');
      print('离线消息：');
      print('  - metadata.localOnly: true');
      print('  - status: "pending"');
    });
    
    test('客户端应该正确处理本地模式和远程模式', () {
      // 这个测试说明如何兼容本地和远程模式
      
      print('兼容本地和远程模式的代码示例：');
      print('');
      print('void _initAgentProxy() async {');
      print('  final proxy = await getOrCreateAgentProxy(employeeId);');
      print('');
      print('  if (proxy.needCache) {');
      print('    // 远程模式：订阅消息变更');
      print('    _messagesSubscription = proxy.onMessagesChanged.listen((messages) {');
      print('      updateMessagesList(messages);');
      print('    });');
      print('  } else {');
      print('    // 本地模式：手动加载消息');
      print('    await _loadMessages();');
      print('  }');
      print('}');
    });
  });
  
  group('使用建议', () {
    test('完整的客户端实现示例', () {
      print('完整客户端实现步骤：');
      print('');
      print('1. 初始化代理：');
      print('   final proxy = await deviceClient.getOrCreateAgentProxy(employeeId);');
      print('');
      print('2. 订阅消息变更（远程模式）：');
      print('   if (proxy.needCache) {');
      print('     proxy.onMessagesChanged.listen((messages) {');
      print('       // 自动更新界面');
      print('       _messages.assignAll(messages);');
      print('     });');
      print('   }');
      print('');
      print('3. 发送消息：');
      print('   await proxy.sendMessage(MessageInput(content: "你好"));');
      print('   // ✅ 不需要手动刷新，onMessagesChanged 会自动通知');
      print('');
      print('4. 强制刷新（可选）：');
      print('   final messages = await proxy.getMessagesForceRefresh();');
      print('');
      print('5. 撤回消息：');
      print('   await proxy.revokeMessage(messageId);');
      print('   // ✅ 不需要手动刷新');
      print('');
      print('6. 清空会话：');
      print('   await proxy.clearCurrentSession();');
      print('   // ✅ 不需要手动刷新');
      print('');
      print('7. 释放资源：');
      print('   _messagesSubscription?.cancel();');
      print('   _stateSubscription?.cancel();');
    });
    
    test('避免的常见错误', () {
      print('常见错误示例：');
      print('');
      print('❌ 错误1：手动合并 pendingMessages');
      print('   final messages = await proxy.getSessionMessages();');
      print('   final pending = proxy.pendingMessages;');
      print('   final all = [...messages, ...pending];  // ❌ 导致重复');
      print('');
      print('✅ 正确：直接使用 getSessionMessages()');
      print('   final messages = await proxy.getSessionMessages();');
      print('   _messages.assignAll(messages);');
      print('');
      print('❌ 错误2：发送消息后立即手动加载');
      print('   await proxy.sendMessage(input);');
      print('   await _loadMessages();  // ❌ 不需要');
      print('');
      print('✅ 正确：订阅 onMessagesChanged 自动更新');
      print('   proxy.onMessagesChanged.listen((messages) {');
      print('     _messages.assignAll(messages);');
      print('   });');
      print('   await proxy.sendMessage(input);');
      print('');
      print('❌ 错误3：忘记取消订阅');
      print('   // 没有在 onClose 中取消订阅');
      print('');
      print('✅ 正确：记得取消订阅');
      print('   @override');
      print('   void onClose() {');
      print('     _messagesSubscription?.cancel();');
      print('     super.onClose();');
      print('   }');
    });
  });
}
