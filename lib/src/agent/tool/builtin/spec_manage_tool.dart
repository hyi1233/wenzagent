import '../../../persistence/entities/spec_group_entity.dart';
import '../../../persistence/entities/spec_item_entity.dart';
import '../agent_tool.dart';

/// 规格管理工具
///
/// 支持跨轮次的规格说明管理，数据持久化到 SQLite，
/// 支持分组管理。所有操作通过异步回调由 AgentImpl 注入。
class SpecManageTool extends AgentTool {
  // ===== 异步回调（由 AgentImpl 注入） =====

  /// 获取活跃 spec 项（draft + pending + in_progress）
  Future<List<SpecItemEntity>> Function(String employeeId)? getActiveSpecs;

  /// 获取已完成的 spec 项
  Future<List<SpecItemEntity>> Function(String employeeId, {int limit})?
      getCompletedSpecs;

  /// 保存 spec 项
  Future<void> Function(SpecItemEntity item)? saveSpec;

  /// 更新 spec 状态
  Future<void> Function(String id, String status)? updateSpecStatus;

  /// 更新 spec 内容
  Future<void> Function(String id, {String? title, String? content})?
      updateSpecContent;

  /// 软删除 spec 项
  Future<void> Function(String id)? removeSpec;

  /// 批量删除已完成的项
  Future<void> Function(String employeeId)? clearCompletedSpecs;

  /// 移动 spec 到分组
  Future<void> Function(String id, String? groupId)? moveSpecToGroup;

  /// 获取员工所有分组
  Future<List<SpecGroupEntity>> Function(String employeeId)? getGroups;

  /// 按名称查找分组
  Future<SpecGroupEntity?> Function(String employeeId, String name)?
      findGroupByName;

  /// 保存分组
  Future<void> Function(SpecGroupEntity group)? saveGroup;

  /// 软删除分组
  Future<void> Function(String id)? removeGroup;

  /// 重命名分组
  Future<void> Function(String id, String newName)? renameGroupFn;

  /// 广播事件
  void Function(String type, Map<String, dynamic> data)? broadcastEvent;

  /// 当前员工 ID（由 AgentImpl 注入）
  String? employeeId;

  @override
  String get name => 'spec_manage';

  @override
  String get description =>
      'Manage persistent spec (specification) documents with group support. '
      'Data persists across agent restarts.\n\n'
      'Actions:\n'
      '- "add": Create a new spec item (requires title; optional: content, priority, group, tags)\n'
      '- "list": View items by scope (active/completed/all)\n'
      '- "update": Change status, title, or content of an item\n'
      '- "remove": Delete a specific item\n'
      '- "clear": Remove all completed items\n'
      '- "create_group": Create a new group\n'
      '- "list_groups": View all groups\n'
      '- "rename_group": Rename a group\n'
      '- "delete_group": Delete a group (items move to ungrouped)\n'
      '- "move_to_group": Move a spec item to a group\n\n'
      'Specs are persisted in the database.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'add',
              'list',
              'update',
              'remove',
              'clear',
              'create_group',
              'list_groups',
              'rename_group',
              'delete_group',
              'move_to_group',
            ],
            'description': 'Action to perform on the spec list.',
          },
          'title': {
            'type': 'string',
            'description':
                'Spec item title. Required for "add". Optional for "update" to change title.',
          },
          'content': {
            'type': 'string',
            'description':
                'Spec item content/description. Optional for "add" and "update".',
          },
          'id': {
            'type': 'string',
            'description':
                'Spec item ID. Required for "update", "remove", and "move_to_group".',
          },
          'status': {
            'type': 'string',
            'enum': ['draft', 'pending', 'in_progress', 'completed'],
            'description':
                'New status for the item. Used with "update" action.',
          },
          'priority': {
            'type': 'string',
            'enum': ['low', 'medium', 'high'],
            'description':
                'Priority level for "add" action. Default is "medium".',
          },
          'tags': {
            'type': 'string',
            'description':
                'Comma-separated tags for "add" action.',
          },
          'scope': {
            'type': 'string',
            'enum': ['active', 'completed', 'all'],
            'description':
                'Scope for "list" action. Default is "active".',
          },
          'group': {
            'type': 'string',
            'description':
                'Group name for "add" action. Creates the group if it does not exist.',
          },
          'group_id': {
            'type': 'string',
            'description':
                'Group ID for "rename_group", "delete_group", and "move_to_group" actions.',
          },
          'new_name': {
            'type': 'string',
            'description': 'New name for "rename_group" action.',
          },
          'name': {
            'type': 'string',
            'description': 'Group name for "create_group" action.',
          },
        },
        'required': ['action'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final action = arguments['action'] as String?;
    if (action == null || action.isEmpty) {
      return ToolResult.error('action is required');
    }

    if (employeeId == null) {
      return ToolResult.error('Spec tool not initialized');
    }

    switch (action) {
      case 'add':
        return _add(arguments);
      case 'list':
        return _list(arguments);
      case 'update':
        return _update(arguments);
      case 'remove':
        return _remove(arguments);
      case 'clear':
        return _clear();
      case 'create_group':
        return _createGroup(arguments);
      case 'list_groups':
        return _listGroups();
      case 'rename_group':
        return _renameGroup(arguments);
      case 'delete_group':
        return _deleteGroup(arguments);
      case 'move_to_group':
        return _moveToGroup(arguments);
      default:
        return ToolResult.error(
          'Unknown action: $action. Use add, list, update, remove, clear, '
          'create_group, list_groups, rename_group, delete_group, or move_to_group.',
        );
    }
  }

  Future<ToolResult> _add(Map<String, dynamic> arguments) async {
    final title = arguments['title'] as String?;
    if (title == null || title.isEmpty) {
      return ToolResult.error('title is required for add action');
    }

    final content = arguments['content'] as String? ?? '';
    final priority = arguments['priority'] as String? ?? 'medium';
    final tags = arguments['tags'] as String? ?? '';
    final now = DateTime.now();
    final id = 'spec_${now.millisecondsSinceEpoch}';

    // 处理分组
    String? groupId;
    final groupName = arguments['group'] as String?;
    if (groupName != null && groupName.isNotEmpty) {
      if (findGroupByName == null || saveGroup == null) {
        return ToolResult.error('Group operations not available');
      }
      var group = await findGroupByName!(employeeId!, groupName);
      if (group == null) {
        // 自动创建分组
        final groupIdStr = 'sg_${now.millisecondsSinceEpoch}';
        group = SpecGroupEntity(
          id: groupIdStr,
          employeeId: employeeId!,
          name: groupName,
          createTime: now,
          updateTime: now,
        );
        await saveGroup!(group);
        broadcastEvent?.call('specGroupChanged', {
          'action': 'created',
          'groupId': groupIdStr,
          'name': groupName,
        });
      }
      groupId = group.id;
    }

    final item = SpecItemEntity(
      id: id,
      employeeId: employeeId!,
      groupId: groupId,
      title: title,
      content: content,
      status: 'pending',
      priority: priority,
      tags: tags,
      createTime: now,
      updateTime: now,
    );

    await saveSpec?.call(item);

    broadcastEvent?.call('specChanged', {
      'action': 'added',
      'specId': id,
      'title': title,
      'groupId': groupId,
    });

    final groupInfo = groupName != null ? ' (group: $groupName)' : '';
    return ToolResult.success('Spec added: [$id] $title$groupInfo');
  }

  Future<ToolResult> _list(Map<String, dynamic> arguments) async {
    if (getActiveSpecs == null) {
      return ToolResult.error('Spec list is not available');
    }

    final scope = arguments['scope'] as String? ?? 'active';
    final eid = employeeId!;

    List<SpecItemEntity> activeItems = [];
    List<SpecItemEntity> completedItems = [];

    if (scope == 'active' || scope == 'all') {
      activeItems = await getActiveSpecs!(eid);
    }
    if (scope == 'completed' || scope == 'all') {
      completedItems = await getCompletedSpecs!(eid);
    }

    final allItems = [...activeItems, ...completedItems];
    if (allItems.isEmpty) {
      return ToolResult.success('Spec list is empty.');
    }

    // 获取所有分组用于显示名称
    final groups = await getGroups?.call(eid) ?? [];
    final groupMap = <String, String>{};
    for (final g in groups) {
      groupMap[g.id] = g.name;
    }

    // 按分组组织活跃项
    final grouped = <String?, List<SpecItemEntity>>{};
    final ungrouped = <SpecItemEntity>[];
    for (final item in activeItems) {
      if (item.groupId != null) {
        grouped.putIfAbsent(item.groupId, () => []).add(item);
      } else {
        ungrouped.add(item);
      }
    }

    final buffer = StringBuffer();
    buffer.writeln('## Spec List (${allItems.length} items)');

    // 按分组输出
    for (final entry in grouped.entries) {
      final gName = groupMap[entry.key] ?? 'Unknown Group';
      buffer.writeln();
      buffer.writeln('### $gName');
      for (final s in entry.value) {
        final statusIcon = s.status == 'in_progress'
            ? '...'
            : s.status == 'draft'
                ? '?'
                : ' ';
        final priorityTag =
            s.priority != 'medium' ? ' [${s.priority}]' : '';
        buffer.writeln(
            '  - [${s.id}]$statusIcon${s.title}$priorityTag');
      }
    }

    // 未分组的活跃项
    final inProgress =
        ungrouped.where((s) => s.status == 'in_progress').toList();
    final pending = ungrouped.where((s) => s.status == 'pending').toList();
    final draft = ungrouped.where((s) => s.status == 'draft').toList();

    if (inProgress.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### In Progress');
      for (final s in inProgress) {
        buffer.writeln('  - [${s.id}] ${s.title}');
      }
    }

    if (pending.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Pending');
      for (final s in pending) {
        buffer.writeln('  - [${s.id}] ${s.title}');
      }
    }

    if (draft.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Draft');
      for (final s in draft) {
        buffer.writeln('  - [${s.id}] ${s.title}');
      }
    }

    if (completedItems.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Completed (${completedItems.length})');
      for (final s in completedItems) {
        buffer.writeln('  - [${s.id}] ${s.title}');
      }
    }

    return ToolResult.success(buffer.toString().trim());
  }

  Future<ToolResult> _update(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for update action');
    }

    final statusStr = arguments['status'] as String?;
    final title = arguments['title'] as String?;
    final content = arguments['content'] as String?;

    if (statusStr == null &&
        (title == null || title.isEmpty) &&
        (content == null || content.isEmpty)) {
      return ToolResult.error(
          'At least one of status, title, or content is required for update action');
    }

    if (statusStr != null) {
      if (!['draft', 'pending', 'in_progress', 'completed']
          .contains(statusStr)) {
        return ToolResult.error(
          'Invalid status: $statusStr. Use draft, pending, in_progress, or completed.',
        );
      }
      await updateSpecStatus?.call(id, statusStr);
    }

    if ((title != null && title.isNotEmpty) ||
        (content != null && content.isNotEmpty)) {
      await updateSpecContent?.call(id, title: title, content: content);
    }

    broadcastEvent?.call('specChanged', {
      'action': 'updated',
      'specId': id,
      if (statusStr != null) 'status': statusStr,
    });

    return ToolResult.success(
      'Spec updated: [$id]${
        statusStr != null ? ' status=$statusStr' : ''
      }${title != null ? ' title=$title' : ''}${content != null ? ' content updated' : ''}',
    );
  }

  Future<ToolResult> _remove(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for remove action');
    }

    await removeSpec?.call(id);

    broadcastEvent?.call('specChanged', {
      'action': 'removed',
      'specId': id,
    });

    return ToolResult.success('Spec removed: [$id]');
  }

  Future<ToolResult> _clear() async {
    if (clearCompletedSpecs == null) {
      return ToolResult.error('Spec operations not available');
    }
    await clearCompletedSpecs!(employeeId!);

    broadcastEvent?.call('specChanged', {
      'action': 'cleared',
    });

    return ToolResult.success('All completed spec items cleared.');
  }

  Future<ToolResult> _createGroup(Map<String, dynamic> arguments) async {
    final name = arguments['name'] as String?;
    if (name == null || name.isEmpty) {
      return ToolResult.error('name is required for create_group action');
    }

    if (saveGroup == null || findGroupByName == null) {
      return ToolResult.error('Group operations not available');
    }

    // 检查是否已存在同名分组
    final existing = await findGroupByName!(employeeId!, name);
    if (existing != null) {
      return ToolResult.error('Group already exists: $name');
    }

    final now = DateTime.now();
    final id = 'sg_${now.millisecondsSinceEpoch}';
    final group = SpecGroupEntity(
      id: id,
      employeeId: employeeId!,
      name: name,
      createTime: now,
      updateTime: now,
    );
    await saveGroup!(group);

    broadcastEvent?.call('specGroupChanged', {
      'action': 'created',
      'groupId': id,
      'name': name,
    });

    return ToolResult.success('Group created: [$id] $name');
  }

  Future<ToolResult> _listGroups() async {
    if (getGroups == null) {
      return ToolResult.error('Group operations not available');
    }

    final groups = await getGroups!(employeeId!);
    if (groups.isEmpty) {
      return ToolResult.success('No groups found.');
    }

    final buffer = StringBuffer('## Spec Groups (${groups.length})\n');
    for (final g in groups) {
      buffer.writeln('  - [${g.id}] ${g.name}');
    }
    return ToolResult.success(buffer.toString().trim());
  }

  Future<ToolResult> _renameGroup(Map<String, dynamic> arguments) async {
    final groupId = arguments['group_id'] as String?;
    final newName = arguments['new_name'] as String?;

    if (groupId == null || groupId.isEmpty) {
      return ToolResult.error('group_id is required for rename_group action');
    }
    if (newName == null || newName.isEmpty) {
      return ToolResult.error('new_name is required for rename_group action');
    }

    await renameGroupFn?.call(groupId, newName);

    broadcastEvent?.call('specGroupChanged', {
      'action': 'renamed',
      'groupId': groupId,
      'newName': newName,
    });

    return ToolResult.success('Group renamed: [$groupId] -> $newName');
  }

  Future<ToolResult> _deleteGroup(Map<String, dynamic> arguments) async {
    final groupId = arguments['group_id'] as String?;
    if (groupId == null || groupId.isEmpty) {
      return ToolResult.error('group_id is required for delete_group action');
    }

    await removeGroup?.call(groupId);

    broadcastEvent?.call('specGroupChanged', {
      'action': 'deleted',
      'groupId': groupId,
    });

    return ToolResult.success(
      'Group deleted: [$groupId]. Items moved to ungrouped.',
    );
  }

  Future<ToolResult> _moveToGroup(Map<String, dynamic> arguments) async {
    final specId = arguments['id'] as String?;
    final groupId = arguments['group_id'] as String?;

    if (specId == null || specId.isEmpty) {
      return ToolResult.error('id is required for move_to_group action');
    }

    if (moveSpecToGroup == null) {
      return ToolResult.error('Spec operations not available');
    }

    // groupId 为 null 表示移出分组
    await moveSpecToGroup!(specId, groupId);

    broadcastEvent?.call('specChanged', {
      'action': 'moved',
      'specId': specId,
      'groupId': groupId,
    });

    if (groupId != null) {
      return ToolResult.success('Spec [$specId] moved to group [$groupId]');
    }
    return ToolResult.success('Spec [$specId] moved to ungrouped');
  }
}
