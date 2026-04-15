import 'package:sqlite3/sqlite3.dart';

import '../schemas/spec_schema.dart';
import 'migration.dart';

/// 版本 12: 新增 spec_items 和 spec_groups 表
///
/// 规格说明管理系统，支持 AI 员工在对话中管理项目/员工的规格文档。
class V12Migration extends Migration {
  @override
  int get version => 12;

  @override
  void onUpgrade(Database db) {
    SpecGroupSchema.create(db);
    SpecItemSchema.create(db);
  }
}
