// test/location_test.dart
// 位置（课程 → 教材 → 章 → 节）的测试：值对象拼法、笔记字段往返、
// 从笔记还原位置、以及选择器在「没教材 / 没目录」时的降级表现。
//
// 这里守的核心是 R1：chapterKey 只能有一种拼法。
// 它同时是术语缓存键和提示词里的章节，拼错了缓存永远命中不了，而且没人会发现。

import 'package:material_ui/material_ui.dart'
    show Builder, Center, ElevatedButton, MaterialApp, Scaffold, Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/models/course_location.dart';
import 'package:classnote/models/note.dart';
import 'package:classnote/models/textbook.dart';
import 'package:classnote/services/db_service.dart';
import 'package:classnote/services/textbook_service.dart';
import 'package:classnote/services/toc_parser.dart';
import 'package:classnote/widgets/location_picker.dart';

void main() {
  final botanyBook = Textbook(
    id: 't1',
    course: '植物学',
    title: '植物学（第三版）',
    author: '方炎明 主编',
    publisher: '中国林业出版社',
  );
  final chapter = Chapter(
    id: 'c1',
    textbookId: 't1',
    no: '第五章',
    title: '被子植物',
  );
  final section = Section(
    id: 's1',
    chapterId: 'c1',
    no: '第二节',
    title: '木兰科',
  );

  group('CourseLocation 拼法（唯一真值）', () {
    test('章 + 节的 chapterKey 与显示行', () {
      final loc = CourseLocation(
        course: '植物学',
        textbook: botanyBook,
        chapter: chapter,
        section: section,
      );
      expect(loc.chapterKey, '第五章 被子植物 第二节 木兰科');
      expect(loc.displayLine,
          '植物学（第三版） · 第五章 被子植物 · 第二节 木兰科');
      expect(loc.materialLine, '植物学（第三版），方炎明 主编，中国林业出版社');
      expect(loc.hasPosition, isTrue);
    });

    test('只到章：chapterKey 不含节', () {
      final loc = CourseLocation(
        course: '植物学',
        textbook: botanyBook,
        chapter: chapter,
      );
      expect(loc.chapterKey, '第五章 被子植物');
      expect(loc.hasPosition, isTrue);
    });

    test('跳过定位：chapterKey 为空串，等价于改造前', () {
      final loc = CourseLocation(course: '植物学', textbook: botanyBook);
      expect(loc.chapterKey, '');
      expect(loc.hasPosition, isFalse);
      expect(loc.materialLine, isNotEmpty);
    });

    test('全空：显示行为空，界面据此不渲染位置块', () {
      expect(CourseLocation.empty.chapterKey, '');
      expect(CourseLocation.empty.displayLine, '');
      expect(CourseLocation.empty.isEmpty, isTrue);
    });

    test('copyWith 清章时连带清节', () {
      final loc = CourseLocation(
        course: '植物学',
        textbook: botanyBook,
        chapter: chapter,
        section: section,
      );
      final noSection = loc.copyWith(clearChapter: true);
      expect(noSection.chapter, isNull);
      expect(noSection.section, isNull);
      expect(noSection.chapterKey, '');
      expect(noSection.hasPosition, isFalse);
    });
  });

  group('Note 的位置字段', () {
    Note makeNote() => Note(
          id: 'n1',
          title: '植物学 第三讲',
          transcript: '木兰科的花被片离生。',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          course: '植物学',
          textbookId: 't1',
          chapterNo: '第五章',
          chapterTitle: '被子植物',
          sectionNo: '第二节',
          sectionTitle: '木兰科',
        );

    test('toMap / fromMap 往返，章号节号原样保留', () {
      final back = Note.fromMap(makeNote().toMap());
      expect(back.textbookId, 't1');
      expect(back.chapterNo, '第五章');
      expect(back.chapterTitle, '被子植物');
      expect(back.sectionNo, '第二节');
      expect(back.sectionTitle, '木兰科');
      expect(back.chapterKey, '第五章 被子植物 第二节 木兰科');
      expect(back.hasLocation, isTrue);
    });

    test('老库缺列时按 null 处理，不抛异常', () {
      final old = Note.fromMap({
        'id': 'old',
        'title': '课堂 11月22日',
        'transcript': '',
        'created_at': 0,
      });
      expect(old.textbookId, isNull);
      expect(old.hasLocation, isFalse);
      expect(old.chapterKey, '');
    });

    test('copyWith：clearPosition 只清章/节，clearLocation 清全部', () {
      final note = makeNote();
      final noPosition = note.copyWith(clearPosition: true);
      expect(noPosition.textbookId, 't1');
      expect(noPosition.chapterNo, isNull);
      expect(noPosition.hasLocation, isTrue); // 还留着教材

      final cleared = note.copyWith(clearLocation: true);
      expect(cleared.textbookId, isNull);
      expect(cleared.chapterNo, isNull);
      expect(cleared.sectionTitle, isNull);
      expect(cleared.hasLocation, isFalse);
    });

    test('copyWith：clearCourse 能真的清空课程（否则取消选择后永远挂着旧课）', () {
      final note = makeNote();
      final cleared = note.copyWith(clearCourse: true);
      expect(cleared.course, isNull);
      expect(cleared.effectiveCourse, '植物学 第三讲'); // 回退到 title
      expect(cleared.chapterNo, '第五章'); // 课程清空不影响位置字段本身
    });
  });

  group('从笔记还原位置（真实 SQL）', () {
    late TextbookService service;

    setUpAll(() {
      sqfliteFfiInit();
    });

    setUp(() async {
      DbService.factoryOverrideForTest = databaseFactoryFfi;
      DbService.dbPathOverrideForTest = inMemoryDatabasePath;
      await DbService().resetForTest();
      service = TextbookService();
    });

    tearDown(() async {
      await DbService().resetForTest();
      DbService.factoryOverrideForTest = null;
      DbService.dbPathOverrideForTest = null;
    });

    Future<({Textbook book, Chapter chapter, Section section})> prepareToc() async {
      final book = (await service.listAll()).firstWhere((t) => t.course == '植物学');
      await service.saveToc(
        book.id,
        TocParser.parse('第五章 被子植物\n  第一节 木兰科\n  第二节 蔷薇科'),
        source: Textbook.tocPasted,
      );
      final chapters = await service.chaptersOf(book.id);
      final sections = await service.sectionsOf(chapters.single.id);
      return (book: book, chapter: chapters.single, section: sections.first);
    }

    test('按五个字段还原出章与节', () async {
      final data = await prepareToc();
      final loc = await service.resolve(
        course: '植物学',
        textbookId: data.book.id,
        chapterNo: data.chapter.no,
        chapterTitle: data.chapter.title,
        sectionNo: data.section.no,
        sectionTitle: data.section.title,
      );
      expect(loc.chapter?.id, data.chapter.id);
      expect(loc.section?.id, data.section.id);
      expect(loc.chapterKey, '第五章 被子植物 第一节 木兰科');
      expect(loc.displayLine, contains('植物学（第三版）'));
      expect(loc.materialLine, contains('中国林业出版社'));
    });

    test('章号对不上：降级为只有教材，不报错', () async {
      final data = await prepareToc();
      final loc = await service.resolve(
        course: '植物学',
        textbookId: data.book.id,
        chapterNo: '第九章',
        chapterTitle: '裸子植物',
      );
      expect(loc.chapter, isNull);
      expect(loc.section, isNull);
      expect(loc.textbook, isNotNull);
      expect(loc.chapterKey, '');
    });

    test('教材被删：靠课程名模糊匹配回来（会命中另一本同课教材）', () async {
      final data = await prepareToc();
      await service.delete(data.book.id);
      final loc = await service.resolve(
        course: '植物学',
        textbookId: data.book.id, // 已不存在
        chapterNo: '第五章',
        chapterTitle: '被子植物',
      );
      // 种子被删后这门课没有教材了，matchCourse 应返回 null 而不是抛错
      expect(loc.textbook, isNull);
      expect(loc.chapter, isNull);
    });

    test('sectionMapOf 一条 JOIN 取全书的节', () async {
      final data = await prepareToc();
      final map = await service.sectionMapOf(data.book.id);
      expect(map.keys, [data.chapter.id]);
      expect(map[data.chapter.id]!.length, 2);
    });

    test('位置字段随笔记真正落库、能读回、能清空', () async {
      final data = await prepareToc();
      final db = DbService();
      await db.insert(Note(
        id: 'n-loc',
        title: '植物学 第三讲',
        transcript: '木兰科的花被片离生。',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        course: '植物学',
        textbookId: data.book.id,
        chapterNo: data.chapter.no,
        chapterTitle: data.chapter.title,
        sectionNo: data.section.no,
        sectionTitle: data.section.title,
      ));

      final back = await db.queryById('n-loc');
      expect(back, isNotNull);
      expect(back!.hasLocation, isTrue);
      expect(back.chapterKey, '第五章 被子植物 第一节 木兰科');
      expect(back.textbookId, data.book.id);

      // 清空位置后落库，再读回来必须是空——防止 clearLocation 只在内存里生效
      await db.update(back.copyWith(clearLocation: true));
      final cleared = await db.queryById('n-loc');
      expect(cleared!.hasLocation, isFalse);
      expect(cleared.chapterNo, isNull);
      expect(cleared.sectionTitle, isNull);
      expect(cleared.textbookId, isNull);
      expect(cleared.course, '植物学'); // 清位置不动课程
    });
  });

  group('选择器的降级表现', () {
    testWidgets('课程没有教材时提示去新建', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LocationPickerSheet(
            course: '高等数学',
            service: _FakeTextbookService(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('这门课还没有教材'), findsOneWidget);
    });

    testWidgets('教材没目录时提示去录入', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LocationPickerSheet(
            course: '植物学',
            service: _FakeTextbookService(books: [botanyBook]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没录入目录'), findsOneWidget);
    });

    testWidgets('有目录时可以选到节并返回位置', (tester) async {
      final fake = _FakeTextbookService(
        books: [botanyBook],
        chapters: [chapter],
        sections: {
          chapter.id: [section],
        },
      );
      CourseLocation? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showLocationPicker(
                    ctx,
                    course: '植物学',
                    service: fake,
                  );
                },
                child: const Text('打开选择器'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();
      expect(find.text('第五章 被子植物'), findsOneWidget);

      // 点章行：选中并展开
      await tester.tap(find.text('第五章 被子植物'));
      await tester.pumpAndSettle();
      expect(find.text('第二节 木兰科'), findsOneWidget);

      // 点节：立即返回一个带完整位置的结果
      await tester.tap(find.text('第二节 木兰科'));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(picked!.chapterKey, '第五章 被子植物 第二节 木兰科');
      expect(picked!.textbook?.id, botanyBook.id);
    });

    testWidgets('跳过：确认按钮返回「只到教材、无章节」的位置', (tester) async {
      final fake = _FakeTextbookService(
        books: [botanyBook],
        chapters: [chapter],
        sections: {
          chapter.id: [section],
        },
      );
      CourseLocation? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showLocationPicker(
                    ctx,
                    course: '植物学',
                    service: fake,
                  );
                },
                child: const Text('打开选择器'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(picked!.hasPosition, isFalse);
      expect(picked!.chapterKey, '');
    });
  });
}

/// 只实现选择器用到的那几个方法，避免 widget 测试真开数据库。
class _FakeTextbookService extends TextbookService {
  _FakeTextbookService({
    this.books = const [],
    this.chapters = const [],
    this.sections = const {},
  });

  final List<Textbook> books;
  final List<Chapter> chapters;
  final Map<String, List<Section>> sections;

  @override
  Future<List<Textbook>> listByCourse(String course) async => books;

  @override
  Future<List<Chapter>> chaptersOf(String textbookId) async => chapters;

  @override
  Future<Map<String, List<Section>>> sectionMapOf(String textbookId) async =>
      sections;
}