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
import 'package:path/path.dart';

import '../config.dart';
import '../models/note.dart';
import '../models/note_template.dart';
import '../models/study_note.dart';
import 'search_index.dart';

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
  /// v7 = 新增 wiki_entries 与 wiki_sources 表（课程级知识库词条）。
  static const int dbVersion = 7;

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
            template_id TEXT
          )
        ''');
        await _createTerminologyCache(db);
        await _createTemplates(db);
        await SearchIndex.createTables(db);
        await _createWikiTables(db);
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
        }
        if (oldVersion < 7) {
          await _createWikiTables(db);
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
      await _index.indexDoc(
        IndexDoc(
          noteId: note.id,
          title: note.title,
          course: note.effectiveCourse,
          transcript: note.transcript,
          summary: summary?.detailMarkdown ?? '',
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

  /// 删除一条笔记
  Future<void> delete(String id) async {
    final db = await database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
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
    return db.delete(
      'notes',
      where: "status = ? AND transcript = '' AND title = '未命名课堂' AND created_at < ?",
      whereArgs: [Note.statusDraft, cutoff],
    );
  }
}
