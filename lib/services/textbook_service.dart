// lib/services/textbook_service.dart
// 教材库的读写：教材 CRUD + 章节目录存取。
//
// 页面不直接碰数据库，统一走这里（与 DbService 的分工一致：
// DbService 管 note/模板/wiki，教材相关表由本服务封装）。
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

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