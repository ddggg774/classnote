// test/wiki_service_test.dart
// 知识库的解析、判重与合并测试。
//
// 分两组：
//   · 纯逻辑：模型输出解析、定义判重（不碰数据库、不花钱）
//   · 真实 SQL：用 sqflite_common_ffi 测合并逻辑
//     （新建/追加出处/冲突标记/幂等），这些只能真建表才测得出来
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/models/note.dart';
import 'package:classnote/models/wiki_entry.dart';
import 'package:classnote/services/db_service.dart';
import 'package:classnote/services/wiki_service.dart';

/// 造一条笔记（不落库，只用来喂 mergeCandidates）
Note _note(String id, {String course = '植物学', String title = '植物学第三讲'}) =>
    Note(
      id: id,
      title: title,
      transcript: '木兰科是离生心皮，多数螺旋状排列在延长的花托上。',
      course: course,
      createdAt: DateTime.now(),
    );

WikiCandidate _candidate(
  String term, {
  String definition = '某定义',
  String snippet = '某原文片段',
  WikiEntryType type = WikiEntryType.term,
  List<String> variants = const [],
}) =>
    WikiCandidate(
      term: term,
      type: type,
      definition: definition,
      snippet: snippet,
      variants: variants,
    );

void main() {
  var dbSeq = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 每个用例开一个独立的库文件。
  /// DbService 是单例，若不隔离，用例间会串数据（真实踩过）。
  setUp(() async {
    await DbService().resetForTest();
    DbService.factoryOverrideForTest = databaseFactoryFfi;
    DbService.dbPathOverrideForTest =
        '${Directory.systemTemp.path}/classnote_wiki_test_${dbSeq++}.db';
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

  group('模型输出解析（模型的格式很不可靠，必须容错）', () {
    test('干净的 JSON 数组', () {
      final list = WikiService.parseCandidates('''
[{"term":"离生心皮","type":"term","definition":"心皮彼此分离","snippet":"木兰科是离生心皮"}]
''');
      expect(list.length, 1);
      expect(list.first.term, '离生心皮');
      expect(list.first.definition, '心皮彼此分离');
      expect(list.first.type, WikiEntryType.term);
    });

    test('被 ```json 代码块包裹', () {
      final list = WikiService.parseCandidates('''
好的，结果如下：
```json
[{"term":"心皮","type":"term","definition":"雌蕊的组成单位","snippet":"心皮的数目"}]
```
''');
      expect(list.length, 1);
      expect(list.first.term, '心皮');
    });

    test('前后有废话，但数组完整', () {
      final list = WikiService.parseCandidates(
          '这是抽取结果：[{"term":"托叶","definition":"叶柄基部的附属物","snippet":"托叶"}] 以上。');
      expect(list.length, 1);
      expect(list.first.term, '托叶');
    });

    test('缺 term 或 definition 的条目被丢弃', () {
      final list = WikiService.parseCandidates('''
[{"term":"有名字但无定义","snippet":"x"},
 {"definition":"有定义但无名字","snippet":"y"},
 {"term":"完整","definition":"都齐了","snippet":"z"}]
''');
      expect(list.length, 1);
      expect(list.first.term, '完整');
    });

    test('未知 type 落到 concept，不丢弃', () {
      final list = WikiService.parseCandidates(
          '[{"term":"X","type":"莫名其妙的分类","definition":"d","snippet":"s"}]');
      expect(list.length, 1);
      expect(list.first.type, WikiEntryType.concept);
    });

    test('中文 type 标签也能识别', () {
      final list = WikiService.parseCandidates(
          '[{"term":"X","type":"公式/定理","definition":"d","snippet":"s"}]');
      expect(list.first.type, WikiEntryType.formula);
    });

    test('空数组', () {
      expect(WikiService.parseCandidates('[]'), isEmpty);
    });

    test('完全无法解析时返回空而不是抛异常', () {
      expect(WikiService.parseCandidates('模型今天不想干活'), isEmpty);
      expect(WikiService.parseCandidates(''), isEmpty);
      expect(WikiService.parseCandidates('{{{'), isEmpty);
      expect(WikiService.parseCandidates('[坏json'), isEmpty);
    });

    test('variants 与 related 被正确读出', () {
      final list = WikiService.parseCandidates('''
[{"term":"离生心皮","definition":"d","snippet":"s",
  "variants":["离心皮","里生心皮"],"related":["心皮"]}]
''');
      expect(list.first.variants, ['离心皮', '里生心皮']);
      expect(list.first.related, ['心皮']);
    });
  });

  group('定义判重', () {
    test('完全相同视为一致', () {
      expect(
        WikiService.definitionsMatch('心皮彼此分离不愈合', '心皮彼此分离不愈合'),
        isTrue,
      );
    });

    test('只差标点空白也视为一致', () {
      expect(
        WikiService.definitionsMatch('心皮，彼此分离。', '心皮 彼此分离'),
        isTrue,
      );
    });

    test('一方是另一方的详略版本，视为一致', () {
      expect(
        WikiService.definitionsMatch(
          '心皮彼此分离不愈合的雌蕊类型',
          '心皮彼此分离',
        ),
        isTrue,
      );
    });

    test('明显不同的定义不算一致', () {
      expect(
        WikiService.definitionsMatch(
          '心皮彼此分离不愈合',
          '心皮完全愈合形成合生雌蕊',
        ),
        isFalse,
      );
    });

    test('空串不参与一致性判断', () {
      expect(WikiService.definitionsMatch('', '有内容'), isFalse);
      expect(WikiService.definitionsMatch('有内容', ''), isFalse);
      expect(WikiService.definitionsMatch('', ''), isTrue);
    });

    test('长度差距过大的包含关系不算一致（防漏判冲突）', () {
      // 短的定义被长定义包含，但长定义多出来一大截信息，
      // 很可能是不同说法，不能当"详略差异"放过
      expect(
        WikiService.definitionsMatch(
          '心皮',
          '心皮是雌蕊的组成单位，在木兰科中多数离生并螺旋排列于花托之上',
        ),
        isFalse,
      );
    });
  });

  group('词条模型', () {
    test('toMap / fromMap 往返', () {
      final now = DateTime.now();
      final e = WikiEntry(
        id: 'e1',
        course: '植物学',
        term: '离生心皮',
        type: WikiEntryType.term,
        definition: '心皮分离',
        variants: const ['离心皮'],
        related: const ['心皮'],
        status: WikiEntryStatus.confirmed,
        createdAt: now,
        updatedAt: now,
      );
      final back = WikiEntry.fromMap(e.toMap());
      expect(back.term, '离生心皮');
      expect(back.variants, ['离心皮']);
      expect(back.related, ['心皮']);
      expect(back.status, WikiEntryStatus.confirmed);
      expect(back.uniqueKey, '植物学::离生心皮');
    });

    test('variants_json 坏数据降级为空列表', () {
      final map = {
        'id': 'e1',
        'course': 'c',
        'term': 't',
        'type': 'term',
        'definition': 'd',
        'variants_json': '不是json',
        'related_json': null,
        'status': 'pending',
        'created_at': 0,
        'updated_at': 0,
      };
      final e = WikiEntry.fromMap(map);
      expect(e.variants, isEmpty);
      expect(e.related, isEmpty);
    });

    test('类型标签与代码互认', () {
      expect(WikiEntryType.fromCode('person'), WikiEntryType.person);
      expect(WikiEntryType.fromCode('人物'), WikiEntryType.person);
      expect(WikiEntryType.fromCode('pitfall').label, '易错点');
      expect(WikiEntryType.fromCode(null), WikiEntryType.concept);
    });
  });

  group('真实 SQL：合并逻辑', () {
    late DbService dbService;
    late WikiService wiki;

    setUp(() {
      dbService = DbService();
      wiki = WikiService(db: dbService);
    });

    test('新词条：新建 + 一条出处 + 状态 pending', () async {
      final r = await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [_candidate('离生心皮', definition: '心皮分离不愈合')],
      );
      expect(r.created, 1);
      expect(r.conflicts, 0);

      final entry = await wiki.findEntry('植物学', '离生心皮');
      expect(entry, isNotNull);
      expect(entry!.status, WikiEntryStatus.pending,
          reason: '新抽取的词条应先进待确认');
      expect(entry.definition, '心皮分离不愈合');

      final sources = await wiki.sourcesOf(entry.id);
      expect(sources.length, 1);
      expect(sources.first.noteId, 'n1');
    });

    test('同一词条第二次出现：追加出处，不新建', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [_candidate('心皮', definition: '雌蕊组成单位', snippet: '心皮的数目')],
      );
      final r2 = await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n2', title: '植物学第四讲'),
        candidates: [_candidate('心皮', definition: '雌蕊组成单位', snippet: '心皮多数')],
      );

      expect(r2.created, 0);
      expect(r2.appendedSources, 1);

      final entry = await wiki.findEntry('植物学', '心皮');
      final sources = await wiki.sourcesOf(entry!.id);
      expect(sources.length, 2, reason: '两节课各有一处出处');
      expect(sources.any((s) => s.noteId == 'n2'), isTrue);
    });

    test('定义冲突：不覆盖主定义，标 conflict 并留 altDefinition', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [_candidate('心皮', definition: '心皮彼此分离不愈合')],
      );
      final r2 = await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n2', title: '植物学第五讲'),
        candidates: [
          _candidate('心皮', definition: '心皮完全愈合形成合生雌蕊', snippet: '更正一下')
        ],
      );

      expect(r2.conflicts, 1);

      final entry = await wiki.findEntry('植物学', '心皮');
      expect(entry!.definition, '心皮彼此分离不愈合',
          reason: '主定义不该被新说法覆盖');

      final sources = await wiki.sourcesOf(entry.id);
      final conflicted = sources.where((s) => s.conflict).toList();
      expect(conflicted.length, 1);
      expect(conflicted.first.altDefinition, '心皮完全愈合形成合生雌蕊',
          reason: '冲突的另一个说法要保留下来给用户裁定');
    });

    test('幂等：同一笔记重复抽取不产生重复出处', () async {
      final note = _note('n1');
      final cand = [_candidate('心皮', definition: 'd', snippet: '同一片段')];

      final r1 = await wiki.mergeCandidates(
          course: '植物学', note: note, candidates: cand);
      final r2 = await wiki.mergeCandidates(
          course: '植物学', note: note, candidates: cand);

      expect(r1.created, 1);
      expect(r2.created, 0);
      expect(r2.appendedSources, 0);
      expect(r2.skipped, 1, reason: '重复的出处应被跳过');

      final entry = await wiki.findEntry('植物学', '心皮');
      final sources = await wiki.sourcesOf(entry!.id);
      expect(sources.length, 1, reason: '不该因为重复抽取多出一条出处');
    });

    test('变体被合并进去（同一个词的多种写法都要累积）', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [
          _candidate('离生心皮', definition: 'd', snippet: 's1', variants: ['离心皮'])
        ],
      );
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n2'),
        candidates: [
          _candidate('离生心皮', definition: 'd', snippet: 's2', variants: ['里生心皮'])
        ],
      );
      final entry = await wiki.findEntry('植物学', '离生心皮');
      expect(entry!.variants, containsAll(['离心皮', '里生心皮']));
    });

    test('不同课程的同名词条互不干扰', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1', course: '植物学'),
        candidates: [_candidate('心皮', definition: '植物学的定义')],
      );
      await wiki.mergeCandidates(
        course: '建筑制图',
        note: _note('n2', course: '建筑制图', title: '制图课'),
        candidates: [_candidate('心皮', definition: '制图课里的另一个意思')],
      );

      final a = await wiki.findEntry('植物学', '心皮');
      final b = await wiki.findEntry('建筑制图', '心皮');
      expect(a!.definition, '植物学的定义');
      expect(b!.definition, '制图课里的另一个意思');
      expect(a.id, isNot(b.id));
    });
  });

  group('真实 SQL：查询与维护', () {
    late WikiService wiki;

    setUp(() {
      wiki = WikiService(db: DbService());
    });

    test('按类型与状态筛选', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [
          _candidate('术语A', type: WikiEntryType.term),
          _candidate('公式B', type: WikiEntryType.formula),
        ],
      );
      final terms = await wiki.listByCourse('植物学', type: WikiEntryType.term);
      expect(terms.length, 1);
      expect(terms.first.term, '术语A');

      final pending =
          await wiki.listByCourse('植物学', status: WikiEntryStatus.pending);
      expect(pending.length, 2, reason: '新词条都是 pending');
    });

    test('确认后状态变成 confirmed', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [_candidate('待确认词')],
      );
      final e = await wiki.findEntry('植物学', '待确认词');
      await wiki.confirm(e!.id);
      final after = await wiki.findEntry('植物学', '待确认词');
      expect(after!.status, WikiEntryStatus.confirmed);
      expect(await wiki.countPending(), 0);
    });

    test('删除词条时出处一起删', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [_candidate('要删的词')],
      );
      final e = await wiki.findEntry('植物学', '要删的词');
      await wiki.deleteEntry(e!.id);
      expect(await wiki.findEntry('植物学', '要删的词'), isNull);
      expect(await wiki.sourcesOf(e.id), isEmpty);
    });

    test('课程概览统计（总数与待确认数）', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [_candidate('A'), _candidate('B')],
      );
      await wiki.mergeCandidates(
        course: '建筑制图',
        note: _note('n2', course: '建筑制图'),
        candidates: [_candidate('C')],
      );
      final overview = await wiki.courseOverview();
      expect(overview.length, 2);
      final zhiwu = overview.firstWhere((o) => o.course == '植物学');
      expect(zhiwu.count, 2);
      expect(zhiwu.pending, 2);
    });

    test('变体字典能取出（供纠错 Agent 用）', () async {
      await wiki.mergeCandidates(
        course: '植物学',
        note: _note('n1'),
        candidates: [
          _candidate('离生心皮', definition: 'd', snippet: 's', variants: ['离心皮'])
        ],
      );
      final dict = await wiki.variantsOfCourse('植物学');
      expect(dict['离生心皮'], contains('离心皮'));
    });
  });
}