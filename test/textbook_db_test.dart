// test/textbook_db_test.dart
// 教材库的真实 SQL 测试（sqflite_common_ffi + 内存库）。
//
// 为什么必须真建表：
//   · 目录是「全量覆盖写」——删章要连带删节，少删一次就留孤儿数据；
//   · toc_source 要随录入方式变化，而编辑教材信息时又不能被覆盖回 none；
//   · 种子只在建库时灌一次，重复灌会让教材越用越多。
// 这三件事都只能靠真实 SQL 验证。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/models/textbook.dart';
import 'package:classnote/services/db_service.dart';
import 'package:classnote/services/textbook_service.dart';
import 'package:classnote/services/toc_parser.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late TextbookService service;

  setUp(() async {
    DbService.factoryOverrideForTest = databaseFactoryFfi;
    DbService.dbPathOverrideForTest = inMemoryDatabasePath;
    await DbService().resetForTest();
    service = TextbookService();
  });

  tearDown(() async {
    await DbService().resetForTest();
  });

  group('种子教材', () {
    test('建库后自动灌入 config.dart 的三本，且只为元数据', () async {
      final all = await service.listAll();
      expect(all.length, 3);
      expect(all.map((t) => t.course).toSet(),
          {'植物学', '建筑制图', '园林制图'});
      final botany = all.firstWhere((t) => t.course == '植物学');
      expect(botany.title, '植物学（第三版）');
      expect(botany.edition, '第三版');
      expect(botany.author, '方炎明 主编');
      expect(botany.publisher, '中国林业出版社');
      // 目录绝不许程序生成
      expect(botany.tocSource, Textbook.tocNone);
      expect(botany.tocUpdatedAt, isNull);
      expect(await service.chaptersOf(botany.id), isEmpty);
    });

    test('重复读取不会重复灌种子', () async {
      expect((await service.listAll()).length, 3);
      expect((await service.listAll()).length, 3);
    });
  });

  group('教材 CRUD', () {
    test('新增后能按 id / 课程读回', () async {
      final t = Textbook(
        id: 't-lab',
        course: '植物学',
        title: '植物学实验指导',
        edition: '第一版',
        author: '某某 编',
        publisher: '高等教育出版社',
      );
      await service.save(t);

      final got = await service.byId('t-lab');
      expect(got, isNotNull);
      expect(got!.displayTitle, '植物学实验指导（第一版）');
      expect(got.materialLine, '植物学实验指导（第一版），某某 编，高等教育出版社');

      final byCourse = await service.listByCourse('植物学');
      expect(byCourse.length, 2);
    });

    test('按课程模糊匹配：植物 → 植物学，匹配不到返回 null', () async {
      expect((await service.matchCourse('植物'))?.course, '植物学');
      expect((await service.matchCourse('园林制图'))?.course, '园林制图');
      expect(await service.matchCourse(''), isNull);
      expect(await service.matchCourse('高等数学'), isNull);
    });

    test('编辑教材信息不把 toc_source 冲回 none', () async {
      final seed = (await service.listAll()).firstWhere((t) => t.course == '植物学');
      await service.saveToc(
        seed.id,
        TocParser.parse('第五章 被子植物\n  第一节 木兰科'),
        source: Textbook.tocPasted,
      );

      final before = await service.byId(seed.id);
      await service.save(before!.copyWith(title: '植物学（第三版）修订'));

      final after = await service.byId(seed.id);
      expect(after!.title, '植物学（第三版）修订');
      expect(after.tocSource, Textbook.tocPasted);
      expect(after.tocUpdatedAt, isNotNull);
    });
  });

  group('目录存取', () {
    late String textbookId;

    setUp(() async {
      final seed = (await service.listAll()).firstWhere((t) => t.course == '植物学');
      textbookId = seed.id;
    });

    test('章号节号原样往返，层级不丢', () async {
      const raw = '''
第五章 被子植物
  第一节 木兰科
  第二节 蔷薇科
  第三节 豆科
第六章 单子叶植物
  第一节 禾本科
''';
      await service.saveToc(textbookId, TocParser.parse(raw),
          source: Textbook.tocPasted);

      final toc = await service.tocOf(textbookId);
      expect(toc.chapterCount, 2);
      expect(toc.sectionCount, 4);
      expect(toc.chapters[0].no, '第五章');
      expect(toc.chapters[0].title, '被子植物');
      expect(toc.chapters[0].sections[0].no, '第一节');
      expect(toc.chapters[0].sections[0].title, '木兰科');
      expect(toc.chapters[1].sections.single.no, '第一节');

      final book = await service.byId(textbookId);
      expect(book!.tocSource, Textbook.tocPasted);
      expect(book.hasToc, isTrue);
    });

    test('覆盖写：旧章旧节被清掉，不留孤儿数据', () async {
      await service.saveToc(
        textbookId,
        TocParser.parse('第五章 被子植物\n  第一节 木兰科\n  第二节 蔷薇科'),
        source: Textbook.tocPasted,
      );
      final oldChapters = await service.chaptersOf(textbookId);
      final oldChapterId = oldChapters.single.id;

      await service.saveToc(
        textbookId,
        TocParser.parse('第六章 单子叶植物\n  第一节 禾本科'),
        source: Textbook.tocManual,
      );

      final chapters = await service.chaptersOf(textbookId);
      expect(chapters.length, 1);
      expect(chapters.single.title, '单子叶植物');

      final db = await DbService().database;
      final orphans = await db.query(
        'sections',
        where: 'chapter_id = ?',
        whereArgs: [oldChapterId],
      );
      expect(orphans, isEmpty);
      final book = await service.byId(textbookId);
      expect(book!.tocSource, Textbook.tocManual);
    });

    test('空目录 = 清空，toc_source 回到 none', () async {
      await service.saveToc(
        textbookId,
        TocParser.parse('第五章 被子植物'),
        source: Textbook.tocManual,
      );
      await service.saveToc(
        textbookId,
        TocParser.parse('完全不成结构的一行字'),
        source: Textbook.tocManual,
      );

      expect(await service.chaptersOf(textbookId), isEmpty);
      final book = await service.byId(textbookId);
      expect(book!.tocSource, Textbook.tocNone);
      expect(book.tocUpdatedAt, isNull);
    });

    test('删除教材连带删章删节', () async {
      await service.saveToc(
        textbookId,
        TocParser.parse('第五章 被子植物\n  第一节 木兰科'),
        source: Textbook.tocManual,
      );
      final chapters = await service.chaptersOf(textbookId);
      expect(chapters, isNotEmpty);

      await service.delete(textbookId);

      expect(await service.byId(textbookId), isNull);
      expect(await service.chaptersOf(textbookId), isEmpty);
      final db = await DbService().database;
      final sections = await db.query(
        'sections',
        where: 'chapter_id = ?',
        whereArgs: [chapters.first.id],
      );
      expect(sections, isEmpty);
      // 种子被删后不会在下次打开时偷偷回来（本测试里同一连接，再查询即可）
      expect((await service.listAll()).length, 2);
    });
  });
}