// lib/models/course_location.dart
// 一次录音的「位置」：课程 → 教材 → 章 → 节。
//
// 【为什么单独一个值对象】
// 这个位置会被五个地方用到：术语表生成、纠错缓存键、总结提示词、Wiki 出处、检索过滤。
// 如果每处自己拼字符串，就一定会出现「预生成时写的是『第五章 被子植物 第二节 木兰科』、
// 纠错时查的是『被子植物』」这种对不上的情况——缓存永远 miss，而且很难发现。
//
// 所以 chapterKey 是唯一真值，所有下游都从它派生，页面只负责把值填进来。

import 'textbook.dart';

class CourseLocation {
  final String course;
  final Textbook? textbook;
  final Chapter? chapter;
  final Section? section;

  const CourseLocation({
    this.course = '',
    this.textbook,
    this.chapter,
    this.section,
  });

  static const CourseLocation empty = CourseLocation();

  bool get hasTextbook => textbook != null;
  bool get hasChapter => chapter != null;
  bool get hasSection => section != null;

  /// 有没有选到章或节。只选了教材不算「定位」。
  bool get hasPosition => chapter != null || section != null;

  bool get isEmpty =>
      course.trim().isEmpty &&
      textbook == null &&
      chapter == null &&
      section == null;

  /// 下游唯一真值：术语缓存键、提示词里的「章节主题」、ClassroomRequest.chapter。
  /// 没选章节时是空串——正好等于改造前的行为。
  String get chapterKey {
    final parts = <String>[];
    final c = chapter;
    if (c != null) {
      final seg =
          [c.no.trim(), c.title.trim()].where((s) => s.isNotEmpty).join(' ');
      if (seg.isNotEmpty) parts.add(seg);
    }
    final s = section;
    if (s != null) {
      final seg =
          [s.no.trim(), s.title.trim()].where((x) => x.isNotEmpty).join(' ');
      if (seg.isNotEmpty) parts.add(seg);
    }
    return parts.join(' ');
  }

  /// 给 prepare(material:) 用：「植物学（第三版），方炎明 主编，中国林业出版社」
  String get materialLine => textbook?.materialLine ?? '';

  /// 界面顶部常驻：「植物学（第三版）· 第五章 被子植物 · 第二节 木兰科」
  String get displayLine {
    final parts = <String>[];
    final tb = textbook;
    if (tb != null) {
      parts.add(tb.displayTitle);
    } else if (course.trim().isNotEmpty) {
      parts.add(course.trim());
    }
    final c = chapter;
    if (c != null) parts.add(c.displayName);
    final s = section;
    if (s != null) parts.add(s.displayName);
    return parts.join(' · ');
  }

  CourseLocation copyWith({
    String? course,
    Textbook? textbook,
    bool clearTextbook = false,
    Chapter? chapter,
    bool clearChapter = false,
    Section? section,
    bool clearSection = false,
  }) {
    return CourseLocation(
      course: course ?? this.course,
      textbook: clearTextbook ? null : (textbook ?? this.textbook),
      chapter: clearChapter ? null : (chapter ?? this.chapter),
      // 章被清掉时节也就没有意义了，一起清
      section: (clearChapter || clearSection)
          ? null
          : (section ?? this.section),
    );
  }

  @override
  String toString() => 'CourseLocation($displayLine)';
}