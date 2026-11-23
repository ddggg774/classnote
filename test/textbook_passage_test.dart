// test/textbook_passage_test.dart
// 教材摘录：实体书用户手抄原文的存取与检索优先级。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/services/db_service.dart';
import 'package:classnote/services/local_vector.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    DbService.factoryOverrideForTest = databaseFactoryFfi;
    DbService.dbPathOverrideForTest = inMemoryDatabasePath;
    await DbService().resetForTest();
  });

  tearDown(() async {
    await DbService().resetForTest();
    DbService.factoryOverrideForTest = null;
    DbService.dbPathOverrideForTest = null;
  });

  test('摘录能存、能按课程读、能删', () async {
    final db = DbService();
    await db.addTextbookPassage(
      course: '植物学',
      chapter: '第四章',
      text: '芋头为地下球茎，具环状节和退化叶。',
    );
    await db.addTextbookPassage(
      course: '计算机科学',
      text: '快速排序平均时间复杂度 O(n log n)。',
    );

    final botany = await db.listTextbookPassages('植物学');
    expect(botany.length, 1);
    expect(botany.single['chapter'], '第四章');
    expect(botany.single['text'], contains('芋头'));

    await db.deleteTextbookPassage(botany.single['id'] as String);
    expect((await db.listTextbookPassages('植物学')), isEmpty);
  });

  test('教材摘录能作为向量语料被检索到', () {
    final index = EvidenceIndex.build(const [
      VectorDoc('芋头为地下球茎，具环状节和退化叶。', source: '教材摘录'),
      VectorDoc('红掌的佛焰苞是变态叶。', source: '教材摘录'),
    ]);
    final hits = index.search('芋头是典型的块茎，其实是地下球茎');
    expect(hits, isNotEmpty);
    expect(hits.first.doc.source, '教材摘录');
    expect(hits.first.doc.text, contains('芋头'));
  });

  test('外部改写版本能并存、按时间列出、可删', () async {
    final db = DbService();
    final id1 = await db.addNoteRewrite('n1', '第一版改写', source: '外部分享');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final id2 = await db.addNoteRewrite('n1', '第二版改写', source: '外部分享');
    await db.addNoteRewrite('n2', '别的笔记', source: '外部分享');

    final rows = await db.listNoteRewrites('n1');
    expect(rows.length, 2);
    expect(rows.first['content'], '第二版改写'); // 倒序
    expect(rows.last['content'], '第一版改写');

    await db.deleteNoteRewrite(id1);
    await db.deleteNoteRewrite(id2);
    expect(await db.listNoteRewrites('n1'), isEmpty);
    expect((await db.listNoteRewrites('n2')).length, 1);
  });
}
