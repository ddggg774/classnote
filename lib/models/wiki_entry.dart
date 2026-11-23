// lib/models/wiki_entry.dart
// 课程知识库词条：把一节课的信息沉淀成「课程级」的可持续积累。
//
// 【与笔记的区别】
// 笔记是「一节课的记录」，词条是「一门课的知识」。
// 同一术语在多节课被提到时，词条只保留一份定义 + 多个出处。
// 这样复习时看的是"木兰科是什么"，而不是"第一讲说了啥、第三讲又说了啥"。
//
// 【为什么用 course + term 做唯一键】
// 「心皮」在植物学里和在其他课里是两回事。按课程隔离，
// 同一门课内同名视为同一词条（追加出处），跨课程互不干扰。
//
// 【关于冲突】
// 同一词条在不同课次出现不同定义时，**不覆盖**：
// 主定义保留最早抽取的那版，新的记录作为 source 入库并标 conflict。
// 谁对谁错由用户回听原文裁定——模型没有资格替用户裁定。
import 'dart:convert';

/// 词条类型。用枚举而不是自由字符串，避免模型每次给的分类都不一样。
enum WikiEntryType {
  term('term', '术语'),
  person('person', '人物'),
  formula('formula', '公式/定理'),
  concept('concept', '概念'),
  pitfall('pitfall', '易错点'),
  problemPattern('problemPattern', '例题套路');

  const WikiEntryType(this.code, this.label);

  final String code;
  final String label;

  static WikiEntryType fromCode(String? code) {
    final c = (code ?? '').trim().toLowerCase();
    for (final t in WikiEntryType.values) {
      if (t.code.toLowerCase() == c || t.label == code) return t;
    }
    // 模型给了不认识的分类，落在「概念」上比丢弃好
    return WikiEntryType.concept;
  }
}

/// 词条状态：抽取出来的词条先进 pending，用户确认后才算 confirmed。
///
/// 为什么要这一步：LLM 抽取难免把噪音（口语、半截话）当成词条，
/// 直接进正式库会让知识库越用越脏。给用户一个"确认"动作，
/// 既是质量控制，也让用户有掌控感。
enum WikiEntryStatus {
  pending('pending'),
  confirmed('confirmed');

  const WikiEntryStatus(this.code);
  final String code;

  static WikiEntryStatus fromCode(String? code) =>
      code == 'confirmed' ? WikiEntryStatus.confirmed : WikiEntryStatus.pending;
}

/// 词条的一处出处
class WikiSource {
  final String id;
  final String entryId;
  final String noteId;

  /// 笔记标题（冗余存一份，列表展示时不用再查 notes）
  final String noteTitle;

  /// 原文片段。这是给用户核对的依据，必须逐字来自原文。
  final String snippet;

  /// 这条出处记录的内容与主定义是否冲突
  final bool conflict;

  /// 与主定义不一致的那一版定义（冲突时才有）
  final String? altDefinition;

  final DateTime createdAt;

  const WikiSource({
    required this.id,
    required this.entryId,
    required this.noteId,
    this.noteTitle = '',
    required this.snippet,
    this.conflict = false,
    this.altDefinition,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'entry_id': entryId,
        'note_id': noteId,
        'note_title': noteTitle,
        'snippet': snippet,
        'conflict': conflict ? 1 : 0,
        'alt_definition': altDefinition,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory WikiSource.fromMap(Map<String, dynamic> map) => WikiSource(
        id: map['id'] as String,
        entryId: map['entry_id'] as String,
        noteId: map['note_id'] as String,
        noteTitle: map['note_title'] as String? ?? '',
        snippet: map['snippet'] as String? ?? '',
        conflict: ((map['conflict'] as num?)?.toInt() ?? 0) == 1,
        altDefinition: map['alt_definition'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (map['created_at'] as num?)?.toInt() ?? 0),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'noteId': noteId,
        'noteTitle': noteTitle,
        'snippet': snippet,
        if (conflict) 'conflict': true,
        if (altDefinition != null) 'altDefinition': altDefinition,
      };

  factory WikiSource.fromJson(Map<String, dynamic> json) => WikiSource(
        id: json['id'] as String? ?? '',
        entryId: json['entryId'] as String? ?? '',
        noteId: json['noteId'] as String? ?? '',
        noteTitle: json['noteTitle'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
        conflict: json['conflict'] as bool? ?? false,
        altDefinition: json['altDefinition'] as String?,
        createdAt: DateTime.now(),
      );
}

/// 一个词条
class WikiEntry {
  final String id;
  final String course;
  final String term;
  final WikiEntryType type;

  /// 主定义（首次抽取的那版）
  final String definition;

  /// 变体写法：别称、常见误听形式。喂给纠错 Agent 用。
  final List<String> variants;

  /// 关联词条的 term（用 term 而不是 id，跨库迁移时不会断链）
  final List<String> related;

  final WikiEntryStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const WikiEntry({
    required this.id,
    required this.course,
    required this.term,
    required this.type,
    required this.definition,
    this.variants = const [],
    this.related = const [],
    this.status = WikiEntryStatus.pending,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isConfirmed => status == WikiEntryStatus.confirmed;

  /// 唯一键：课程 + 词条名
  String get uniqueKey => '$course::$term';

  Map<String, dynamic> toMap() => {
        'id': id,
        'course': course,
        'term': term,
        'type': type.code,
        'definition': definition,
        'variants_json': jsonEncode(variants),
        'related_json': jsonEncode(related),
        'status': status.code,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory WikiEntry.fromMap(Map<String, dynamic> map) => WikiEntry(
        id: map['id'] as String,
        course: map['course'] as String? ?? '',
        term: map['term'] as String? ?? '',
        type: WikiEntryType.fromCode(map['type'] as String?),
        definition: map['definition'] as String? ?? '',
        variants: _decodeList(map['variants_json']),
        related: _decodeList(map['related_json']),
        status: WikiEntryStatus.fromCode(map['status'] as String?),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (map['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (map['updated_at'] as num?)?.toInt() ?? 0),
      );

  static List<String> _decodeList(Object? raw) {
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  WikiEntry copyWith({
    String? definition,
    List<String>? variants,
    List<String>? related,
    WikiEntryStatus? status,
    DateTime? updatedAt,
  }) =>
      WikiEntry(
        id: id,
        course: course,
        term: term,
        type: type,
        definition: definition ?? this.definition,
        variants: variants ?? this.variants,
        related: related ?? this.related,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 模型抽取出来的候选词条（还没落库）
class WikiCandidate {
  final String term;
  final WikiEntryType type;
  final String definition;
  final List<String> variants;
  final List<String> related;

  /// 支撑这个定义的原文片段（必须逐字来自原文）
  final String snippet;

  const WikiCandidate({
    required this.term,
    required this.type,
    required this.definition,
    this.variants = const [],
    this.related = const [],
    this.snippet = '',
  });

  static WikiCandidate? tryFromJson(Map<String, dynamic> json) {
    final term = (json['term'] as String?)?.trim() ?? '';
    final def = (json['definition'] as String?)?.trim() ?? '';
    // 没有词条名或没有定义的一律丢弃——半截词条没有价值
    if (term.isEmpty || def.isEmpty) return null;
    return WikiCandidate(
      term: term,
      type: WikiEntryType.fromCode(json['type'] as String?),
      definition: def,
      variants: ((json['variants'] as List?) ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      related: ((json['related'] as List?) ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      snippet: (json['snippet'] as String?)?.trim() ?? '',
    );
  }
}

/// 一次抽取的结果统计
class WikiExtractResult {
  final int created;
  final int appendedSources;
  final int conflicts;
  final int skipped;

  /// 非空表示有需要告知用户的情况（如正文过长被截断）
  final String note;

  const WikiExtractResult({
    this.created = 0,
    this.appendedSources = 0,
    this.conflicts = 0,
    this.skipped = 0,
    this.note = '',
  });

  int get total => created + appendedSources + conflicts + skipped;

  bool get isEmpty => total == 0;

  String get summary {
    final parts = <String>[];
    if (created > 0) parts.add('新建 $created 个词条');
    if (appendedSources > 0) parts.add('补充 $appendedSources 处出处');
    if (conflicts > 0) parts.add('$conflicts 处与已有定义不一致');
    if (skipped > 0) parts.add('跳过 $skipped 条');
    if (note.isNotEmpty) parts.add(note);
    return parts.isEmpty ? '没有抽取到新内容' : parts.join('，');
  }
}