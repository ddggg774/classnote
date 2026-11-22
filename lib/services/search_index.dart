// lib/services/search_index.dart
// 跨笔记检索：中文 bigram 倒排索引。
//
// 【为什么不用 FTS5】
// sqflite 走的是 Android 系统自带的 SQLite。FTS5 需要编译时启用
// SQLITE_ENABLE_FTS5——AOSP 从 API 26 起默认开，但厂商 ROM 会裁剪，
// 一旦不可用就是 CREATE VIRTUAL TABLE 直接抛异常，整条检索链路崩掉。
// 普通表 + 自己切词 100% 可用，排序逻辑也完全在自己手里。
//
// 【为什么中文用 bigram】
// 中文没有空格分词。「木兰科」切两刀得到「木兰」「兰科」，
// 查询时同样切，于是「离生心皮」能命中原文里写成「离心皮」的段落
// （共享「心皮」这个 bigram）。这是不引入分词词典的可行解。
//
// 【单字怎么办】
// 单个汉字（如「叶」）切不出 bigram。这时直接用 LIKE 扫描兜底——
// 笔记量在几十到几百篇的量级，LIKE 扫一遍代价可接受，
// 不值得为它把索引体积翻倍。
import 'package:sqflite/sqflite.dart';

/// 索引字段及其权重。标题命中 > 总结命中 > 原文命中。
/// 权重直接影响排序：搜「木兰科」时，标题里带木兰科的笔记应该排在前面。
class IndexField {
  const IndexField._();
  static const String title = 'title';
  static const String summary = 'summary';
  static const String transcript = 'transcript';

  /// 英语课的中文译文（与 transcript 同权重），让中文关键词也能搜到外语笔记
  static const String translation = 'translation';

  static int weightOf(String field) {
    switch (field) {
      case title:
        return 3;
      case summary:
        return 2;
      case transcript:
      case translation:
      default:
        return 1;
    }
  }
}

/// 一条检索结果
class SearchHit {
  final String noteId;
  final String title;
  final String course;

  /// 命中处的上下文片段（原文，不是 bigram）
  final String snippet;

  /// 命中位置（在 transcript 里的字符偏移），-1 表示只在标题/总结里命中
  final int position;

  /// 命中的 bigram 数量（用于调试与排序解释）
  final int matchedTerms;

  /// 打分
  final int score;

  const SearchHit({
    required this.noteId,
    required this.title,
    required this.course,
    required this.snippet,
    required this.position,
    required this.matchedTerms,
    required this.score,
  });
}

/// 一个待索引的文档
class IndexDoc {
  final String noteId;
  final String title;
  final String course;
  final String transcript;
  final String summary;

  /// 英语课的中文译文（中文笔记为空）
  final String translation;

  const IndexDoc({
    required this.noteId,
    required this.title,
    this.course = '',
    required this.transcript,
    this.summary = '',
    this.translation = '',
  });
}

class SearchIndex {
  /// bigram 之外的兜底阈值：查询串短于这个长度时走 LIKE 扫描
  static const int minBigramQueryLength = 2;

  /// 单条笔记最多索引多少个不同 bigram（防超长笔记把索引撑爆）
  static const int maxTermsPerField = 4000;

  final Database Function() _openDb;

  SearchIndex(this._openDb);

  // ───────────────────── 建表 / 迁移 ─────────────────────

  /// 建索引表。用 IF NOT EXISTS 保证迁移可重入。
  static Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS search_terms (
        term TEXT NOT NULL,
        note_id TEXT NOT NULL,
        field TEXT NOT NULL,
        freq INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (term, note_id, field)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_search_term ON search_terms(term)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_search_note ON search_terms(note_id)',
    );
  }

  // ───────────────────── 切词 ─────────────────────

  /// 把文本切成可索引的 term。
  ///
  /// 规则：
  ///   · 连续汉字 → 全部 bigram（「木兰科」→ 木兰、兰科）
  ///   · 连续英数 → 整词小写，并额外加「前 3~6 字符前缀」以便部分匹配
  ///   · 标点、空白、emoji → 丢弃
  ///
  /// 不做去停用词：中文停用词（的、了）在 bigram 里影响很小，
  /// 去掉反而可能误伤「的确」「了解」这类正常组合。
  static List<String> tokenize(String text) {
    if (text.isEmpty) return const [];
    final out = <String>{};

    // 用正则把文本切成「汉字串」和「英数串」
    final re = RegExp(r'[\u4e00-\u9fa5]+|[a-zA-Z0-9]+');
    for (final m in re.allMatches(text)) {
      final seg = m.group(0)!;
      if (RegExp(r'^[a-zA-Z0-9]+$').hasMatch(seg)) {
        final word = seg.toLowerCase();
        out.add(word);
        // 英文/拼音缩写常被念半截，加前缀提升部分匹配
        for (var len = 3; len < word.length && len <= 6; len++) {
          out.add(word.substring(0, len));
        }
      } else {
        if (seg.length == 1) {
          // 单个汉字：保留 unigram，否则「叶」「花」这类查不到
          out.add(seg);
        } else {
          for (var i = 0; i + 2 <= seg.length; i++) {
            out.add(seg.substring(i, i + 2));
          }
        }
      }
    }
    return out.toList();
  }

  /// 查询串切词。单字中文保留，因为要走去 unigram 路径。
  static List<String> tokenizeQuery(String query) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    return tokenize(q);
  }

  // ───────────────────── 写入索引 ─────────────────────

  /// 重建一条笔记的索引（先删后插）。
  /// 笔记更新时调它，天然幂等，不会留下旧 term。
  Future<void> indexDoc(IndexDoc doc, {Database? db}) async {
    final database = db ?? _openDb();
    await database.delete(
      'search_terms',
      where: 'note_id = ?',
      whereArgs: [doc.noteId],
    );

    final batch = database.batch();
    void addField(String field, String text) {
      if (text.trim().isEmpty) return;
      final terms = tokenize(text);
      // 超长文档截断，避免单篇把索引撑爆
      final limited = terms.length > maxTermsPerField
          ? terms.take(maxTermsPerField)
          : terms;
      for (final t in limited) {
        batch.insert(
          'search_terms',
          {
            'term': t,
            'note_id': doc.noteId,
            'field': field,
            'freq': 1,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }

    addField(IndexField.title, doc.title);
    addField(IndexField.summary, doc.summary);
    addField(IndexField.transcript, doc.transcript);
    addField(IndexField.translation, doc.translation);
    await batch.commit(noResult: true);
  }

  /// 删除一条笔记的索引
  Future<void> removeDoc(String noteId, {Database? db}) async {
    final database = db ?? _openDb();
    await database.delete(
      'search_terms',
      where: 'note_id = ?',
      whereArgs: [noteId],
    );
  }

  /// 清空全部索引（「重建索引」前调用）
  Future<void> clear({Database? db}) async {
    final database = db ?? _openDb();
    await database.delete('search_terms');
  }

  // ───────────────────── 查询 ─────────────────────

  /// 在索引里检索，返回按分数降序的 noteId 与分数。
  ///
  /// 打分：每个命中的 term 按「字段权重 × min(频次, 3)」累加。
  /// 不用 BM25 是因为笔记量小（几十到几百篇），
  /// 精致的长尾归一化带来的差别用户感知不到，反而更难调。
  Future<List<({String noteId, int score, int matched})>> searchRaw(
    String query, {
    Database? db,
    int limit = 50,
  }) async {
    final database = db ?? _openDb();
    final terms = tokenizeQuery(query);
    if (terms.isEmpty) return [];

    final placeholders = List.filled(terms.length, '?').join(',');
    final rows = await database.rawQuery('''
      SELECT note_id, field, freq
      FROM search_terms
      WHERE term IN ($placeholders)
    ''', terms);

    final scores = <String, int>{};
    final matched = <String, Set<String>>{};
    for (final r in rows) {
      final noteId = r['note_id'] as String;
      final field = r['field'] as String? ?? IndexField.transcript;
      final freq = (r['freq'] as num?)?.toInt() ?? 1;
      final weight = IndexField.weightOf(field);
      scores[noteId] = (scores[noteId] ?? 0) + weight * (freq > 3 ? 3 : freq);
      matched.putIfAbsent(noteId, () => <String>{}).add(field);
    }

    final out = scores.entries
        .map((e) => (
              noteId: e.key,
              score: e.value,
              matched: matched[e.key]?.length ?? 0,
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// 单字查询兜底：直接扫 notes 表的三个字段。
  /// 只用于 query 长度不足 minBigramQueryLength 的情况。
  Future<List<String>> searchShortQuery(
    String query, {
    Database? db,
    int limit = 50,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final database = db ?? _openDb();
    final like = '%$q%';
    final rows = await database.rawQuery('''
      SELECT id FROM notes
      WHERE title LIKE ? OR transcript LIKE ? OR summary_json LIKE ?
      ORDER BY created_at DESC
      LIMIT ?
    ''', [like, like, like, limit]);
    return rows.map((r) => r['id'] as String).toList();
  }

  // ───────────────────── 高亮片段 ─────────────────────

  /// 从原文里截取命中处的上下文。
  ///
  /// 为什么不用 bigram 定位：bigram 是切碎的词，位置无法还原到原句。
  /// 直接用原始查询串 indexOf，和 pending_fixer 的定位思路一致——
  /// 简单、准确、可预测。
  static ({String snippet, int position}) locate(
    String text,
    String query, {
    int contextChars = 40,
  }) {
    final q = query.trim();
    if (text.isEmpty || q.isEmpty) {
      return (snippet: text.length > 80 ? '${text.substring(0, 80)}…' : text, position: -1);
    }

    // 多词查询时优先找最长的那一段，命中概率更高
    final parts = q
        .split(RegExp(r'[\s,，、;；]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final keywords = parts.isEmpty ? [q] : parts;

    var hitAt = -1;
    var hitWord = '';
    for (final w in keywords) {
      final idx = text.indexOf(w);
      if (idx >= 0) {
        hitAt = idx;
        hitWord = w;
        break;
      }
    }
    if (hitAt < 0) {
      return (
        snippet: text.length > 80 ? '${text.substring(0, 80)}…' : text,
        position: -1,
      );
    }

    final start = (hitAt - contextChars).clamp(0, text.length);
    final end = (hitAt + hitWord.length + contextChars).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return (
      snippet: '$prefix${text.substring(start, end)}$suffix',
      position: hitAt,
    );
  }
}