// lib/models/textbook.dart
// 教材、章、节的数据模型。
//
// 【为什么教材要从 config.dart 的常量升级成表】
// config.dart 里三本教材只有书名/编者/出版社四个字段，且是 const：
// 不能增删改、不能多版本并存、没有目录。而「课前定位」需要知道
// 「植物学（第三版）· 第五章 被子植物 · 第二节 木兰科」这种粒度。
//
// 【章号存原文】
// 「第五章」就存「第五章」，不规范化成 5。老师口头说的是「第五章」，
// 教材印的也是「第五章」，原样存界面直接可用；排序靠 sort_order，
// 不靠解析 no。规范化还会把「上篇/下篇」「附录」这类结构吃掉。

/// 一本教材
class Textbook {
  /// 目录来源：用户逐条手打的
  static const String tocManual = 'manual';

  /// 目录来源：从电子版/官网粘贴后解析的
  static const String tocPasted = 'pasted';

  /// 目录来源：还没录入
  static const String tocNone = 'none';

  final String id;

  /// 课程名，与 notes.course 同一套写法（用于按课程带出教材）
  final String course;

  /// 书名原文，如「植物学（第三版）」
  final String title;

  /// 版次，如「第三版」
  final String edition;

  /// 编者，如「方炎明 主编」
  final String author;

  /// 出版社，如「中国林业出版社」
  final String publisher;

  /// 出版年（可空）
  final String year;

  /// ISBN（可空，用于唯一标识版本）
  final String isbn;

  /// manual / pasted / none
  final String tocSource;

  final DateTime? tocUpdatedAt;

  final int sortOrder;

  Textbook({
    required this.id,
    required this.course,
    required this.title,
    this.edition = '',
    this.author = '',
    this.publisher = '',
    this.year = '',
    this.isbn = '',
    this.tocSource = tocNone,
    this.tocUpdatedAt,
    this.sortOrder = 0,
  });

  /// 显示用书名：版次已经写在书名里就不再补一次（种子数据就是这种）
  String get displayTitle {
    final e = edition.trim();
    if (e.isEmpty) return title;
    if (title.contains(e)) return title;
    return '$title（$e）';
  }

  /// 给提示词用的教材描述：「植物学（第三版），方炎明 主编，中国林业出版社」
  String get materialLine {
    return [displayTitle, author.trim(), publisher.trim()]
        .where((s) => s.isNotEmpty)
        .join('，');
  }

  String get tocSourceLabel {
    switch (tocSource) {
      case tocManual:
        return '手动录入';
      case tocPasted:
        return '粘贴导入';
      default:
        return '未录入';
    }
  }

  bool get hasToc => tocSource != tocNone;

  factory Textbook.fromMap(Map<String, dynamic> map) {
    final updated = map['toc_updated_at'] as int?;
    return Textbook(
      id: map['id'] as String,
      course: (map['course'] as String?) ?? '',
      title: (map['title'] as String?) ?? '',
      edition: (map['edition'] as String?) ?? '',
      author: (map['author'] as String?) ?? '',
      publisher: (map['publisher'] as String?) ?? '',
      year: (map['year'] as String?) ?? '',
      isbn: (map['isbn'] as String?) ?? '',
      tocSource: (map['toc_source'] as String?) ?? tocNone,
      tocUpdatedAt:
          updated == null ? null : DateTime.fromMillisecondsSinceEpoch(updated),
      sortOrder: (map['sort_order'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'course': course,
      'title': title,
      'edition': edition,
      'author': author,
      'publisher': publisher,
      'year': year,
      'isbn': isbn,
      'toc_source': tocSource,
      'toc_updated_at': tocUpdatedAt?.millisecondsSinceEpoch,
      'sort_order': sortOrder,
    };
  }

  Textbook copyWith({
    String? course,
    String? title,
    String? edition,
    String? author,
    String? publisher,
    String? year,
    String? isbn,
    String? tocSource,
    DateTime? tocUpdatedAt,
    int? sortOrder,
  }) {
    return Textbook(
      id: id,
      course: course ?? this.course,
      title: title ?? this.title,
      edition: edition ?? this.edition,
      author: author ?? this.author,
      publisher: publisher ?? this.publisher,
      year: year ?? this.year,
      isbn: isbn ?? this.isbn,
      tocSource: tocSource ?? this.tocSource,
      tocUpdatedAt: tocUpdatedAt ?? this.tocUpdatedAt,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

/// 一章
class Chapter {
  final String id;
  final String textbookId;

  /// 章号原文，如「第五章」；「附录」这类没有编号的留空串
  final String no;

  /// 章名，如「被子植物」
  final String title;

  final int sortOrder;

  Chapter({
    required this.id,
    required this.textbookId,
    required this.no,
    required this.title,
    this.sortOrder = 0,
  });

  /// 界面与提示词里的显示名
  String get displayName {
    final n = no.trim();
    return n.isEmpty ? title : '$n $title'.trim();
  }

  factory Chapter.fromMap(Map<String, dynamic> map) {
    return Chapter(
      id: map['id'] as String,
      textbookId: (map['textbook_id'] as String?) ?? '',
      no: (map['no'] as String?) ?? '',
      title: (map['title'] as String?) ?? '',
      sortOrder: (map['sort_order'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'textbook_id': textbookId,
      'no': no,
      'title': title,
      'sort_order': sortOrder,
    };
  }
}

/// 一节
class Section {
  final String id;
  final String chapterId;

  /// 节号原文，如「第二节」
  final String no;

  /// 节名，如「木兰科」
  final String title;

  final int sortOrder;

  Section({
    required this.id,
    required this.chapterId,
    required this.no,
    required this.title,
    this.sortOrder = 0,
  });

  String get displayName {
    final n = no.trim();
    return n.isEmpty ? title : '$n $title'.trim();
  }

  factory Section.fromMap(Map<String, dynamic> map) {
    return Section(
      id: map['id'] as String,
      chapterId: (map['chapter_id'] as String?) ?? '',
      no: (map['no'] as String?) ?? '',
      title: (map['title'] as String?) ?? '',
      sortOrder: (map['sort_order'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'chapter_id': chapterId,
      'no': no,
      'title': title,
      'sort_order': sortOrder,
    };
  }
}