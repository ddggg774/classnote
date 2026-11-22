// test/db_migration_v8_test.dart
// v7 → v8 迁移的真实测试。
//
// 为什么单独测：db_service.dart 开头那段警告不是摆设——改 version 却漏了
// onUpgrade，已装机用户升级后打开就是 "no such column" 白屏。
// 这里用一个真的 v7 库文件走一遍升级，验证两件事：
//   ① 老笔记还在（没有被重建库顺手清掉）；
//   ② 教材三表建好且种子灌了一次，重复打开不会重复灌。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/services/db_service.dart';
import 'package:classnote/services/textbook_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('classnote_mig_');
    dbPath = '${tempDir.path}/classnote.db';

    // 造一个 v7 的库：只建 notes（v7 的全部列）并放一条老笔记。
    // v7→v8 这一段迁移只新增教材三表，不需要其他表存在。
    final old = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 7,
        onCreate: (db, _) async {
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
          await db.insert('notes', {
            'id': 'old-note',
            'title': '植物学 第三讲',
            'transcript': '木兰科的花被片离生。',
            'created_at': 1700000000000,
            'duration': 600,
            'status': 'done',
            'course': '植物学',
          });
        },
      ),
    );
    await old.close();

    DbService.factoryOverrideForTest = databaseFactoryFfi;
    DbService.dbPathOverrideForTest = dbPath;
    await DbService().resetForTest();
  });

  tearDown(() async {
    await DbService().resetForTest();
    DbService.factoryOverrideForTest = null;
    DbService.dbPathOverrideForTest = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // 临时目录清不掉不影响测试结论
    }
  });

  test('升级到 v8 后老笔记还在', () async {
    final note = await DbService().queryById('old-note');
    expect(note, isNotNull);
    expect(note!.title, '植物学 第三讲');
    expect(note.effectiveCourse, '植物学');
  });

  test('升级后教材三表建好并灌入三本种子', () async {
    final service = TextbookService();
    final all = await service.listAll();
    expect(all.length, 3);
    expect(all.map((t) => t.course).toSet(),
        {'植物学', '建筑制图', '园林制图'});

    final db = await DbService().database;
    // 三张表都能查，说明 CREATE TABLE 确实执行了
    expect(await db.query('chapters'), isEmpty);
    expect(await db.query('sections'), isEmpty);
  });

  test('再次打开不会重复灌种子', () async {
    expect((await TextbookService().listAll()).length, 3);
    await DbService().resetForTest();
    expect((await TextbookService().listAll()).length, 3);
  });
}