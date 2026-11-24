// lib/models/note_template.dart
// 笔记模板：决定「输出哪些章节、每节要求什么」。
//
// 【为什么模板不是一整个 prompt 字符串】
// 现有 _detailSystemPrompt 里混了三类内容：
//   ① 通用铁律（绝不编造、标待确认、公式保留原样）
//   ② 整理要求（去口语、书面语重述、标来源）
//   ③ 输出结构（9 节）
// 如果模板存整个 prompt，那"自定义模板"就变成让用户重写铁律和整理要求——
// 既容易改坏，也不是用户想做的事。所以模板只负责 ③，
// ①②由 AiService 恒定拼在前面。这样用户改模板不会碰到防编造的底线。
//
// 【为什么章节要带 requirements 而不是只给标题】
// 只给"# 知识点结构"这种标题，模型不知道该写到什么颗粒度。
// 经验是：每一节必须带一句"这节该写什么"的说明，产出质量差别很大。
import 'dart:convert';

/// 模板里的一节
class TemplateSection {
  final String title;

  /// 是否必需。非必需节模型可以写「未提及」，但依然要出现在输出里——
  /// 结构完整性比"每节都有内容"更重要，用户能一眼看出哪里是空的。
  final bool required;

  /// 这一节该写什么。会作为「本节要求」拼进提示词。
  final List<String> requirements;

  /// 是否强制每条都带原文引用（detail 档会全局强制，这里可以按节单独要求）
  final bool needQuote;

  /// 是否要求用表格
  final bool needTable;

  const TemplateSection({
    required this.title,
    this.required = true,
    this.requirements = const [],
    this.needQuote = false,
    this.needTable = false,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'required': required,
        if (requirements.isNotEmpty) 'requirements': requirements,
        if (needQuote) 'needQuote': needQuote,
        if (needTable) 'needTable': needTable,
      };

  factory TemplateSection.fromJson(Map<String, dynamic> json) =>
      TemplateSection(
        title: (json['title'] as String?)?.trim() ?? '',
        required: json['required'] as bool? ?? true,
        requirements: (json['requirements'] as List?)
                ?.map((e) => e.toString())
                .where((e) => e.trim().isNotEmpty)
                .toList() ??
            const [],
        needQuote: json['needQuote'] as bool? ?? false,
        needTable: json['needTable'] as bool? ?? false,
      );

  /// 渲染成提示词片段
  String render() {
    final b = StringBuffer('# $title');
    final notes = <String>[];
    if (!required) notes.add('本节无内容时写「未提及」，但标题必须保留');
    if (needTable) notes.add('用 Markdown 表格呈现');
    if (needQuote) notes.add('每条都要带「原文引用」');
    notes.addAll(requirements);
    if (notes.isNotEmpty) {
      for (final n in notes) {
        b.write('\n- $n');
      }
    }
    return b.toString();
  }
}

/// 笔记模板
class NoteTemplate {
  final String id;
  final String name;

  /// 适用场景的说明，显示在模板选择面板里
  final String scene;

  /// 绑定课程（空表示通用）。只有课程名包含该串时才自动匹配。
  final String course;

  final List<TemplateSection> sections;

  /// 是否内置。内置模板不可删除，但可以复制成自定义再改。
  final bool builtin;

  final int sortOrder;

  const NoteTemplate({
    required this.id,
    required this.name,
    this.scene = '',
    this.course = '',
    required this.sections,
    this.builtin = false,
    this.sortOrder = 0,
  });

  /// 该模板是否适用于某课程
  bool matchesCourse(String courseName) {
    if (course.isEmpty) return true;
    final c = courseName.trim();
    if (c.isEmpty) return false;
    return c.contains(course) || course.contains(c);
  }

  /// 章节标题列表（导图分支的默认来源）
  List<String> get sectionTitles => sections.map((s) => s.title).toList();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (scene.isNotEmpty) 'scene': scene,
        if (course.isNotEmpty) 'course': course,
        'sections': sections.map((s) => s.toJson()).toList(),
        'builtin': builtin,
        'sortOrder': sortOrder,
      };

  factory NoteTemplate.fromJson(Map<String, dynamic> json) => NoteTemplate(
        id: (json['id'] as String?)?.trim() ?? '',
        name: (json['name'] as String?)?.trim() ?? '',
        scene: json['scene'] as String? ?? '',
        course: json['course'] as String? ?? '',
        sections: ((json['sections'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TemplateSection.fromJson)
            .toList(),
        builtin: json['builtin'] as bool? ?? false,
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      );

  String encode() => jsonEncode(toJson());

  static NoteTemplate? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final t = NoteTemplate.fromJson(decoded);
      // 没章节的模板没意义，当作解析失败
      return t.sections.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  NoteTemplate copyWith({
    String? id,
    String? name,
    String? scene,
    String? course,
    List<TemplateSection>? sections,
    bool? builtin,
    int? sortOrder,
  }) =>
      NoteTemplate(
        id: id ?? this.id,
        name: name ?? this.name,
        scene: scene ?? this.scene,
        course: course ?? this.course,
        sections: sections ?? this.sections,
        builtin: builtin ?? this.builtin,
        sortOrder: sortOrder ?? this.sortOrder,
      );
}