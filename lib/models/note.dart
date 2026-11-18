// lib/models/note.dart
// 笔记数据模型 + 思维导图节点结构。
// 这里定义"数据长什么样"，页面和服务都围绕它工作。

/// 一条课堂笔记
class Note {
  final String id;          // 唯一 ID（uuid 生成）
  final String title;       // 课程名
  final String transcript;  // 原始转写文字
  final String? summaryJson;// AI 总结（结构化 JSON 字符串，用于生成思维导图）
  final DateTime createdAt; // 创建时间
  final int duration;       // 录音时长（秒）

  Note({
    required this.id,
    required this.title,
    required this.transcript,
    this.summaryJson,
    required this.createdAt,
    this.duration = 0,
  });

  /// 是否已生成总结
  bool get hasSummary => summaryJson != null && summaryJson!.isNotEmpty;

  /// 数据库 -> 对象
  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id: map['id'] as String,
      title: map['title'] as String,
      transcript: map['transcript'] as String,
      summaryJson: map['summary_json'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      duration: (map['duration'] as int?) ?? 0,
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
    };
  }

  /// 复制并更新部分字段（如写入 AI 总结后返回新对象）
  Note copyWith({String? summaryJson, String? transcript, int? duration}) {
    return Note(
      id: id,
      title: title,
      transcript: transcript ?? this.transcript,
      summaryJson: summaryJson ?? this.summaryJson,
      createdAt: createdAt,
      duration: duration ?? this.duration,
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
