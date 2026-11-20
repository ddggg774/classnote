// lib/models/study_note.dart
// 详细课堂笔记的数据结构。
//
// 设计取舍：一次总结同时产出两份东西——
//   ① detailMarkdown：给「详细笔记」Tab 展示的固定结构 Markdown（可读、可二次编辑、可导出）；
//   ② mindMap：给「思维导图」Tab 用的结构化节点。
// 为什么不是一份：导图 Tab 和导出 PNG 依赖 MindMapData 的 root/nodes/children 结构，
// 直接换成 Markdown 会把已验证的导图功能弄坏。两份都由同一次 LLM 调用返回，不额外花钱。

import 'dart:convert';

import 'note.dart' show MindMapData;

/// 一次「详细总结」的产物
class StudySummary {
  /// 固定结构的详细笔记（Markdown）
  final String detailMarkdown;

  /// 结构化要点，供思维导图渲染
  final MindMapData mindMap;

  /// 本次总结是否按「超长课堂」做了分块合并（用于界面上提示用户）
  final bool chunked;

  const StudySummary({
    required this.detailMarkdown,
    required this.mindMap,
    this.chunked = false,
  });

  Map<String, dynamic> toJson() => {
        'format': 'classnote.detail.v1',
        'detail': detailMarkdown,
        'mindMap': mindMap.toJson(),
        'chunked': chunked,
      };

  factory StudySummary.fromJson(Map<String, dynamic> json) {
    // 兼容旧数据：v1 之前 summaryJson 里只有 mindMap 的结构，没有 detail
    final detail = json['detail'] as String? ?? '';
    final mapJson = json['mindMap'];
    final mindMap = mapJson is Map<String, dynamic>
        ? MindMapData.fromJson(mapJson)
        : MindMapData.fromJson(json); // 老格式：整个 json 就是 mindMap
    return StudySummary(
      detailMarkdown: detail,
      mindMap: mindMap,
      chunked: json['chunked'] as bool? ?? false,
    );
  }

  String encode() => jsonEncode(toJson());

  /// 解析存储的 summaryJson。
  /// 兼容三种历史形态：① 新格式带 detail；② 只有 mindMap 的老格式；
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
}