# 消息ID一致性修复总结

## 问题

用户发送消息后，`getUnreceivedMessages` 返回了与当前输入消息 ID 不一样的相同消息，导致消息重复显示。

## 根本原因

`LangChainChatAdapter.addMessage` 在添加用户消息到历史时，使用了 `MessageWrapper.create()` 自动生成新的 UUID，而不是使用客户端提供的消息 ID。

### 问题流程

```
客户端发送: messageId = uuid-aaa
    ↓
LangChainChatAdapter.addMessage()
    ↓
MessageWrapper.create() → uuid-bbb ❌
    ↓
持久化: {'id': uuid-bbb, ...}
    ↓
getUnreceivedMessages: 返回 uuid-bbb ❌
    ↓
客户端期望: uuid-aaa
```

## 解决方案

**核心原则**：每个环节都要确保消息 ID 没有变化，而不是使用内容签名去重。

### 关键修改

1. **SessionHistory.addMessage** - 添加 `messageId` 参数
2. **SessionMemoryManager.addMessage** - 传递 `messageId`
3. **LangChainChatAdapter.streamMessage** - 从 `messageData` 提取并传递 ID
4. **持久化逻辑** - 同时设置 `uuid` 和 `id` 字段

### 修复后的流程

```
客户端发送: messageId = uuid-aaa
    ↓
LangChainChatAdapter.streamMessage()
    ↓
提取 userMessageId = uuid-aaa ✅
    ↓
memoryManager.addMessage(..., messageId: uuid-aaa) ✅
    ↓
MessageWrapper(uuid: uuid-aaa, ...) ✅
    ↓
持久化: {'uuid': uuid-aaa, 'id': uuid-aaa, ...} ✅
    ↓
getUnreceivedMessages: 返回 uuid-aaa ✅
    ↓
客户端: ID 匹配，无重复 ✅
```

## 撤销的方案

之前为了避免消息重复，添加了基于内容签名的去重逻辑，但这不是正确的解决方案。现在已经撤销：

- ❌ `_findDuplicateUserMessage()` 方法
- ❌ 内容签名去重逻辑
- ✅ 使用消息 ID 一致性保证

## 测试验证

✅ 所有测试通过  
✅ 无 lint 错误  
✅ 消息 ID 在整个流程中保持一致  

## 文件修改

| 文件 | 修改内容 |
|------|---------|
| `lib/src/agent/adapter/session_memory_manager.dart` | 添加 `messageId` 参数支持 |
| `lib/src/agent/adapter/langchain_chat_adapter.dart` | 从 `messageData` 提取并传递消息 ID |
| `lib/src/agent/adapter/persistent_chat_adapter.dart` | 同时设置 `uuid` 和 `id` 字段 |
| `lib/src/agent/client/cached_agent_proxy.dart` | 撤销内容签名去重逻辑 |

## 总结

通过在消息处理的每个环节确保消息 ID 的一致性，从根本上解决了消息重复的问题。这比使用内容签名去重更加可靠和正确。
