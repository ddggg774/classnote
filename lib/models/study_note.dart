// lib/models/study_note.dart
// 详细课堂笔记的数据结构。
//
// 一次总结产出三份东西：
//   ① detailMarkdown：九段式详细笔记（可读、可二次编辑、可导出 .md）
//   ② mindMap：旧的两层导图（保留，供旧的导图 Tab / 导出兼容）
//   ③ graph：新的 3–5 级详细导图（主图+子图、关系、标记、来源回溯）
//
// 为什么 ② 和 ③ 都留：②已被页面和 PNG 导出依赖，直接删会把老功能弄坏；
// ③ 是新规格。两者由同一次 LLM 调用返回，不额外花钱。
// 模型没给 ③ 时，用 ② 自动降级生成一份，保证老数据和新数据都能看。

import 'dart:convert';

import 'mind_graph.dart';
import 'note.dart' show MindMapData;
import 'terminology.dart';

/// 一次「详细总结」的产物
class StudySummary {
  /// 固定结构的详细笔记（Markdown）
  final String detailMarkdown;

  /// 结构化要点（两层，供兼容用途）
  final MindMapData mindMap;

  /// 3–5 级详细导图
  final MindGraph graph;

  /// 本次总结是否按「超长课堂」做了分块合并（用于界面上提示用户）
  final bool chunked;

  /// 纠错留下的待确认项（Agent 跑完后要能在详情页看到并点击定位）。
  /// 存在这里而不是单独建表：它本来就是"这次生成的产物"，
  /// 与总结同一次落库、同一次读取，不会出现两处不同步。
  final List<PendingItem> pending;

  /// 额外技能产出（技能 id → Markdown）。
  /// 考点清单、复习题这类不进 detailMarkdown，避免污染"详细笔记"的语义。
  final Map<String, String> extras;

  /// 上次纠错因「待确认预算」压掉的条数（老数据缺省 0）。
  /// 存在这里，重进详情页才能继续显示「另有 N 处」。
  final int suppressedCount;

  const StudySummary({
    required this.detailMarkdown,
    required this.mindMap,
    required this.graph,
    this.chunked = false,
    this.pending = const [],
    this.extras = const {},
    this.suppressedCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'format': 'classnote.detail.v2',
        'detail': detailMarkdown,
        'mindMap': mindMap.toJson(),
        'graph': graph.toJson(),
        'chunked': chunked,
        if (pending.isNotEmpty)
          'pending': pending.map<Map<String, dynamic>>((p) => p.toJson()).toList(),
        if (extras.isNotEmpty) 'extras': extras,
        if (suppressedCount > 0) 'suppressedCount': suppressedCount,
      };

  factory StudySummary.fromJson(Map<String, dynamic> json) {
    final detail = json['detail'] as String? ?? '';

    // mindMap：新格式在 mindMap 字段；老格式整个 json 就是 mindMap
    final mapJson = json['mindMap'];
    final mindMap = mapJson is Map<String, dynamic>
        ? MindMapData.fromJson(mapJson)
        : MindMapData.fromJson(json);

    // graph：新格式才有；没有就用 mindMap 降级生成
    final graphJson = json['graph'];
    final graph = graphJson is Map<String, dynamic>
        ? MindGraph.fromJson(graphJson)
        : MindGraph.fromLegacyMindMap(mindMap);

    return StudySummary(
      detailMarkdown: detail,
      mindMap: mindMap,
      graph: graph,
      chunked: json['chunked'] as bool? ?? false,
      pending: (json['pending'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(PendingItem.fromJson)
              .toList() ??
          const [],
      extras: (json['extras'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
          ) ??
          const {},
      suppressedCount: (json['suppressedCount'] as num?)?.toInt() ?? 0,
    );
  }

  String encode() => jsonEncode(toJson());

  /// 解析存储的 summaryJson。
  /// 兼容三种历史形态：① 新格式带 detail/graph；② 只有 mindMap 的老格式；
  /// ③ 完全解析不了时返回 null，调用方降级为「无总结」而不是崩溃。
  static StudySummary? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return StudySummary.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 是否已有详细笔记正文
  bool get hasDetail => detailMarkdown.trim().isNotEmpty;

  /// 是否已有真正按新规格生成的导图（有二级以上层级）
  bool get hasRichGraph => graph.maxDepth >= 2;
}