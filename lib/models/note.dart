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

  /// 结构化课程归属（如「植物学」）。
  ///
  /// 为什么要单独一个字段：title 是用户随手写的（常是「11月22日第三讲」），
  /// 而模板匹配、术语表检索、Wiki 组织都需要准确的课程名。
  /// 为空表示老笔记，读的时候回退用 title。
  final String? course;

  /// 生成总结时使用的模板 ID，空表示九段式
  final String? templateId;

  /// 这次录音对应的教材位置（v9 加的五个字段，老笔记全为空）。
  ///
  /// 章号/节号存原文（「第五章」「第二节」），不拼成一个字符串——
  /// 将来要按章分组、按节排序都得靠结构化字段。
  final String? textbookId;
  final String? chapterNo;
  final String? chapterTitle;
  final String? sectionNo;
  final String? sectionTitle;

  /// 课堂语言（v10）。`zh` 默认，英语课为 `en`。
  /// 老笔记读出来一律按 zh，不迁移数据。
  final String language;

  /// 英语课的逐句译文（TranslationResult 的 JSON），中文笔记永远是 null。
  final String? translationJson;

  Note({
    required this.id,
    required this.title,
    required this.transcript,
    this.summaryJson,
    required this.createdAt,
    this.duration = 0,
    this.status = statusDone,
    this.terminologyJson,
    this.course,
    this.templateId,
    this.textbookId,
    this.chapterNo,
    this.chapterTitle,
    this.sectionNo,
    this.sectionTitle,
    this.language = 'zh',
    this.translationJson,
  });

  /// 是否已生成总结
  bool get hasSummary => summaryJson != null && summaryJson!.isNotEmpty;

  /// 是不是英语课笔记。翻译只对这类笔记启用。
  bool get isEnglish => language == 'en';

  /// 实际用于匹配课程的名字：优先 course，老笔记回退 title。
  /// 所有需要「课程」的地方都应该读这个，而不是直接用 title。
  String get effectiveCourse {
    final c = (course ?? '').trim();
    return c.isEmpty ? title.trim() : c;
  }

  /// 是否是「还没点完成」的草稿（崩溃/误退后可在首页继续）
  bool get isDraft => status == statusDraft;

  /// 这条笔记有没有记下教材位置。老笔记为 false，详情页据此决定要不要显示位置块。
  bool get hasLocation =>
      (textbookId ?? '').trim().isNotEmpty ||
      (chapterNo ?? '').trim().isNotEmpty ||
      (chapterTitle ?? '').trim().isNotEmpty ||
      (sectionNo ?? '').trim().isNotEmpty ||
      (sectionTitle ?? '').trim().isNotEmpty;

  /// 章节唯一键（与 CourseLocation.chapterKey 同一套拼法）。
  /// 术语缓存与提示词都用它，不要再自己拼。
  String get chapterKey {
    final parts = <String>[];
    final cNo = (chapterNo ?? '').trim();
    final cTitle = (chapterTitle ?? '').trim();
    if (cNo.isNotEmpty || cTitle.isNotEmpty) {
      parts.add([cNo, cTitle].where((s) => s.isNotEmpty).join(' '));
    }
    final sNo = (sectionNo ?? '').trim();
    final sTitle = (sectionTitle ?? '').trim();
    if (sNo.isNotEmpty || sTitle.isNotEmpty) {
      parts.add([sNo, sTitle].where((s) => s.isNotEmpty).join(' '));
    }
    return parts.join(' ');
  }

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
      course: map['course'] as String?,
      templateId: map['template_id'] as String?,
      // v9 之前的老库没有这五列，缺列时当作 null（不显示位置即可）
      textbookId: map['textbook_id'] as String?,
      chapterNo: map['chapter_no'] as String?,
      chapterTitle: map['chapter_title'] as String?,
      sectionNo: map['section_no'] as String?,
      sectionTitle: map['section_title'] as String?,
      // v10 之前的老库没有这两列，缺列时按中文课处理
      language: (map['language'] as String?) ?? 'zh',
      translationJson: map['translation_json'] as String?,
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
      'course': course,
      'template_id': templateId,
      'textbook_id': textbookId,
      'chapter_no': chapterNo,
      'chapter_title': chapterTitle,
      'section_no': sectionNo,
      'section_title': sectionTitle,
      'language': language,
      'translation_json': translationJson,
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
    String? course,
    bool clearCourse = false,
    String? templateId,
    String? textbookId,
    String? chapterNo,
    String? chapterTitle,
    String? sectionNo,
    String? sectionTitle,
    bool clearLocation = false,
    bool clearPosition = false,
    String? language,
    String? translationJson,
    bool clearTranslation = false,
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
      course: clearCourse ? null : (course ?? this.course),
      templateId: templateId ?? this.templateId,
      textbookId: clearLocation ? null : (textbookId ?? this.textbookId),
      chapterNo:
          (clearLocation || clearPosition) ? null : (chapterNo ?? this.chapterNo),
      chapterTitle: (clearLocation || clearPosition)
          ? null
          : (chapterTitle ?? this.chapterTitle),
      sectionNo:
          (clearLocation || clearPosition) ? null : (sectionNo ?? this.sectionNo),
      sectionTitle: (clearLocation || clearPosition)
          ? null
          : (sectionTitle ?? this.sectionTitle),
      language: language ?? this.language,
      translationJson: clearTranslation
          ? null
          : (translationJson ?? this.translationJson),
    );
  }
}

/// AI 总结的结构化数据：一个中心主题 + 多个要点，每个要点带子点。
/// 对应思维导图：中心 -> 分支 -> 子分支。

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
