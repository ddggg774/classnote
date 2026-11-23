// lib/services/db_service.dart
// 本地数据库服务：用 sqflite 把笔记存到手机本地。
// 这是"存储层"，页面不直接操作数据库，统一走这里。
//
// 【版本迁移约定 · 加字段前必读】
// 数据库 version 与迁移必须成对维护：改 version 就必须在同一次提交里补 onUpgrade 分支，
// 否则已装机用户升级后打开 App 会直接抛 "no such column" 白屏，数据还在但打不开。
// 每个迁移必须可重复执行（IF NOT EXISTS 或先查 PRAGMA table_info），失败要能回滚到旧版本。
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart';

import '../config.dart';
import '../models/note.dart';
import '../models/note_template.dart';
import '../models/study_note.dart';
import 'search_index.dart';
import 'translation_service.dart';

class DbService {
  // 单例：整个 App 共用一个数据库实例
  DbService._internal();
  static final DbService _instance = DbService._internal();
  factory DbService() => _instance;

  /// 当前 schema 版本。
  /// v1 = 初始；v2 = 增加 status（草稿/已完成）；
  /// v3 = 增加 terminology_json（课前术语表）；
  /// v4 = 增加 terminology_cache 表（按课程+章节缓存术语表，避免重复生成）；
  /// v5 = notes 增加 course（结构化课程归属）与 template_id（使用的笔记模板），
  ///      新增 templates 表存用户自定义模板；
  /// v6 = 新增 search_terms 表（中文 bigram 倒排索引，用于跨笔记检索）；
  /// v7 = 新增 wiki_entries 与 wiki_sources 表（课程级知识库词条）；
  /// v8 = 新增 textbooks / chapters / sections 表（教材库与章节目录），
  ///      并把 config.dart 里三本教材的元数据灌成种子（只灌一次）；
  /// v9 = notes 增加五个位置字段（textbook_id / chapter_no / chapter_title /
  ///      section_no / section_title），记录这节课的教材位置。老笔记留空。
  /// v10 = notes 增加 language（zh/en，默认 zh）与 translation_json（英语课译文）。
  /// v11 = 新增 academic_reviews 表（学科专家质检结果，一篇笔记一份）。
  /// v12 = 新增 textbook_passages 表（教材摘录：实体书拍照/手抄的原文，供质检当依据）。
  /// v13 = 新增 note_rewrites 表（外部改写版本，保留历史，不覆盖原笔记）。
  static const int dbVersion = 13;

  Database? _db;

  /// 仅测试用：覆盖数据库工厂与路径。
  ///
  /// DbService 是单例，所有 DbService() 共享同一个 _db。
  /// 测试里若不隔离，用例之间会互相污染数据（这是真实踩过的坑：
  /// 一个用例建了「心皮」词条，下一个用例的冲突断言直接读到它）。
  @visibleForTesting
  static DatabaseFactory? factoryOverrideForTest;

  @visibleForTesting
  static String? dbPathOverrideForTest;

  /// 仅测试用：关掉当前连接，让下次 database 重新打开
  @visibleForTesting
  Future<void> resetForTest() async {
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
  }

  /// 检索索引。所有写笔记的入口都会同步更新它，
  /// 保证「搜得到的一定在库里、删掉的一定搜不到」。
  late final SearchIndex _index = SearchIndex(() => _db!);

  SearchIndex get index => _index;

  /// 打开（或创建）数据库
  Future<Database> get database async {
    if (_db != null) return _db!;
    final factory = factoryOverrideForTest ?? databaseFactory;
    final path = dbPathOverrideForTest ??
        join(await getDatabasesPath(), AppConfig.dbName);
    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
      version: dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            transcript TEXT NOT NULL,
            summary_json TEXT,
            created_at INTEGER NOT NULL,
            duration INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'done',
            terminology_json TEXT,
            course TEXT,
            template_id TEXT,
            textbook_id TEXT,
            chapter_no TEXT,
            chapter_title TEXT,
            section_no TEXT,
            section_title TEXT,
            language TEXT NOT NULL DEFAULT 'zh',
            translation_json TEXT
          )
        ''');
        await _createTerminologyCache(db);
        await _createTemplates(db);
        await SearchIndex.createTables(db);
        await _createWikiTables(db);
        await _createTextbookTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 逐版本迁移，每个分支独立、可重入
        if (oldVersion < 2) {
          await _addColumnIfMissing(
            db,
            'notes',
            'status',
            "TEXT NOT NULL DEFAULT 'done'",
          );
        }
        if (oldVersion < 3) {
          await _addColumnIfMissing(
            db,
            'notes',
            'terminology_json',
            'TEXT',
          );
        }
        if (oldVersion < 4) {
          await _createTerminologyCache(db);
        }
        if (oldVersion < 5) {
          // 老笔记的 course 留空，读的时候回退用 title——
          // 不能拿 title 猜一个课程塞进去，猜错比空着更糟。
          await _addColumnIfMissing(db, 'notes', 'course', 'TEXT');
          await _addColumnIfMissing(db, 'notes', 'template_id', 'TEXT');
          await _createTemplates(db);
        }
        if (oldVersion < 6) {
          await SearchIndex.createTables(db);
          // 老库升级上来时历史笔记没有索引，不补的话两字以上检索一条都搜不到。
          // 一次性重建，失败不影响升级（搜索页仍可用单字兜底）。
          try {
            final rows = await db.query('notes');
            for (final row in rows) {
              await _syncIndex(Note.fromMap(row), db);
            }
          } catch (_) {}
        }
        if (oldVersion < 7) {
          await _createWikiTables(db);
        }
        if (oldVersion < 8) {
          await _createTextbookTables(db);
        }
        if (oldVersion < 9) {
          // 老笔记这五列留空：读的时候不显示位置块，不做数据迁移、不猜
          await _addColumnIfMissing(db, 'notes', 'textbook_id', 'TEXT');
          await _addColumnIfMissing(db, 'notes', 'chapter_no', 'TEXT');
          await _addColumnIfMissing(db, 'notes', 'chapter_title', 'TEXT');
          await _addColumnIfMissing(db, 'notes', 'section_no', 'TEXT');
          await _addColumnIfMissing(db, 'notes', 'section_title', 'TEXT');
        }
        if (oldVersion < 10) {
          // 默认 zh：老笔记都是中文课，不需要迁移数据
          await _addColumnIfMissing(
            db,
            'notes',
            'language',
            "TEXT NOT NULL DEFAULT 'zh'",
          );
          await _addColumnIfMissing(db, 'notes', 'translation_json', 'TEXT');
        }
        if (oldVersion < 11) {
          await _createAcademicReviews(db);
        }
        if (oldVersion < 12) {
          await _createTextbookPassages(db);
        }
        if (oldVersion < 13) {
          await _createNoteRewrites(db);
        }
      },
      ),
    );
    return _db!;
  }

  /// 术语表缓存表。按「课程+章节」存一份生成好的术语包，
  /// 同一章节第二次纠错直接读缓存，不再重复调模型。
  /// 用 IF NOT EXISTS 保证迁移可重入。
  Future<void> _createTerminologyCache(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS terminology_cache (
        cache_key TEXT PRIMARY KEY,
        course TEXT NOT NULL,
        chapter TEXT NOT NULL,
        pack_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_term_course ON terminology_cache(course)',
    );
  }

  /// 用户自定义模板表。内置模板不落库（跟着版本走），这里只存用户改出来的。
  Future<void> _createTemplates(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS templates (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        scene TEXT,
        course TEXT,
        template_json TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// 知识库表。
  ///
  /// wiki_entries 的 (course, term) 是唯一键：同一门课内同名视为同一词条，
  /// 跨课程互不干扰（「心皮」在植物学和其他课里是两回事）。
  ///
  /// wiki_sources 的 (entry_id, note_id, snippet) 唯一：
  /// 这保证了幂等——同一篇笔记重复抽取不会产生重复出处。
  Future<void> _createWikiTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wiki_entries (
        id TEXT PRIMARY KEY,
        course TEXT NOT NULL,
        term TEXT NOT NULL,
        type TEXT NOT NULL,
        definition TEXT NOT NULL,
        variants_json TEXT,
        related_json TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_wiki_course_term '
      'ON wiki_entries(course, term)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_wiki_course ON wiki_entries(course)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS wiki_sources (
        id TEXT PRIMARY KEY,
        entry_id TEXT NOT NULL,
        note_id TEXT NOT NULL,
        note_title TEXT,
        snippet TEXT NOT NULL,
        conflict INTEGER NOT NULL DEFAULT 0,
        alt_definition TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_wiki_source_unique '
      'ON wiki_sources(entry_id, note_id, snippet)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_wiki_source_entry '
      'ON wiki_sources(entry_id)',
    );
  }

  /// 教材库表。
  ///
  /// 章、节分两张表而不是一张自引用表：需求只有「章 → 节」两层，
  /// 两张表最直白、测试也好写（代价是「篇」这一层放不下，第一版接受）。
  /// 章号/节号存原文（「第五章」「第一节」），排序靠 sort_order，
  /// 不解析 no——老师在课堂上说的就是「第五章」。
  ///
  /// 建表后顺手灌种子：config.dart 里那三本教材的元数据只在这一步写入，
  /// 之后一切读写走数据库。只在建库/升级时执行，用户删掉的教材不会被偷偷塞回来。
  Future<void> _createTextbookTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS textbooks (
        id TEXT PRIMARY KEY,
        course TEXT NOT NULL,
        title TEXT NOT NULL,
        edition TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        publisher TEXT NOT NULL DEFAULT '',
        year TEXT NOT NULL DEFAULT '',
        isbn TEXT NOT NULL DEFAULT '',
        toc_source TEXT NOT NULL DEFAULT 'none',
        toc_updated_at INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_textbook_course ON textbooks(course)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS chapters (
        id TEXT PRIMARY KEY,
        textbook_id TEXT NOT NULL,
        no TEXT NOT NULL,
        title TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chapter_book '
      'ON chapters(textbook_id, sort_order)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sections (
        id TEXT PRIMARY KEY,
        chapter_id TEXT NOT NULL,
        no TEXT NOT NULL,
        title TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_section_chapter '
      'ON sections(chapter_id, sort_order)',
    );

    await _createAcademicReviews(db);
    await _createTextbookPassages(db);
    await _createNoteRewrites(db);

    await _seedTextbooksIfEmpty(db);
  }

  /// 学科质检结果：一篇笔记一份，重跑时覆盖。
  /// 不拆成逐条表：质检结果整体展示，按条查没有使用场景，反而多一次 join。
  Future<void> _createAcademicReviews(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS academic_reviews (
        note_id TEXT PRIMARY KEY,
        subject TEXT NOT NULL,
        result_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// 外部改写版本：从 DeepSeek 等 App 分享回来的稿子存这里，**不覆盖 summary_json**。
  Future<void> _createNoteRewrites(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_rewrites (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        content TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rewrite_note ON note_rewrites(note_id)',
    );
  }

  /// 存一版外部改写（并存，不覆盖原笔记）
  Future<String> addNoteRewrite(
    String noteId,
    String content, {
    String source = '',
  }) async {
    final db = await database;
    // 同一微秒内连续插入（如连点导入）会撞主键，用 uuid 避免
    final id = 'r${const Uuid().v4()}';
    await db.insert('note_rewrites', {
      'id': id,
      'note_id': noteId,
      'content': content,
      'source': source,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    return id;
  }

  Future<List<Map<String, Object?>>> listNoteRewrites(String noteId) async {
    final db = await database;
    return db.query(
      'note_rewrites',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> deleteNoteRewrite(String id) async {
    final db = await database;
    await db.delete('note_rewrites', where: 'id = ?', whereArgs: [id]);
  }

  /// 教材摘录：实体书没有电子版时，用户手抄/拍照识别后存下的原文段落。
  /// 只存用户主动给的文本，不猜、不自动生成。
  Future<void> _createTextbookPassages(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS textbook_passages (
        id TEXT PRIMARY KEY,
        course TEXT NOT NULL,
        chapter TEXT NOT NULL DEFAULT '',
        text TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_passage_course '
      'ON textbook_passages(course)',
    );
  }

  Future<void> addTextbookPassage({
    required String course,
    required String text,
    String chapter = '',
  }) async {
    final db = await database;
    await db.insert('textbook_passages', {
      // 同一微秒连续保存两条会撞主键，用 uuid
      'id': 'p${const Uuid().v4()}',
      'course': course.trim(),
      'chapter': chapter.trim(),
      'text': text.trim(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, Object?>>> listTextbookPassages(String course) async {
    final db = await database;
    return db.query(
      'textbook_passages',
      // 课程名手输容易差一个字（「植物学」vs「植物学（第三版）」），
      // 精确匹配查不到时退化为包含匹配，避免摘录变成死数据
      where: "(course = ? OR course LIKE ? OR ? LIKE '%' || course || '%')",
      whereArgs: [course.trim(), '%${course.trim()}%', course.trim()],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> deleteTextbookPassage(String id) async {
    final db = await database;
    await db.delete('textbook_passages', where: 'id = ?', whereArgs: [id]);
  }

  /// 保存（覆盖）一篇笔记的学科质检结果
  Future<void> saveAcademicReview(String noteId, String resultJson,
      {String subject = 'general'}) async {
    final db = await database;
    await db.insert(
      'academic_reviews',
      {
        'note_id': noteId,
        'subject': subject,
        'result_json': resultJson,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取一篇笔记上次的质检结果（JSON 字符串），没有返回 null
  Future<String?> academicReviewJson(String noteId) async {
    final db = await database;
    final rows = await db.query(
      'academic_reviews',
      columns: ['result_json'],
      where: 'note_id = ?',
      whereArgs: [noteId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['result_json'] as String?;
  }

  /// 空库时把 config.dart 的三本教材灌成种子。
  ///
  /// 只写元数据，目录标记为「未录入」——目录绝不许由程序猜，
  /// 只能等用户手动录入或粘贴。
  Future<void> _seedTextbooksIfEmpty(Database db) async {
    final count = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM textbooks'),
        ) ??
        0;
    if (count > 0) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < AppConfig.textbooks.length; i++) {
      final t = AppConfig.textbooks[i];
      final m = RegExp(r'[（(]([^）)]*版)[）)]').firstMatch(t.book);
      await db.insert(
        'textbooks',
        {
          'id': 'textbook-seed-$i',
          'course': t.course,
          'title': t.book,
          'edition': m?.group(1) ?? '',
          'author': t.author,
          'publisher': t.publisher,
          'year': '',
          'isbn': '',
          'toc_source': 'none',
          'toc_updated_at': null,
          'sort_order': i,
          'created_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  /// 加列前先查 PRAGMA table_info，保证迁移可重复执行（避免重复 ALTER 抛错）
  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    final exists = info.any((row) => row['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  /// 新增一条笔记
  Future<void> insert(Note note) async {
    final db = await database;
    // uuid 理论上不会撞；万一重复（例如草稿转正时重复插入），用 replace 覆盖而不是抛错
    await db.insert('notes', note.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _syncIndex(note, db);
  }

  /// 把一条笔记同步进检索索引。
  ///
  /// 索引失败不该让保存笔记失败（那样用户会丢数据），
  /// 所以这里吞掉异常——最坏情况只是搜不到这篇，
  /// 用户可以在搜索页点「重建索引」修好。
  Future<void> _syncIndex(Note note, Database db) async {
    try {
      // 草稿不索引：内容还在变，索引它只会让搜索结果里出现半截笔记
      if (note.isDraft) {
        await _index.removeDoc(note.id, db: db);
        return;
      }
      final summary = StudySummary.tryDecode(note.summaryJson);
      final translation = TranslationResult.tryDecode(note.translationJson);
      await _index.indexDoc(
        IndexDoc(
          noteId: note.id,
          title: note.title,
          course: note.effectiveCourse,
          transcript: note.transcript,
          summary: summary?.detailMarkdown ?? '',
          translation: translation == null
              ? ''
              : translation.pairs.map((p) => p.target).join('\n'),
        ),
        db: db,
      );
    } catch (_) {}
  }

  /// 查询全部笔记，按创建时间倒序（最新的在前）。
  /// 注意：这里仍然取全字段，首页只展示摘要；正文按需 queryById 取。
  Future<List<Note>> queryAll() async {
    final db = await database;
    final maps = await db.query('notes', orderBy: 'created_at DESC');
    return maps.map((m) => Note.fromMap(m)).toList();
  }

  /// 只看草稿（未完成的录音），用于首页「继续记录」入口
  Future<List<Note>> queryDrafts() async {
    final db = await database;
    final maps = await db.query(
      'notes',
      where: 'status = ?',
      whereArgs: [Note.statusDraft],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => Note.fromMap(m)).toList();
  }

  /// 根据 ID 查询单条笔记
  Future<Note?> queryById(String id) async {
    final db = await database;
    final maps = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Note.fromMap(maps.first);
  }

  /// 更新一条笔记（用于写入 AI 总结、草稿增量保存等）
  Future<void> update(Note note) async {
    final db = await database;
    await db.update('notes', note.toMap(), where: 'id = ?', whereArgs: [note.id]);
    await _syncIndex(note, db);
  }

  /// 只更新总结相关字段（不碰 transcript）。
  ///
  /// 生成总结需要几分钟，期间正文可能被别的入口改过；
  /// 整行 update 会把那些改动回滚，所以单独给一个字段级入口。
  Future<void> updateSummary(
    String noteId, {
    required String summaryJson,
    String? templateId,
  }) async {
    final db = await database;
    await db.update(
      'notes',
      {
        'summary_json': summaryJson,
        if (templateId != null) 'template_id': templateId,
      },
      where: 'id = ?',
      whereArgs: [noteId],
    );
    final note = await queryById(noteId);
    if (note != null) await _syncIndex(note, db);
  }

  /// 删除一条笔记（连同它的外部改写版本、质检结果一起删，避免残留正文）
  Future<void> delete(String id) async {
    final db = await database;
    // 主表与子表放在同一事务里：中途被杀不会留下「笔记没了、改写正文还在」的孤儿
    await db.transaction((txn) async {
      await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
      for (final table in ['note_rewrites', 'academic_reviews', 'wiki_sources']) {
        try {
          await txn.delete(table, where: 'note_id = ?', whereArgs: [id]);
        } catch (_) {
          // 老库没有这些表时忽略；不能因为清理失败就删不掉笔记
        }
      }
    });
    try {
      await _index.removeDoc(id, db: db);
    } catch (_) {}
  }

  /// 清掉一天前创建、既没有标题也没有正文的空白草稿
  /// （用户点进录音页又立刻退出会产生）。限定 24 小时以上，避免误删正在用的草稿。
  // ───────────────────── 自定义模板 ─────────────────────

  /// 读取全部用户自定义模板（内置模板不在这里，它们写死在 TemplateService）
  Future<List<NoteTemplate>> queryTemplates() async {
    try {
      final db = await database;
      final rows = await db.query('templates', orderBy: 'sort_order ASC, created_at ASC');
      final out = <NoteTemplate>[];
      for (final r in rows) {
        final t = NoteTemplate.tryDecode(r['template_json'] as String?);
        if (t != null) out.add(t);
      }
      return out;
    } catch (_) {
      // 模板表读失败不该让整个 App 打不开，当作没有自定义模板
      return [];
    }
  }

  Future<void> saveTemplate(NoteTemplate template) async {
    final db = await database;
    await db.insert(
      'templates',
      {
        'id': template.id,
        'name': template.name,
        'scene': template.scene,
        'course': template.course,
        'template_json': template.encode(),
        'sort_order': template.sortOrder,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteTemplate(String id) async {
    final db = await database;
    await db.delete('templates', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> purgeEmptyDrafts() async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    // 走 delete(id) 而不是裸删：子表、索引一起清，避免残留正文
    final rows = await db.query(
      'notes',
      columns: ['id'],
      where: "status = ? AND transcript = '' AND title = '未命名课堂' AND created_at < ?",
      whereArgs: [Note.statusDraft, cutoff],
    );
    for (final row in rows) {
      await delete(row['id'] as String);
    }
    return rows.length;
  }
}
