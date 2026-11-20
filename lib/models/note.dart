// lib/models/note.dart
// 笔记数据模型 + 思维导图节点结构。
// 这里定义"数据长什么样"，页面和服务都围绕它工作。

/// 一条课堂笔记
class Note {
  static const String statusDraft = 'draft'; // 录音中/未点「完成并记录」
  static const String statusDone = 'done'; // 已正式保存

  final String id;          // 唯一 ID（uuid 生成）
  final String title;       // 课程名
  final String transcript;  // 原始转写文字
  final String? summaryJson;// AI 总结（结构化 JSON 字符串，用于生成思维导图）
  final DateTime createdAt; // 创建时间
  final int duration;       // 录音时长（秒）
  final String status;      // draft / done，见上方常量
  /// 课前术语表（TerminologyPack 的 JSON），可为空
  final String? terminologyJson;

  Note({
    required this.id,
    required this.title,
    required this.transcript,
    this.summaryJson,
    required this.createdAt,
    this.duration = 0,
    this.status = statusDone,
    this.terminologyJson,
  });

  /// 是否已生成总结
  bool get hasSummary => summaryJson != null && summaryJson!.isNotEmpty;

  /// 是否是「还没点完成」的草稿（崩溃/误退后可在首页继续）
  bool get isDraft => status == statusDraft;

  /// 数据库 -> 对象
  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id: map['id'] as String,
      title: map['title'] as String,
      transcript: map['transcript'] as String,
      summaryJson: map['summary_json'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      duration: (map['duration'] as int?) ?? 0,
      // 老库没有 status 列时按「已完成」处理，保持向后兼容
      status: (map['status'] as String?) ?? statusDone,
      terminologyJson: map['terminology_json'] as String?,
    );
  }

  /// 对象 -> 数据库
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'transcript': transcript,
      'summary_json': summaryJson,
      'created_at': createdAt.millisecondsSinceEpoch,
      'duration': duration,
      'status': status,
      'terminology_json': terminologyJson,
    };
  }

  /// 复制并更新部分字段（如写入 AI 总结后返回新对象）
  ///
  /// summaryJson 支持「显式清空」：传 [clearSummary] = true 时把总结置为 null。
  /// 旧版只有 `summaryJson ?? this.summaryJson` 一种语义，导致总结一旦生成就再也
  /// 无法清除（传 null 会被当成「不修改」）。
  Note copyWith({
    String? summaryJson,
    bool clearSummary = false,
    String? title,
    String? transcript,
    int? duration,
    String? status,
    String? terminologyJson,
    bool clearTerminology = false,
  }) {
    return Note(
      id: id,
      title: title ?? this.title,
      transcript: transcript ?? this.transcript,
      summaryJson: clearSummary ? null : (summaryJson ?? this.summaryJson),
      createdAt: createdAt,
      duration: duration ?? this.duration,
      status: status ?? this.status,
      terminologyJson: clearTerminology
          ? null
          : (terminologyJson ?? this.terminologyJson),
    );
  }
}

/// AI 总结的结构化数据：一个中心主题 + 多个要点，每个要点带子点。
/// 对应思维导图：中心 -> 分支 -> 子分支。
class MindMapData {
  final String root;                 // 中心主题
  final List<MindNode> nodes;        // 一级要点

  MindMapData({required this.root, required this.nodes});

  factory MindMapData.fromJson(Map<String, dynamic> json) {
    final rawNodes = (json['nodes'] as List?) ?? [];
    return MindMapData(
      root: (json['root'] as String?) ?? '本课总结',
      nodes: rawNodes
          .whereType<Map<String, dynamic>>()
          .map((n) => MindNode.fromJson(n))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'root': root,
        'nodes': nodes.map((n) => n.toJson()).toList(),
      };
}

/// 思维导图的一个要点节点
class MindNode {
  final String topic;              // 要点标题
  final List<String> children;     // 子点

  MindNode({required this.topic, required this.children});

  factory MindNode.fromJson(Map<String, dynamic> json) {
    final rawChildren = (json['children'] as List?) ?? [];
    return MindNode(
      topic: (json['topic'] as String?) ?? '',
      children: rawChildren.map((e) => e.toString()).toList(),
    );
  }

  Map<String, dynamic> toJson() => {'topic': topic, 'children': children};
}
