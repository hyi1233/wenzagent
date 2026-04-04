import 'dart:async';

import '../agent_state.dart';
import 'agent_tool.dart';

/// 权限请求处理回调
///
/// 当工具需要权限确认时调用，返回用户的权限决策。
typedef PermissionRequestHandler =
    Future<PermissionDecision> Function(AgentPermissionRequest request);

/// 工具权限管理器
///
/// 负责在工具执行前进行权限检查，集成已有的 [AgentPermissionRequest] 框架。
/// 支持 [PermissionDecision.allowAlways] 缓存机制。
class ToolPermissionManager {
  /// 已记住的"始终允许"权限模式
  final Set<String> _allowedAlwaysPatterns = {};

  /// 权限请求处理回调（由 AgentImpl 设置）
  PermissionRequestHandler? onPermissionRequest;

  /// 检查工具执行权限
  ///
  /// 返回权限决策结果。流程：
  /// 1. 工具不需要权限 → 直接 allow
  /// 2. 已在"始终允许"缓存中 → 直接 allow
  /// 3. 调用 [onPermissionRequest] 回调等待用户决策
  /// 4. 如果用户选择 allowAlways → 加入缓存
  Future<PermissionDecision> checkPermission(
    AgentTool tool,
    Map<String, dynamic> arguments,
  ) async {
    // 不需要权限的工具直接放行
    if (!tool.requiresPermission) {
      return PermissionDecision.allow;
    }

    // 检查"始终允许"缓存
    final pattern = tool.permissionType;
    if (_allowedAlwaysPatterns.contains(pattern)) {
      return PermissionDecision.allow;
    }

    // 没有权限请求处理器，默认拒绝
    if (onPermissionRequest == null) {
      return PermissionDecision.deny;
    }

    // 构建权限请求
    final request = AgentPermissionRequest(
      requestId: 'perm_${DateTime.now().millisecondsSinceEpoch}_${tool.name}',
      type: 'tool_execution',
      description: '工具 "${tool.name}" 请求执行权限',
      functionName: tool.name,
      permissionPattern: pattern,
      permissionType: tool.permissionType,
      data: {
        'toolName': tool.name,
        'arguments': arguments,
        'requiresPermission': tool.requiresPermission,
      },
    );

    // 等待用户决策
    final decision = await onPermissionRequest!(request);

    // 如果用户选择"始终允许"，加入缓存
    if (decision == PermissionDecision.allowAlways) {
      _allowedAlwaysPatterns.add(pattern);
    }

    return decision;
  }

  /// 清除"始终允许"缓存
  void clearAllowedAlways() {
    _allowedAlwaysPatterns.clear();
  }

  /// 获取当前"始终允许"的权限模式列表
  Set<String> get allowedAlwaysPatterns =>
      Set.unmodifiable(_allowedAlwaysPatterns);
}
