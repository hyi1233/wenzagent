# 字段统一重命名 Spec

## 重命名目标

将项目中的 `employeeUuid`、`sessionId`、`employeeId` 统一为 `employeeId`，消除命名混淆。

## 核心原则

1. **employeeUuid → employeeId**：所有表示员工唯一标识的字段统一使用 `employeeId`
2. **sessionId → employeeId**：项目中 sessionId 实际上就是 employeeId（一个员工一个会话），统一为 `employeeId`
3. **保留现有的 employeeId**：消息实体等已经使用 `employeeId` 的地方保持不变

## 影响范围

### 一、实体类（Entity）

#### 1. AiEmployeeSessionEntity（会话实体）
- **文件**: `lib/src/persistence/entities/session_entity.dart`
- **变更**:
  - 字段 `employeeUuid` → `employeeId`
  - 构造函数参数 `employeeUuid` → `employeeId`
  - `fromMap()` 中的 `'employeeUuid'` → `'employeeId'`
  - `toMap()` 中的 `'employeeUuid'` → `'employeeId'`
  - `copyWith()` 参数 `employeeUuid` → `employeeId`
  - `toString()` 中的 `employeeUuid` → `employeeId`
  - 注释中的 "员工UUID" → "员工ID"

#### 2. AiEmployeeMessageEntity（消息实体）
- **文件**: `lib/src/persistence/entities/message_entity.dart`
- **变更**: 无（已使用 `employeeId`，保持不变）

#### 3. SessionHistory（会话历史）
- **文件**: `lib/src/agent/adapter/session_memory_manager.dart`
- **变更**:
  - 字段 `employeeUuid` → `employeeId`
  - 构造函数参数 `employeeUuid` → `employeeId`

#### 4. SessionChangeEvent（会话变更事件）
- **文件**: `lib/src/service/session_manager.dart`
- **变更**:
  - 字段 `employeeUuid` → `employeeId`
  - 构造函数参数 `employeeUuid` → `employeeId`

### 二、Store 层

#### 1. SessionStore
- **文件**: `lib/src/persistence/stores/session_store.dart`
- **变更**:
  - 所有方法参数 `employeeUuid` → `employeeId`
  - 注释中的 "使用employeeUuid作为主键" → "使用employeeId作为主键"
  - 注释中的 "只需要employeeUuid" → "只需要employeeId"

#### 2. MessageStoreService
- **文件**: `lib/src/persistence/services/message_store_service.dart`
- **变更**: 无（已使用 `employeeId`，保持不变）

### 三、Service 层

#### 1. SessionManager
- **文件**: `lib/src/service/session_manager.dart`
- **变更**:
  - 所有接口方法参数 `employeeUuid` → `employeeId`
  - 实现类中的参数和局部变量 `employeeUuid` → `employeeId`
  - `_notifyChange()` 中的参数名调整

#### 2. AgentFactory
- **文件**: `lib/src/service/agent_factory.dart`
- **变更**:
  - `loadSession()` 回调中的局部变量 `employeeUuid` → `employeeId`
  - 返回的 map 中 `'employeeUuid'` → `'employeeId'`（保持兼容）

### 四、Device 层

#### 1. DeviceClientImpl
- **文件**: `lib/src/device/impl/device_client_impl.dart`
- **变更**:
  - `loadSession()` 回调中的注释 "employeeId现在实际上是employeeUuid" → 删除此注释（已统一）
  - 返回的 map 中 `'employeeUuid'` → `'employeeId'`
  - 相关局部变量调整

### 五、Agent 层

#### 1. AgentClient
- **文件**: `lib/src/agent/client/agent_client.dart`
- **变更**:
  - 方法参数 `employeeUuid` → `employeeId`（注意：这里有两种参数同时存在，需要仔细处理）
  - `_currentEmployeeUuid` → `_currentEmployeeId`
  - `currentEmployeeUuid` getter → `currentEmployeeId`
  - RPC 调用中的 `'employeeUuid'` 键名 → `'employeeId'`
  - 从 result 中读取 `'employeeId'`（保持不变）

#### 2. PersistentChatAdapter
- **文件**: `lib/src/agent/adapter/persistent_chat_adapter.dart`
- **变更**: 检查并统一相关字段

#### 3. AgentStateSnapshot
- **文件**: `lib/src/agent/agent_state.dart`
- **变更**:
  - 字段 `employeeId` 保持不变
  - `toMap()` 和 `fromMap()` 保持不变

### 六、Host 层

#### 1. MessageRouter
- **文件**: `lib/src/host/message_router.dart`
- **变更**:
  - RPC 调用中的 `'employeeId'` 保持不变

### 七、Persistence 层

#### 1. HiveManager
- **文件**: `lib/src/persistence/hive_manager.dart`
- **变更**:
  - `buildEmployeeSessionsKey()` 参数 `employeeUuid` → `employeeId`
  - 注释中的 `employeeUuid` → `employeeId`

#### 2. SessionAdapter
- **文件**: `lib/src/persistence/adapters/session_adapter.dart`
- **变更**:
  - 读写 `obj.employeeUuid` → `obj.employeeId`

### 八、Example 测试文件

所有 example 文件中的以下变更：
- 变量名 `employeeUuid` → `employeeId`
- 变量名如 `employeeAliceUuid` → `employeeAliceId`
- 注释中的 `employeeUuid` → `employeeId`
- 注释中的 `sessionUuid` → `employeeId`

**涉及文件**:
- `example/tool_call_persistence_test.dart`
- `example/remote_session_message_test.dart`
- `example/remote_session_list_test.dart`
- `example/remote_device_chat_test.dart`
- `example/message_persistence_fix_test.dart`
- `example/message_persistence_test.dart`
- `example/message_persistence_full_test.dart`
- `example/langchain_chat_test.dart`
- `example/tool_calling_test.dart`
- `example/full_example.dart`
- 其他包含 `employeeUuid` 的 example 文件

## 向后兼容性考虑

### 数据迁移
**不需要兼容旧数据**，直接进行字段重命名：
1. `fromMap()` 方法只读取新格式 `'employeeId'`
2. `toMap()` 方法只写入新格式 `'employeeId'`
3. 已有的 Hive 数据将在下次保存时自动更新为新格式

### API 兼容性
- RPC 调用中的参数名需要统一为 `'employeeId'`
- 如果有外部系统调用，需要通知变更

## 实施步骤

### Phase 1: 核心实体和 Store 层
1. 修改 `AiEmployeeSessionEntity`
2. 修改 `SessionHistory`
3. 修改 `SessionChangeEvent`
4. 修改 `SessionStore`
5. 修改 `SessionManager`

### Phase 2: Service 和 Device 层
1. 修改 `AgentFactory`
2. 修改 `DeviceClientImpl`
3. 修改 `HiveManager` 和 `SessionAdapter`

### Phase 3: Agent 和 Client 层
1. 修改 `AgentClient`
2. 修改 `PersistentChatAdapter`
3. 修改 `AgentStateSnapshot`（如需要）

### Phase 4: Example 测试文件
1. 修改所有 example 文件
2. 运行测试确保功能正常

### Phase 5: 验证
1. 运行所有 example 测试
2. 检查是否有遗漏的引用
3. 更新文档注释

## 风险和注意事项

1. **破坏性变更**: 这是一个破坏性变更，所有使用 `employeeUuid` 的代码都需要更新
2. **数据丢失**: 不兼容旧数据，已有的 Hive 存储数据需要重新生成
3. **RPC 协议**: 如果有其他服务依赖当前的 RPC 参数名，需要同步更新
4. **测试覆盖**: 所有修改都需要通过测试验证

## 检查清单

- [ ] 所有 `employeeUuid` 字段已重命名为 `employeeId`
- [ ] 所有 `sessionId` 引用已确认为 `employeeId`（当前未发现）
- [ ] 所有 `sessionUuid` 引用已更新为 `employeeId`
- [ ] 实体类的 `fromMap()` 只使用新格式 `'employeeId'`
- [ ] 实体类的 `toMap()` 使用新格式 `'employeeId'`
- [ ] 所有注释已更新
- [ ] 所有示例代码已更新
- [ ] 所有测试通过
- [ ] 文档已更新（如 README、CHANGELOG）

## 特殊说明

1. **employeeId vs employeeUuid**: 
   - 当前项目中，这两个字段实际上指向同一个概念（员工的唯一标识）
   - 统一后只使用 `employeeId`，消除歧义

2. **sessionId vs employeeId**:
   - 当前项目设计中，一个员工只有一个会话
   - 因此 sessionId 实际上就是 employeeId
   - 统一后不再使用 sessionId 概念

3. **RPC 参数**:
   - `AgentClient` 中同时存在 `employeeUuid` 和 `employeeId` 参数
   - 需要统一为 `employeeId`，并标记废弃 `employeeUuid` 参数
