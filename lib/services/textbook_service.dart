// lib/services/textbook_service.dart
// 教材库的读写：教材 CRUD + 章节目录存取。
//
// 页面不直接碰数据库，统一走这里（与 DbService 的分工一致：
// DbService 管 note/模板/wiki，教材相关表由本服务封装）。
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/course_location.dart';
import '../models/textbook.dart';
import 'db_service.dart';
import 'toc_parser.dart';

class TextbookService {
  final DbService _db;

  TextbookService([DbService? db]) : _db = db ?? DbService();

  // ───────────────────── 教材 ─────────────────────

  /// 全部教材，按课程分组顺序 → 组内自定义排序
  Future<List<Textbook>> listAll() async {
    final db = await _db.database;
    final rows = await db.query(
      'textbooks',
      orderBy: 'course ASC, sort_order ASC, created_at ASC',
    );
    return rows.map(Textbook.fromMap).toList();
  }

  /// 某门课的教材（可能多个版本）
  Future<List<Textbook>> listByCourse(String course) async {
    final q = course.trim();
    if (q.isEmpty) return const [];
    final db = await _db.database;
    final rows = await db.query(
      'textbooks',
      where: 'course = ?',
      whereArgs: [q],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(Textbook.fromMap).toList();
  }

  Future<Textbook?> byId(String id) async {
    final db = await _db.database;
    final rows =
        await db.query('textbooks', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Textbook.fromMap(rows.first);
  }

  /// 按课程名找教材：先精确，再像 config.textbookOf 那样双向 contains。
  /// 找不到返回 null——不猜，让界面显示「未选教材」。
  Future<Textbook?> matchCourse(String courseName) async {
    final q = courseName.trim();
    if (q.isEmpty) return null;
    final all = await listAll();
    if (all.isEmpty) return null;
    for (final t in all) {
      if (t.course == q) return t;
    }
    for (final t in all) {
      if (q.contains(t.course) || t.course.contains(q)) return t;
    }
    return null;
  }

  Future<void> save(Textbook textbook) async {
    final db = await _db.database;
    await db.insert(
      'textbooks',
      {
        ...textbook.toMap(),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删除教材，一并删掉它的章与节。笔记里记录的位置字段保持原样
  /// （那是历史记录，不该因为教材被删就消失）。
  Future<void> delete(String id) async {
    final db = await _db.database;
    final chapters =
        await db.query('chapters', columns: ['id'], where: 'textbook_id = ?', whereArgs: [id]);
    await db.transaction((txn) async {
      for (final c in chapters) {
        await txn.delete('sections',
            where: 'chapter_id = ?', whereArgs: [c['id']]);
      }
      await txn.delete('chapters', where: 'textbook_id = ?', whereArgs: [id]);
      await txn.delete('textbooks', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ───────────────────── 目录 ─────────────────────

  Future<List<Chapter>> chaptersOf(String textbookId) async {
    final db = await _db.database;
    final rows = await db.query(
      'chapters',
      where: 'textbook_id = ?',
      whereArgs: [textbookId],
      orderBy: 'sort_order ASC',
    );
    return rows.map(Chapter.fromMap).toList();
  }

  Future<List<Section>> sectionsOf(String chapterId) async {
    final db = await _db.database;
    final rows = await db.query(
      'sections',
      where: 'chapter_id = ?',
      whereArgs: [chapterId],
      orderBy: 'sort_order ASC',
    );
    return rows.map(Section.fromMap).toList();
  }

  /// 整本书的节，按 chapterId 分组。
  ///
  /// 目录选择器要用：一本书有十几章上百节，逐章查是 N 次往返，
  /// 一条 JOIN 拿全更省事。
  Future<Map<String, List<Section>>> sectionMapOf(String textbookId) async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT s.* FROM sections s '
      'JOIN chapters c ON s.chapter_id = c.id '
      'WHERE c.textbook_id = ? '
      'ORDER BY s.sort_order ASC',
      [textbookId],
    );
    final out = <String, List<Section>>{};
    for (final r in rows) {
      final s = Section.fromMap(r);
      out.putIfAbsent(s.chapterId, () => []).add(s);
    }
    return out;
  }

  /// 用笔记里存的五个字段还原出可用的位置对象。
  ///
  /// 教材可能已经被删、目录可能被重录过——那就逐级降级：
  /// 找不到章节就只显示教材，找不到教材就只剩课程。绝不抛异常，
  /// 详情页打开的是一条老笔记，不该因为教材没了就打不开。
  Future<CourseLocation> resolve({
    required String course,
    String? textbookId,
    String? chapterNo,
    String? chapterTitle,
    String? sectionNo,
    String? sectionTitle,
  }) async {
    final c = course.trim();
    Textbook? book;
    final id = (textbookId ?? '').trim();
    if (id.isNotEmpty) {
      // 明确记过是哪本教材，就一定按那本来。找不到就只显示课程——
      // 不能再按课程名去猜一本，否则会把章节挂到另一个版本的同名章上，
      // 用户看到的是「第五章 被子植物」，实际对应的可能不是他用那本书。
      book = await byId(id);
    } else {
      // 老笔记没有 textbook_id，只能按课程模糊匹配
      book = await matchCourse(c);
    }

    Chapter? chapter;
    Section? section;
    if (book != null) {
      final chapters = await chaptersOf(book.id);
      chapter = _matchChapter(chapters, chapterNo, chapterTitle);
      final sNo = (sectionNo ?? '').trim();
      final sTitle = (sectionTitle ?? '').trim();
      if (chapter != null && (sNo.isNotEmpty || sTitle.isNotEmpty)) {
        section = _matchSection(await sectionsOf(chapter.id), sectionNo, sectionTitle);
      }
    }

    return CourseLocation(
      course: c,
      textbook: book,
      chapter: chapter,
      section: section,
    );
  }

  static Chapter? _matchChapter(
      List<Chapter> list, String? no, String? title) {
    final n = (no ?? '').trim();
    final t = (title ?? '').trim();
    if (n.isEmpty && t.isEmpty) return null;
    for (final c in list) {
      if (c.no.trim() == n && c.title.trim() == t) return c;
    }
    for (final c in list) {
      if (t.isNotEmpty && c.title.trim() == t) return c;
    }
    for (final c in list) {
      if (n.isNotEmpty && c.no.trim() == n) return c;
    }
    return null;
  }

  static Section? _matchSection(
      List<Section> list, String? no, String? title) {
    final n = (no ?? '').trim();
    final t = (title ?? '').trim();
    if (n.isEmpty && t.isEmpty) return null;
    for (final s in list) {
      if (s.no.trim() == n && s.title.trim() == t) return s;
    }
    for (final s in list) {
      if (t.isNotEmpty && s.title.trim() == t) return s;
    }
    for (final s in list) {
      if (n.isNotEmpty && s.no.trim() == n) return s;
    }
    return null;
  }

  /// 整本目录读成解析结构（编辑页保存时也用它做全量覆盖）
  Future<TocData> tocOf(String textbookId) async {
    final chapters = await chaptersOf(textbookId);
    final out = <TocChapter>[];
    for (final c in chapters) {
      final sections = await sectionsOf(c.id);
      out.add(TocChapter(
        no: c.no,
        title: c.title,
        sections: sections
            .map((s) => TocSection(no: s.no, title: s.title))
            .toList(),
      ));
    }
    return TocData(chapters: out);
  }

  /// 全量覆盖目录：先清空再写入（编辑/粘贴都走这一条，避免增量合并的边界问题）。
  ///
  /// 空目录 = 清空：toc_source 回到 none，不假装录入过。
  Future<void> saveToc(
    String textbookId,
    TocData toc, {
    required String source,
  }) async {
    final db = await _db.database;
    const uuid = Uuid();
    final chapters = toc.chapters;

    await db.transaction((txn) async {
      final old = await txn.query(
        'chapters',
        columns: ['id'],
        where: 'textbook_id = ?',
        whereArgs: [textbookId],
      );
      for (final c in old) {
        await txn.delete('sections',
            where: 'chapter_id = ?', whereArgs: [c['id']]);
      }
      await txn.delete('chapters',
          where: 'textbook_id = ?', whereArgs: [textbookId]);

      for (var i = 0; i < chapters.length; i++) {
        final c = chapters[i];
        final chapterId = uuid.v4();
        await txn.insert('chapters', {
          'id': chapterId,
          'textbook_id': textbookId,
          'no': c.no,
          'title': c.title,
          'sort_order': i,
        });
        for (var j = 0; j < c.sections.length; j++) {
          final s = c.sections[j];
          await txn.insert('sections', {
            'id': uuid.v4(),
            'chapter_id': chapterId,
            'no': s.no,
            'title': s.title,
            'sort_order': j,
          });
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'textbooks',
        {
          'toc_source': chapters.isEmpty ? Textbook.tocNone : source,
          'toc_updated_at': chapters.isEmpty ? null : now,
        },
        where: 'id = ?',
        whereArgs: [textbookId],
      );
    });
  }

  Future<void> clearToc(String textbookId) async {
    await saveToc(textbookId, TocData.empty, source: Textbook.tocManual);
  }
}