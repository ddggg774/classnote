// lib/models/study_note.dart
// 详细课堂笔记的数据结构。
//
// 一次总结只产出详细笔记（detailMarkdown）；
// 思维导图（graph）在正文定稿后单独生成，见 AiService.generateMindGraph。
//
// 老数据的 summary_json 里可能还带 mindMap 字段：解析时直接忽略，
// 不再保留两层导图模型（2026-11 起大纲模块已删除）。

import 'dart:convert';

import 'mind_graph.dart';
import 'terminology.dart';

/// 一次「详细总结」的产物
class StudySummary {
  /// 固定结构的详细笔记（Markdown）
  final String detailMarkdown;

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
    required this.graph,
    this.chunked = false,
    this.pending = const [],
    this.extras = const {},
    this.suppressedCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'format': 'classnote.detail.v2',
        'detail': detailMarkdown,
        'graph': graph.toJson(),
        'chunked': chunked,
        if (pending.isNotEmpty)
          'pending': pending.map<Map<String, dynamic>>((p) => p.toJson()).toList(),
        if (extras.isNotEmpty) 'extras': extras,
        if (suppressedCount > 0) 'suppressedCount': suppressedCount,
      };

  factory StudySummary.fromJson(Map<String, dynamic> json) {
    final detail = json['detail'] as String? ?? '';

    // graph：导图单独生成；老数据没有就留空，不影响正文解析
    final graphJson = json['graph'];
    MindGraph graph;
    try {
      graph = graphJson is Map<String, dynamic>
          ? MindGraph.fromJson(graphJson)
          : const MindGraph(root: '', branches: []);
    } catch (_) {
      graph = const MindGraph(root: '', branches: []);
    }

    return StudySummary(
      detailMarkdown: detail,
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
  /// 兼容历史形态：新格式带 detail/graph；老格式可能只有 mindMap（忽略）；
  /// 完全解析不了时返回 null，调用方降级为「无总结」而不是崩溃。
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