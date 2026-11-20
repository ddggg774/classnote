// lib/agent/terminology_store.dart
// 术语表仓库：按「课程 + 章节」存取术语包，避免每次纠错都重新生成一遍。
//
// 【为什么需要这个】
// 纠错子 Agent 的第一步是 lookup_terminology。如果每次都现调 DeepSeek 生成，
// 同一节课纠正两次就要付两次生成费、等两次延迟。术语表在当前章节内是稳定的，
// 天然适合缓存。
//
// 【为什么存在数据库而不是内存】
// 内存缓存在 App 被杀后清空，而用户往往是"录完这节课、隔天再整理"，
// 跨会话复用才有价值。所以落到 SQLite。
//
// 【为什么按「课程+章节」而不是只按课程】
// 用户明确要求「不把整本教材塞进 prompt」。一节植物学课可能涉及十几种科属，
// 全塞进去既贵又会让模型抓不住重点。按章节切分后，每次只喂相关的几十条。
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/terminology.dart';
import '../services/db_service.dart';

/// 术语表缓存条目
class TerminologyEntry {
  final String course;
  final String chapter;
  final TerminologyPack pack;
  final DateTime updatedAt;

  const TerminologyEntry({
    required this.course,
    required this.chapter,
    required this.pack,
    required this.updatedAt,
  });
}

class TerminologyStore {
  final DbService _db;
  TerminologyStore([DbService? db]) : _db = db ?? DbService();

  /// 缓存键：课程+章节归一化（去空格、统一大小写不敏感的分隔）
  static String _keyOf(String course, String chapter) =>
      '${course.trim()}|${chapter.trim()}';

  /// 读取缓存。没有则返回 null。
  Future<TerminologyPack?> get(String course, String chapter) async {
    if (course.trim().isEmpty) return null;
    try {
      final db = await _db.database;
      final rows = await db.query(
        'terminology_cache',
        where: 'cache_key = ?',
        whereArgs: [_keyOf(course, chapter)],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final json = rows.first['pack_json'] as String?;
      return TerminologyPack.tryDecode(json);
    } catch (_) {
      // 缓存读失败不该阻断纠错，当作没有缓存
      return null;
    }
  }

  /// 写入/更新缓存
  Future<void> put(String course, String chapter, TerminologyPack pack) async {
    if (course.trim().isEmpty) return;
    try {
      final db = await _db.database;
      await db.insert(
        'terminology_cache',
        {
          'cache_key': _keyOf(course, chapter),
          'course': course.trim(),
          'chapter': chapter.trim(),
          'pack_json': pack.encode(),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // 写缓存失败不影响主流程
    }
  }

  /// 列出某课程下已缓存的章节（界面上让用户挑已有章节，省一次生成）
  Future<List<TerminologyEntry>> listByCourse(String course) async {
    if (course.trim().isEmpty) return [];
    try {
      final db = await _db.database;
      final rows = await db.query(
        'terminology_cache',
        where: 'course = ?',
        whereArgs: [course.trim()],
        orderBy: 'updated_at DESC',
      );
      final out = <TerminologyEntry>[];
      for (final r in rows) {
        final pack = TerminologyPack.tryDecode(r['pack_json'] as String?);
        if (pack == null) continue;
        out.add(TerminologyEntry(
          course: r['course'] as String? ?? '',
          chapter: r['chapter'] as String? ?? '',
          pack: pack,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
              (r['updated_at'] as int?) ?? 0),
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> remove(String course, String chapter) async {
    try {
      final db = await _db.database;
      await db.delete(
        'terminology_cache',
        where: 'cache_key = ?',
        whereArgs: [_keyOf(course, chapter)],
      );
    } catch (_) {}
  }
}

/// 调试用：把术语包压成一行摘要
String summarizePack(TerminologyPack pack) {
  final b = StringBuffer()
    ..write('${pack.terms.length} 条')
    ..write('（高 ${pack.byLevel(TermLevel.high).length}');
  b.write(' / 中 ${pack.byLevel(TermLevel.mid).length}');
  b.write(' / 低 ${pack.byLevel(TermLevel.low).length}）');
  if (pack.riskHints.isNotEmpty) {
    b.write(' · ${pack.riskHints.length} 条风险提示');
  }
  return b.toString();
}

/// 仅测试用：序列化检查
String debugEncode(TerminologyPack pack) => jsonEncode(pack.toJson());