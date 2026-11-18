// lib/services/db_service.dart
// 本地数据库服务：用 sqflite 把笔记存到手机本地。
// 这是"存储层"，页面不直接操作数据库，统一走这里。
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../config.dart';
import '../models/note.dart';

class DbService {
  // 单例：整个 App 共用一个数据库实例
  DbService._internal();
  static final DbService _instance = DbService._internal();
  factory DbService() => _instance;

  Database? _db;

  /// 打开（或创建）数据库
  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, AppConfig.dbName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            transcript TEXT NOT NULL,
            summary_json TEXT,
            created_at INTEGER NOT NULL,
            duration INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
    return _db!;
  }

  /// 新增一条笔记
  Future<void> insert(Note note) async {
    final db = await database;
    await db.insert('notes', note.toMap());
  }

  /// 查询全部笔记，按创建时间倒序（最新的在前）
  Future<List<Note>> queryAll() async {
    final db = await database;
    final maps = await db.query('notes', orderBy: 'created_at DESC');
    return maps.map((m) => Note.fromMap(m)).toList();
  }

  /// 根据 ID 查询单条笔记
  Future<Note?> queryById(String id) async {
    final db = await database;
    final maps = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Note.fromMap(maps.first);
  }

  /// 更新一条笔记（用于写入 AI 总结）
  Future<void> update(Note note) async {
    final db = await database;
    await db.update('notes', note.toMap(), where: 'id = ?', whereArgs: [note.id]);
  }

  /// 删除一条笔记
  Future<void> delete(String id) async {
    final db = await database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }
}
