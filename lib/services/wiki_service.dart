// lib/services/wiki_service.dart
// 知识库：从笔记里抽取词条，维护「课程级」的知识沉淀。
//
// 【抽取的核心约束】
// 沿用纠错层的铁律：只抽原文真的讲了的，拿不准就不抽。
// 宁可漏掉十个词条，也不要往知识库里塞一个编造的定义——
// 知识库会被反复阅读，一条错的定义污染的是后续所有复习。
//
// 【冲突为什么不覆盖】
// 同一词条在两节课有不同说法时，谁对谁错只有用户回听原文才知道。
// 程序保留主定义 + 把不一致的记录标出来，让用户裁定。
// 自动"取最新"看起来聪明，但那是在替用户做学术判断。
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models/note.dart';
import '../models/study_note.dart';
import '../models/wiki_entry.dart';
import 'db_service.dart';

class WikiService {
  final DbService _db;
  final String? apiKeyOverride;

  WikiService({DbService? db, this.apiKeyOverride}) : _db = db ?? DbService();

  /// 单次抽取输入的最大字数。太长会稀释注意力，也更容易漏。
  static const int maxInputChars = 12000;

  /// 单条笔记单次最多抽多少个词条。防止一篇长笔记灌进上百条噪音。
  static const int maxCandidatesPerNote = 30;

  static const String extractPrompt = '''
你是课堂知识库的词条抽取器。给你一节课的转写稿，你要从中抽出**可以沉淀成知识库词条**的内容。

## 什么该抽
- 术语/概念：老师给出定义或解释的专业名词
- 公式/定理：有名称、有表达式或有适用条件的
- 人物：老师提到的学者、教材作者（要说明他是谁）
- 易错点：老师明确说"这里容易错""常有人搞混"的地方
- 例题套路：有明确解题方法论的题型

## 什么不该抽（非常重要）
- 只提了名字、**没有给出任何实质内容**的词（比如"还有个概念叫XX，你们自己看书"）
- 口语词、连接词、语气词
- 老师自己也没说清楚的（"那个东西""大概是"）
- 你从学科常识里知道、但**这段转写里没讲**的内容

## 铁律
1. **只抽原文真的讲了的**。原文没说定义，就不要自己补一个。
   这是硬约束：知识库会被反复阅读，一条编造的定义污染后续所有复习。
2. 定义用**原文的意思**重述，不要添加原文没有的细节。
3. 每个词条必须给一段 `snippet`，是支撑这个定义的**原文片段**（逐字摘录，不要改写）。
4. 拿不准是不是正式术语的，宁可不抽。
5. 一节课抽 5~20 个词条为宜，不是越多越好。

## 输出格式
只输出 JSON 数组，不要任何解释文字：
```json
[
  {
    "term": "离生心皮",
    "type": "term",
    "definition": "心皮彼此分离、不愈合的雌蕊类型",
    "variants": ["离心皮"],
    "related": ["心皮", "雌蕊"],
    "snippet": "木兰科是离生心皮，多数螺旋状排列在延长的花托上"
  }
]
```

type 只能是：term（术语）/ person（人物）/ formula（公式定理）/
concept（概念）/ pitfall（易错点）/ problemPattern（例题套路）。
variants 填别称、常见误听写法（可空数组）；related 填关联词条名（可空数组）。
''';

  // ───────────────────── 抽取 ─────────────────────

  /// 从一条笔记抽取词条并入库。
  ///
  /// [apiKey] 为空时从 SettingsService 读（测试里用 apiKeyOverride 注入）。
  /// [force] 为 false 时，如果这条笔记已经抽过就直接跳过。
  ///
  /// 为什么必须默认跳过：模型每次抽取的措辞会变（第一次抽「花被片不分化」，
  /// 第二次可能抽「花被片」），重复抽取会往知识库里灌同义不同名的垃圾词条。
  /// 加了去重也挡不住这种"名字不同算新词条"的情况，所以从源头拦住。
  /// 用户想重抽时传 force=true。
  Future<WikiExtractResult> extractFromNote(
    Note note, {
    String? apiKey,
    String? baseUrlOverride,
    http.Client? httpClient,
    bool force = false,
  }) async {
    final key = apiKey ?? apiKeyOverride ?? '';
    if (key.isEmpty) {
      throw Exception('缺少 API Key，无法抽取词条');
    }
    if (note.isDraft) {
      // 草稿内容还在变，抽了也会过期
      return const WikiExtractResult();
    }

    final course = note.effectiveCourse;
    if (course.trim().isEmpty) {
      throw Exception('这条笔记没有课程名，无法归入知识库');
    }

    if (!force && await hasExtracted(note.id)) {
      // 已经抽过，不重复花钱也不污染知识库
      return const WikiExtractResult();
    }

    final input = await _buildInput(note);
    if (input.trim().length < 50) {
      // 内容太少，抽不出有意义的词条
      return const WikiExtractResult();
    }

    final raw = await _chat(
      apiKey: key,
      system: extractPrompt,
      user: input,
      baseUrlOverride: baseUrlOverride,
      httpClient: httpClient,
    );

    final candidates = parseCandidates(raw);
    if (candidates.isEmpty) return const WikiExtractResult();

    return mergeCandidates(
      course: course,
      note: note,
      candidates: candidates.take(maxCandidatesPerNote).toList(),
    );
  }

  /// 把候选词条并入知识库。
  ///
  /// 三种情况：
  ///   · 词条不存在 → 新建（status=pending，等用户确认）
  ///   · 词条存在且定义实质相同 → 只追加出处
  ///   · 词条存在但定义不一致 → 追加出处并标 conflict，**不覆盖主定义**
  Future<WikiExtractResult> mergeCandidates({
    required String course,
    required Note note,
    required List<WikiCandidate> candidates,
  }) async {
    var created = 0;
    var appended = 0;
    var conflicts = 0;
    var skipped = 0;

    for (final c in candidates) {
      final existing = await findEntry(course, c.term);
      if (existing == null) {
        final now = DateTime.now();
        final entry = WikiEntry(
          id: const Uuid().v4(),
          course: course,
          term: c.term,
          type: c.type,
          definition: c.definition,
          variants: c.variants,
          related: c.related,
          status: WikiEntryStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        await _insertEntry(entry);
        final added = await _insertSource(
          entryId: entry.id,
          note: note,
          snippet: c.snippet.isEmpty ? c.definition : c.snippet,
        );
        if (added) {
          created++;
        } else {
          skipped++;
        }
        continue;
      }

      // 已存在：先看这条出处是不是已经有了（幂等）
      final snippet = c.snippet.isEmpty ? c.definition : c.snippet;
      final duplicate = await _hasSource(existing.id, note.id, snippet);
      if (duplicate) {
        skipped++;
        continue;
      }

      final sameDefinition = definitionsMatch(existing.definition, c.definition);
      final added = await _insertSource(
        entryId: existing.id,
        note: note,
        snippet: snippet,
        conflict: !sameDefinition,
        altDefinition: sameDefinition ? null : c.definition,
      );
      if (!added) {
        skipped++;
        continue;
      }
      if (sameDefinition) {
        appended++;
        // 顺带把新发现的变体并进去（变体会喂给纠错 Agent，越多越准）
        final merged = {...existing.variants, ...c.variants}.toList();
        if (merged.length != existing.variants.length) {
          await _updateEntry(
            existing.copyWith(variants: merged, updatedAt: DateTime.now()),
          );
        }
      } else {
        conflicts++;
      }
    }

    return WikiExtractResult(
      created: created,
      appendedSources: appended,
      conflicts: conflicts,
      skipped: skipped,
    );
  }

  /// 两个定义是否"实质相同"。
  ///
  /// 这里刻意用宽松的文本比对而不是调模型判断：
  /// 判重是确定性问题，不值得为它多花一次调用；
  /// 宽松的后果只是"多标了一处冲突"，用户扫一眼就能排除，
  /// 而漏判的后果是"真冲突被当成一致吞掉"，那才是真损失。
  @visibleForTesting
  static bool definitionsMatch(String a, String b) {
    final na = _normalize(a);
    final nb = _normalize(b);
    if (na == nb) return true;
    if (na.isEmpty || nb.isEmpty) return false;
    // 一方包含另一方时，判断是「同一说法的详略差异」还是「不同说法」。
    // 用绝对长度差 + 长度比双重约束：
    //   · 绝对差太大 → 多出来的是一大段新信息，可能已构成另一种说法
    //   · 长度比太大 → 短的那句只是长句的开头，不是同义
    // 宁可多标冲突（用户扫一眼能排除），也不要漏判（真冲突被吞掉）。
    if (na.contains(nb) || nb.contains(na)) {
      final shorter = na.length < nb.length ? na.length : nb.length;
      final longer = na.length > nb.length ? na.length : nb.length;
      if (longer - shorter <= 8 && longer <= shorter * 3) return true;
    }
    return false;
  }

  static String _normalize(String s) {
    var t = s.trim().toLowerCase();
    // 去掉标点与空白，只比内容
    t = t.replaceAll(RegExp(r'[\s，。、；：,.;:！？!?（）()【】\[\]「」""'']'), '');
    return t;
  }

  // ───────────────────── 查询 ─────────────────────

  /// 按唯一键找词条
  Future<WikiEntry?> findEntry(String course, String term) async {
    final db = await _db.database;
    final rows = await db.query(
      'wiki_entries',
      where: 'course = ? AND term = ?',
      whereArgs: [course.trim(), term.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WikiEntry.fromMap(rows.first);
  }

  /// 列出某课程的全部词条（含未确认的）
  Future<List<WikiEntry>> listByCourse(
    String course, {
    WikiEntryType? type,
    WikiEntryStatus? status,
    String? keyword,
  }) async {
    final db = await _db.database;
    final where = <String>['course = ?'];
    final args = <Object?>[course.trim()];
    if (type != null) {
      where.add('type = ?');
      args.add(type.code);
    }
    if (status != null) {
      where.add('status = ?');
      args.add(status.code);
    }
    if (keyword != null && keyword.trim().isNotEmpty) {
      where.add('(term LIKE ? OR definition LIKE ?)');
      final like = '%${keyword.trim()}%';
      args.addAll([like, like]);
    }
    final rows = await db.query(
      'wiki_entries',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'updated_at DESC',
    );
    return rows.map(WikiEntry.fromMap).toList();
  }

  /// 列出所有出现过词条的课程（知识库首页用）
  Future<List<({String course, int count, int pending})>> courseOverview() async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT course,
             COUNT(*) AS total,
             SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending
      FROM wiki_entries
      GROUP BY course
      ORDER BY course
    ''');
    return rows
        .map((r) => (
              course: r['course'] as String? ?? '',
              count: (r['total'] as num?)?.toInt() ?? 0,
              pending: (r['pending'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  /// 取一个词条的全部出处
  Future<List<WikiSource>> sourcesOf(String entryId) async {
    final db = await _db.database;
    final rows = await db.query(
      'wiki_sources',
      where: 'entry_id = ?',
      whereArgs: [entryId],
      orderBy: 'created_at ASC',
    );
    return rows.map(WikiSource.fromMap).toList();
  }

  /// 某课程所有词条的变体（喂给纠错 Agent 的 lookup_terminology）
  Future<Map<String, List<String>>> variantsOfCourse(String course) async {
    final entries = await listByCourse(course);
    final out = <String, List<String>>{};
    for (final e in entries) {
      if (e.variants.isEmpty) continue;
      out[e.term] = e.variants;
    }
    return out;
  }

  // ───────────────────── 维护 ─────────────────────

  Future<void> confirm(String entryId) async {
    final db = await _db.database;
    await db.update(
      'wiki_entries',
      {
        'status': WikiEntryStatus.confirmed.code,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [entryId],
    );
  }

  Future<void> deleteEntry(String entryId) async {
    final db = await _db.database;
    await db.delete('wiki_sources', where: 'entry_id = ?', whereArgs: [entryId]);
    await db.delete('wiki_entries', where: 'id = ?', whereArgs: [entryId]);
  }

  /// 这条笔记是否已经抽过词条
  Future<bool> hasExtracted(String noteId) async {
    final db = await _db.database;
    final rows = await db.query(
      'wiki_sources',
      where: 'note_id = ?',
      whereArgs: [noteId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<int> countPending() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM wiki_entries WHERE status = 'pending'");
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  // ───────────────────── 内部 ─────────────────────

  Future<void> _insertEntry(WikiEntry entry) async {
    final db = await _db.database;
    await db.insert('wiki_entries', entry.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _updateEntry(WikiEntry entry) async {
    final db = await _db.database;
    await db.update('wiki_entries', entry.toMap(),
        where: 'id = ?', whereArgs: [entry.id]);
  }

  Future<bool> _insertSource({
    required String entryId,
    required Note note,
    required String snippet,
    bool conflict = false,
    String? altDefinition,
  }) async {
    final db = await _db.database;
    final source = WikiSource(
      id: const Uuid().v4(),
      entryId: entryId,
      noteId: note.id,
      noteTitle: note.title,
      snippet: snippet,
      conflict: conflict,
      altDefinition: altDefinition,
      createdAt: DateTime.now(),
    );
    // 唯一索引 (entry_id, note_id, snippet) 保证幂等：
    // 重复插入被 ignore，返回 0 即表示这条出处已经有了。
    final id = await db.insert('wiki_sources', source.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return id != 0;
  }

  Future<bool> _hasSource(String entryId, String noteId, String snippet) async {
    final db = await _db.database;
    final rows = await db.query(
      'wiki_sources',
      where: 'entry_id = ? AND note_id = ? AND snippet = ?',
      whereArgs: [entryId, noteId, snippet],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<String> _buildInput(Note note) async {
    final b = StringBuffer()
      ..writeln('课程：${note.effectiveCourse}')
      ..writeln('笔记标题：${note.title}')
      ..writeln();

    // 把这个课程已有的词条名告诉模型，让它优先复用而不是造近义词。
    // 这是缓解"同义不同名"的第二道防线（第一道是 hasExtracted 直接跳过）。
    try {
      final existing = await listByCourse(note.effectiveCourse);
      if (existing.isNotEmpty) {
        final names = existing.take(40).map((e) => e.term).join('、');
        b
          ..writeln('【本课程知识库里已有的词条（如果这些概念再次出现，请沿用一个名字，不要造近义词）】')
          ..writeln(names)
          ..writeln();
      }
    } catch (_) {}

    final summary = StudySummary.tryDecode(note.summaryJson);
    if (summary != null && summary.detailMarkdown.trim().isNotEmpty) {
      b
        ..writeln('【整理过的笔记】')
        ..writeln(summary.detailMarkdown.length > maxInputChars ~/ 2
            ? '${summary.detailMarkdown.substring(0, maxInputChars ~/ 2)}…'
            : summary.detailMarkdown)
        ..writeln();
    }
    final t = note.transcript;
    b
      ..writeln('【课堂转写原文】')
      ..writeln(t.length > maxInputChars ? '${t.substring(0, maxInputChars)}…' : t);
    return b.toString();
  }

  /// 解析模型返回。容忍 ```json 包裹与前后废话。
  @visibleForTesting
  static List<WikiCandidate> parseCandidates(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    // 先试着直接解析
    final direct = _tryParseList(text);
    if (direct != null) return direct;

    // 再试着从代码块里抠
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    for (final m in fence.allMatches(text)) {
      final parsed = _tryParseList(m.group(1) ?? '');
      if (parsed != null) return parsed;
    }

    // 最后试数组字面量
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start >= 0 && end > start) {
      final parsed = _tryParseList(text.substring(start, end + 1));
      if (parsed != null) return parsed;
    }
    return const [];
  }

  static List<WikiCandidate>? _tryParseList(String raw) {
    final t = raw.trim();
    if (!t.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(t);
      if (decoded is! List) return null;
      final out = <WikiCandidate>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final c = WikiCandidate.tryFromJson(item);
          if (c != null) out.add(c);
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<String> _chat({
    required String apiKey,
    required String system,
    required String user,
    String? baseUrlOverride,
    http.Client? httpClient,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      final request = http.Request(
        'POST',
        Uri.parse(baseUrlOverride ?? AppConfig.deepSeekBaseUrl),
      )
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = jsonEncode({
          'model': AppConfig.deepSeekModel,
          'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
          // 抽取要保守，不要发挥
          'temperature': 0.1,
          'max_tokens': 4000,
        });

      final streamed =
          await client.send(request).timeout(const Duration(seconds: 180));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception('API Key 无效');
      }
      if (response.statusCode == 402) {
        throw Exception('账户余额不足');
      }
      if (response.statusCode != 200) {
        throw Exception('请求失败（${response.statusCode}）');
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw Exception('模型没有返回内容');
      }
      final message = (choices.first as Map)['message'] as Map?;
      return (message?['content'] as String?)?.trim() ?? '';
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
