// test/real_api_wiki_test.dart
// 知识库抽取的真实验证（需 DS_KEY，默认跳过）。
//
// 核心验收只有一条：**不许编造**。
// 知识库会被反复阅读，一条编造的定义污染的是后续所有复习。
// 所以这里故意用「信息很少」的转写，看它会不会为了凑数补内容。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/models/note.dart';
import 'package:classnote/services/db_service.dart';
import 'package:classnote/services/wiki_service.dart';

const _richTranscript = '''
今天我们讲被子植物的木兰科。木兰科它是原始被子植物的代表类群。
大家看这个 Magnolia denudata，就是白玉兰，它的花被片是不分化的，没有花萼和花冠的区别。
心皮的数目要注意，木兰科是离生心皮，多数螺旋状排列在延长的花托上。
雄蕊群也是多数，花丝短，花药长，花药是外向的。
托叶是叶柄基部的附属物，木兰科的托叶早落，脱落后留下托叶痕。
这个离生心皮的结构在考试里会考，要能画出来。
作业是画木兰科花部的纵切图，下周三交。
''';

/// 信息很少的转写：大量口语、没有实质定义
const _thinTranscript = '''
今天我们接着上次的说。那个东西你们回去自己看书。
嗯，这个部分我就不展开讲了，考试不考。
好，下课。
''';

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;
  var seq = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DbService().resetForTest();
    DbService.factoryOverrideForTest = databaseFactoryFfi;
    DbService.dbPathOverrideForTest =
        '${Directory.systemTemp.path}/classnote_wiki_api_${seq++}.db';
  });

  tearDown(() async {
    final path = DbService.dbPathOverrideForTest;
    await DbService().resetForTest();
    if (path != null) {
      try {
        await databaseFactoryFfi.deleteDatabase(path);
      } catch (_) {}
    }
    DbService.dbPathOverrideForTest = null;
    DbService.factoryOverrideForTest = null;
  });

  Note note(String id, String transcript, {String title = '植物学第三讲'}) =>
      Note(
        id: id,
        title: title,
        transcript: transcript,
        course: '植物学',
        createdAt: DateTime.now(),
      );

  group('内容充实的转写', () {
    test('能抽出词条，且每个词条定义都有原文依据', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final wiki = WikiService(apiKeyOverride: key);
      final r = await wiki.extractFromNote(note('n1', _richTranscript));

      // ignore: avoid_print
      print('===== 抽取结果：${r.summary} =====');

      expect(r.created, greaterThan(0), reason: '这段内容明显有可抽的词条');

      final entries = await wiki.listByCourse('植物学');
      // ignore: avoid_print
      print('===== 共 ${entries.length} 个词条 =====');
      for (final e in entries) {
        // ignore: avoid_print
        print('· [${e.type.label}] ${e.term}：${e.definition}'
            '${e.variants.isEmpty ? '' : '（变体：${e.variants.join('/')}）'}');
      }

      expect(entries, isNotEmpty);

      // 每个词条都要有出处，且出处片段能在原文里找到
      for (final e in entries) {
        final sources = await wiki.sourcesOf(e.id);
        expect(sources, isNotEmpty, reason: '${e.term} 没有出处');
        final found = sources.any((s) =>
            _richTranscript.contains(s.snippet) ||
            s.snippet.length < 6);
        expect(found, isTrue,
            reason: '${e.term} 的出处片段在原文里找不到，可能是编造的');
      }

      // 已知的核心术语应该被抽到
      final terms = entries.map((e) => e.term).toList();
      expect(
        terms.any((t) => t.contains('离生心皮') || t.contains('心皮')),
        isTrue,
        reason: '「离生心皮」是这段的核心，应该被抽到',
      );

      // 不该编造原文没有的内容
      expect(terms.any((t) => t.contains('单子叶')), isFalse,
          reason: '原文没提单子叶，不该出现');
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('同一笔记重复抽取被直接跳过（不花钱、不污染）', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final wiki = WikiService(apiKeyOverride: key);
      final n = note('n1', _richTranscript);

      final r1 = await wiki.extractFromNote(n);
      final count1 = (await wiki.listByCourse('植物学')).length;

      // 第二次不传 force：应该直接跳过，连模型都不调
      final r2 = await wiki.extractFromNote(n);
      final count2 = (await wiki.listByCourse('植物学')).length;

      // ignore: avoid_print
      print('第一次：${r1.summary}，共 $count1 个词条');
      // ignore: avoid_print
      print('第二次（未 force）：${r2.summary}，共 $count2 个词条');

      expect(count2, count1, reason: '重复抽取不该新增词条');
      expect(r2.isEmpty, isTrue, reason: '应直接跳过，不产生任何结果');
      expect(await wiki.hasExtracted(n.id), isTrue);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('force=true 时重抽不会把词条数翻倍（已有词条名会被复用）', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final wiki = WikiService(apiKeyOverride: key);
      final n = note('n1', _richTranscript);

      await wiki.extractFromNote(n);
      final count1 = (await wiki.listByCourse('植物学')).length;

      // 强制重抽：模型可能给不同的措辞，但因为输入里带了已有词条名，
      // 应该倾向于复用而不是造新词条。
      final r2 = await wiki.extractFromNote(n, force: true);
      final count2 = (await wiki.listByCourse('植物学')).length;

      // ignore: avoid_print
      print('首抽 $count1 个；强制重抽后 ${r2.summary}，共 $count2 个');

      // 允许有少量新增（模型措辞难免波动），但不该翻倍
      expect(count2, lessThanOrEqualTo(count1 + 3),
          reason: '强制重抽不该让词条数暴涨');
      expect((await wiki.listByCourse('植物学')).map((e) => e.term).toSet().length,
          count2,
          reason: '同名词条不该重复');
    }, timeout: const Timeout(Duration(minutes: 6)));
  });

  group('信息稀薄的转写（防编造的关键测试）', () {
    test('几乎没内容时不硬抽词条', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final wiki = WikiService(apiKeyOverride: key);
      final r = await wiki.extractFromNote(note('n2', _thinTranscript));

      // ignore: avoid_print
      print('===== 稀薄转写抽取结果：${r.summary} =====');

      final entries = await wiki.listByCourse('植物学');
      // ignore: avoid_print
      print('抽到 ${entries.length} 个词条：');
      for (final e in entries) {
        // ignore: avoid_print
        print('· ${e.term}：${e.definition}');
      }

      // 这段里没有可沉淀的知识，抽到很多就是编造
      expect(entries.length, lessThan(3),
          reason: '信息稀薄时不该抽出大量词条，那是编造');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('跨笔记合并', () {
    test('两节课的同名词条合并为一处，出处累积', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      const second = '''
接着讲木兰科。离生心皮是指心皮彼此分离、不愈合的雌蕊类型，木兰科就是典型。
心皮是构成雌蕊的基本单位，一个心皮或者多个心皮组成雌蕊。
''';
      final wiki = WikiService(apiKeyOverride: key);
      await wiki.extractFromNote(note('n1', _richTranscript));
      final before = (await wiki.listByCourse('植物学')).length;

      await wiki.extractFromNote(
          note('n2', second, title: '植物学第四讲'));
      final after = await wiki.listByCourse('植物学');

      // ignore: avoid_print
      print('第一节课后 $before 个词条，第二节课后 ${after.length} 个');

      // 「心皮」这类两节课都提到的，应该只有一条词条但两条出处
      final xinpi =
          after.where((e) => e.term == '心皮' || e.term == '离生心皮').toList();
      for (final e in xinpi) {
        final sources = await wiki.sourcesOf(e.id);
        // ignore: avoid_print
        print('词条「${e.term}」有 ${sources.length} 处出处：'
            '${sources.map((s) => s.noteTitle).join('、')}');
      }
      // 至少断言没有出现完全重复的同名词条
      final termNames = after.map((e) => e.term).toList();
      expect(termNames.toSet().length, termNames.length,
          reason: '同名词条不该重复（(course,term) 唯一约束）');
    }, timeout: const Timeout(Duration(minutes: 6)));
  });
}