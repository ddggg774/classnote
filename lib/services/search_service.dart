// lib/services/search_service.dart
// 检索的业务层：把索引结果拼回可展示的 SearchHit。
//
// 【分层理由】
// SearchIndex 只管「bigram 怎么切、SQL 怎么查、分数怎么算」，
// 不依赖 Note 模型；这一层负责把 noteId 换成带标题/课程/高亮的完整结果。
// 这样索引层能脱离数据库单测，业务层也能换数据源。
import '../models/note.dart';
import '../models/study_note.dart';
import 'db_service.dart';
import 'search_index.dart';
import 'translation_service.dart';

class SearchService {
  final DbService _db;

  SearchService([DbService? db]) : _db = db ?? DbService();

  /// 检索。返回按相关度降序的命中列表。
  ///
  /// [course] 非空时只搜该课程。
  Future<List<SearchHit>> search(
    String query, {
    String? course,
    int limit = 30,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final db = await _db.database;
    final index = _db.index;

    // 单字/极短查询：bigram 切不出来，直接 LIKE 扫表兜底
    final useShortPath = q.length < SearchIndex.minBigramQueryLength;

    List<({String noteId, int score, int matched})> ranked;
    if (useShortPath) {
      final ids = await index.searchShortQuery(q, db: db, limit: limit);
      ranked = ids
          .map((id) => (noteId: id, score: 1, matched: 1))
          .toList();
    } else {
      ranked = await index.searchRaw(q, db: db, limit: limit * 2);
    }
    if (ranked.isEmpty) return [];

    // 批量取笔记，避免 N+1 查询
    final notes = <String, Note>{};
    for (final r in ranked) {
      final n = await _db.queryById(r.noteId);
      if (n != null) notes[r.noteId] = n;
    }

    final hits = <SearchHit>[];
    for (final r in ranked) {
      final note = notes[r.noteId];
      if (note == null) continue;
      // 课程过滤放在取到 Note 之后：索引里存了 course，但老笔记可能是空，
      // 用 effectiveCourse 判断才不会漏掉老数据。
      if (course != null &&
          course.trim().isNotEmpty &&
          note.effectiveCourse != course.trim()) {
        continue;
      }

      // 用原始查询串在原文里定位，bigram 位置还原不到原句
      var located = SearchIndex.locate(note.transcript, q);
      // 中文关键词命中英语课的译文时，原文里找不到这个词——
      // 这时退到译文里定位，否则搜索结果会显示一段与关键词无关的原文
      if (located.position < 0) {
        final translation = _translationOf(note);
        if (translation.trim().isNotEmpty) {
          final inTranslation = SearchIndex.locate(translation, q);
          if (inTranslation.position >= 0) {
            located = (
              snippet: '〔译文〕${inTranslation.snippet}',
              position: -1,
            );
          }
        }
      }
      hits.add(SearchHit(
        noteId: note.id,
        title: note.title,
        course: note.effectiveCourse,
        snippet: located.snippet,
        position: located.position,
        matchedTerms: r.matched,
        score: r.score,
      ));
    }
    return hits;
  }

  /// 按 ID 取一条笔记（搜索页跳转、RAG 取原文都用它）
  Future<Note?> noteById(String id) => _db.queryById(id);

  /// 重建全部索引。
  ///
  /// 什么时候需要：① 从旧版本升级上来（迁移时不会自动灌历史数据）；
  /// ② 索引出现异常（比如某次保存时索引写失败被吞了）。
  /// 返回重建的笔记条数。
  Future<int> rebuildAll({void Function(int done, int total)? onProgress}) async {
    final db = await _db.database;
    final index = _db.index;
    await index.clear(db: db);

    final notes = await _db.queryAll();
    // 草稿不建索引，与增量同步保持一致
    final targets = notes.where((n) => !n.isDraft).toList();

    var done = 0;
    for (final note in targets) {
      try {
        await index.indexDoc(
          IndexDoc(
            noteId: note.id,
            title: note.title,
            course: note.effectiveCourse,
            transcript: note.transcript,
            summary: _summaryOf(note),
            translation: _translationOf(note),
          ),
          db: db,
        );
      } catch (_) {
        // 单篇失败不中断整体，跳过继续
      }
      done++;
      onProgress?.call(done, targets.length);
    }
    return done;
  }

  /// 索引里的条目数（界面诊断用，能看出索引进度）
  Future<int> indexTermCount() async {
    final db = await _db.database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM search_terms');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 只索引总结的正文，不索引导图 JSON——
  /// 导图里的 id/title 字段会给索引灌进大量噪音。
  /// 直接复用 StudySummary.tryDecode，它已经处理了三种历史格式。
  static String _summaryOf(Note note) {
    final parsed = StudySummary.tryDecode(note.summaryJson);
    return parsed?.detailMarkdown ?? '';
  }

  /// 英语课的译文也进索引：中文关键词才能搜到外语笔记
  static String _translationOf(Note note) {
    final parsed = TranslationResult.tryDecode(note.translationJson);
    if (parsed == null) return '';
    return parsed.pairs.map((p) => p.target).join('\n');
  }
}
