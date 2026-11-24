// lib/models/mind_graph.dart
// 详细思维导图的数据模型（3–5 级，带关系、标记、来源回溯）。
//
// 为什么不用原来的 MindNode：
//   旧模型是 topic + List<String> children，只有两层、子点还是纯字符串，
//   装不下「层级 3–5 级 / 关系标注 / 视觉编码 / 时间戳回溯」这些要求。
//   这里换成真正的树：每个节点有 id、标题、说明、关系、标记、来源。
//
// 视觉编码约定（与提示词、渲染、导出保持同一套，改一处必须三处同步）：
//   ★ 重点   ▲ 难点   ⚠ 易错   ◆ 考点   ❓ 待确认   「」老师原话
// 关系标签（relation）：前提 / 推导 / 因果 / 对比 / 包含 / 易错 / 考试相关
import 'dart:convert';


/// 节点的视觉标记。用枚举而不是裸字符串，保证渲染和导出不会各写一套。
enum NodeMark {
  key('★', '重点'),
  hard('▲', '难点'),
  pitfall('⚠', '易错'),
  exam('◆', '考点'),
  unconfirmed('❓', '待确认'),
  quote('「」', '老师原话'),
  none('', '');

  const NodeMark(this.symbol, this.label);
  final String symbol;
  final String label;

  static NodeMark fromCode(String? code) {
    switch (code) {
      case 'key':
        return NodeMark.key;
      case 'hard':
        return NodeMark.hard;
      case 'pitfall':
        return NodeMark.pitfall;
      case 'exam':
        return NodeMark.exam;
      case 'unconfirmed':
        return NodeMark.unconfirmed;
      case 'quote':
        return NodeMark.quote;
      default:
        return NodeMark.none;
    }
  }

  String get code {
    switch (this) {
      case NodeMark.key:
        return 'key';
      case NodeMark.hard:
        return 'hard';
      case NodeMark.pitfall:
        return 'pitfall';
      case NodeMark.exam:
        return 'exam';
      case NodeMark.unconfirmed:
        return 'unconfirmed';
      case NodeMark.quote:
        return 'quote';
      case NodeMark.none:
        return 'none';
    }
  }
}

/// 思维导图的一个节点（可递归嵌套，支撑 3–5 级）
class MindGraphNode {
  final String id;
  final String title;

  /// 节点正文：概念的定义与条件、公式的变量含义与适用条件、
  /// 例题的题干摘要/思路/答案等，以简短 Markdown 列表存放。
  final List<String> details;

  /// 与父节点的关系（前提/推导/因果/对比/包含/易错/考试相关）
  final String? relation;

  /// 视觉标记
  final NodeMark mark;

  /// 来源回溯：时间戳或原文片段。转写不清时由提示词产出「待确认」说明。
  final String? source;

  final List<MindGraphNode> children;

  const MindGraphNode({
    required this.id,
    required this.title,
    this.details = const [],
    this.relation,
    this.mark = NodeMark.none,
    this.source,
    this.children = const [],
  });

  factory MindGraphNode.fromJson(Map<String, dynamic> json, {String path = 'r'}) {
    final rawChildren = (json['children'] as List?) ?? [];
    final rawDetails = (json['details'] as List?) ?? [];

    // 兼容旧格式：旧的两层结构用 topic 存标题、children 直接是字符串数组。
    // 模型偶尔也会退回这种写法，所以两种都要能吃。
    final title =
        (json['title'] as String?)?.trim().isNotEmpty == true
            ? (json['title'] as String).trim()
            : ((json['topic'] as String?)?.trim() ?? '');

    final relation = (json['relation'] as String?)?.trim();

    return MindGraphNode(
      id: (json['id'] as String?) ?? path,
      title: title,
      details: rawDetails
          .map((e) => e.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList(),
      relation: (relation == null || relation.isEmpty) ? null : relation,
      mark: NodeMark.fromCode(json['mark'] as String?),
      source: (json['source'] as String?)?.trim().isEmpty == true
          ? null
          : (json['source'] as String?),
      children: rawChildren.asMap().entries.map((e) {
        final v = e.value;
        final childPath = '$path.${e.key}';
        // 字符串子节点 → 转成叶子节点（旧格式的典型形态）
        if (v is String) {
          return MindGraphNode(
            id: childPath,
            title: v,
            relation: '包含',
          );
        }
        if (v is Map<String, dynamic>) {
          return MindGraphNode.fromJson(v, path: childPath);
        }
        // 其它类型（null/数字）直接忽略，不让整棵树崩掉
        return MindGraphNode(id: childPath, title: v?.toString() ?? '');
      }).where((n) => n.title.isNotEmpty).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (details.isNotEmpty) 'details': details,
        if (relation != null) 'relation': relation,
        if (mark != NodeMark.none) 'mark': mark.code,
        if (source != null) 'source': source,
        if (children.isNotEmpty)
          'children': children.map((c) => c.toJson()).toList(),
      };

  /// 当前节点及其所有后代的节点数（用于统计/测试）
  int get totalCount =>
      1 + children.fold<int>(0, (sum, c) => sum + c.totalCount);

  /// 这棵树的最大深度（根节点算 1 级）
  int get depth =>
      1 + children.fold<int>(0, (m, c) => c.depth > m ? c.depth : m);

  /// 展开成「主图/子图」两层视图：主图只显示一级分支标题，
  /// 子图显示某个一级分支下的完整层级。
  List<MindGraphNode> get branches => children;
}

/// 一份完整的详细导图
class MindGraph {
  /// 显示的固定顺序：这 11 个一级分支即使「未提及」也要出现在主图上，
  /// 保证每次生成的结构一致、用户知道哪块是空的。
  static const List<String> requiredBranches = [
    '课程信息',
    '学习目标',
    '知识点结构',
    '公式/定理',
    '例题与解题步骤',
    '易错点',
    '老师强调',
    '考试/作业提示',
    '课堂问答',
    '术语表',
    '待确认清单',
  ];

  final String root;
  final List<MindGraphNode> branches;

  const MindGraph({required this.root, required this.branches});

  factory MindGraph.fromJson(Map<String, dynamic> json) {
    // 兼容模型把根节点包成一层的写法：{"root": "...", "children": [...]}
    final rawBranches = (json['branches'] as List?) ??
        (json['children'] as List?) ??
        (json['nodes'] as List?) ??
        [];
    return MindGraph(
      root: (json['root'] as String?)?.trim().isNotEmpty == true
          ? json['root'] as String
          : '本课思维导图',
      branches: rawBranches.asMap().entries.map((e) {
        final v = e.value;
        final path = 'b${e.key}';
        if (v is String) {
          return MindGraphNode(id: path, title: v, relation: '包含');
        }
        if (v is Map<String, dynamic>) {
          return MindGraphNode.fromJson(v, path: path);
        }
        return MindGraphNode(id: path, title: v?.toString() ?? '');
      }).where((n) => n.title.isNotEmpty).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'root': root,
        'branches': branches.map((b) => b.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  /// 用旧的两层 MindMap 降级生成一份 graph。
  /// 用途：本次改版之前生成的笔记只有旧结构，没有 3–5 级详细导图。
  /// 与其让「导图」Tab 空着，不如把它转成两层树，让用户至少能看能导出，
  /// 同时在界面上提示「点重新总结可获得详细导图」。

  static MindGraph? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return MindGraph.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  int get totalNodes => branches.fold<int>(0, (s, b) => s + b.totalCount);
  int get maxDepth =>
      branches.fold<int>(0, (m, b) => b.depth > m ? b.depth : m);

  /// 找出缺失的固定分支（模型没给时用于 UI 提示「未提及」）
  List<String> get missingRequiredBranches {
    final present = branches.map((b) => b.title).toSet();
    return requiredBranches.where((r) => !present.contains(r)).toList();
  }
}