// test/toc_parser_test.dart
// 目录解析器的纯逻辑测试。
//
// 这里守的是这个功能最重要的一条红线：
//   解析结果里出现的每一个字，都必须来自用户粘贴的原文。
// 所以除了「能正确解析」，还有一半用例在测「认不出来的行被丢掉而不是被猜」。

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/services/toc_parser.dart';

void main() {
  group('正则解析：常见目录写法', () {
    test('中文章号 + 中文章节（需求里的样例）', () {
      const raw = '''
第五章 被子植物
  第一节 木兰科
  第二节 蔷薇科
  第三节 豆科
第六章 单子叶植物
  第一节 禾本科
''';
      final toc = TocParser.parse(raw);
      expect(toc.chapterCount, 2);
      expect(toc.sectionCount, 4);
      expect(toc.chapters[0].no, '第五章');
      expect(toc.chapters[0].title, '被子植物');
      expect(toc.chapters[0].sections[0].no, '第一节');
      expect(toc.chapters[0].sections[0].title, '木兰科');
      expect(toc.chapters[1].title, '单子叶植物');
      expect(toc.chapters[1].sections.single.title, '禾本科');
      expect(toc.droppedLines, isEmpty);
    });

    test('阿拉伯章号：第5章 / 5 被子植物', () {
      final a = TocParser.parse('第5章 被子植物\n  第1节 木兰科');
      expect(a.chapters.single.no, '第5章');
      expect(a.sectionsOfFirst, '木兰科');

      final b = TocParser.parse('5 被子植物\n6 单子叶植物\n  6.1 禾本科');
      expect(b.chapterCount, 2);
      expect(b.chapters[1].sections.single.no, '6.1');
      expect(b.chapters[1].sections.single.title, '禾本科');
    });

    test('数字分级节号 5.2 / 5.2.1', () {
      const raw = '''
5 被子植物
5.1 木兰科
5.2 蔷薇科
5.2.1 月季属
''';
      final toc = TocParser.parse(raw);
      expect(toc.chapterCount, 1);
      expect(toc.sectionCount, 3);
      expect(toc.chapters.single.sections[1].no, '5.2');
      expect(toc.chapters.single.sections[2].no, '5.2.1');
    });

    test('「一、」在无章时当章、有章时当节', () {
      final asChapter = TocParser.parse('一、被子植物\n二、单子叶植物');
      expect(asChapter.chapterCount, 2);
      expect(asChapter.chapters[0].no, '一、');

      final asSection = TocParser.parse('第五章 被子植物\n一、木兰科\n二、蔷薇科');
      expect(asSection.chapterCount, 1);
      expect(asSection.sectionCount, 2);
      expect(asSection.chapters.single.sections[0].no, '一、');
    });

    test('无编号节点（附录）当章，no 留空', () {
      const raw = '''
第五章 被子植物
  第一节 木兰科
附录 植物分类检索表
参考文献
''';
      final toc = TocParser.parse(raw);
      expect(toc.chapterCount, 3);
      expect(toc.chapters[1].no, '');
      expect(toc.chapters[1].title, '附录 植物分类检索表');
      expect(toc.chapters[2].title, '参考文献');
    });

    test('标题尾部的省略号 + 页码被剥掉', () {
      final toc = TocParser.parse('第五章 被子植物 …… 12\n  第一节 木兰科 …… 13');
      expect(toc.chapters.single.title, '被子植物');
      expect(toc.chapters.single.sections.single.title, '木兰科');
    });

    test('目录标题行与纯页码行跳过，不算丢弃', () {
      const raw = '''
目 录
第五章 被子植物
12
第 13 页
- 14 -
''';
      final toc = TocParser.parse(raw);
      expect(toc.chapterCount, 1);
      expect(toc.droppedLines, isEmpty);
    });

    test('缩进续行拼回上一条标题', () {
      const raw = '''
第五章 被子植物
  第一节 木兰科
    含鹅掌楸属
''';
      final toc = TocParser.parse(raw);
      expect(toc.chapters.single.sections.single.title, '木兰科 含鹅掌楸属');
    });
  });

  group('不编造：认不出的行如实丢弃', () {
    test('章之前出现的节被丢弃', () {
      final toc = TocParser.parse('第一节 木兰科\n第五章 被子植物');
      expect(toc.chapterCount, 1);
      expect(toc.chapters.single.sections, isEmpty);
      expect(toc.droppedLines, contains('第一节 木兰科'));
    });

    test('第三级「（一）」不提升成节，进丢弃列表', () {
      final toc = TocParser.parse('第五章 被子植物\n（一）木兰科\n第二节 蔷薇科');
      expect(toc.sectionCount, 1);
      expect(toc.chapters.single.sections.single.title, '蔷薇科');
      expect(toc.droppedLines, contains('（一）木兰科'));
    });

    test('完全不成结构的文字：0 章，全部进丢弃列表', () {
      const raw = '今天天气不错\n随便写点东西\n这门课挺有意思的';
      final toc = TocParser.parse(raw);
      expect(toc.isEmpty, isTrue);
      expect(toc.droppedLines.length, 3);
    });

    test('空输入不崩', () {
      expect(TocParser.parse('').isEmpty, isTrue);
      expect(TocParser.parse('   \n\n\t ').isEmpty, isTrue);
    });
  });

  group('模型兜底的行级校验', () {
    const raw = '第五章 被子植物\n  第一节 木兰科\n  第二节 蔷薇科';

    test('原文里有的章节能通过', () {
      const json = '{"chapters":[{"no":"第五章","title":"被子植物",'
          '"sections":[{"no":"第一节","title":"木兰科"}]}]}';
      final toc = TocParser.fromModelJson(json, raw);
      expect(toc, isNotNull);
      expect(toc!.chapterCount, 1);
      expect(toc.sectionCount, 1);
      expect(toc.droppedLines, isEmpty);
    });

    test('标点/空白差异不影响判断（归一化后再比对）', () {
      const json = '{"chapters":[{"no":"第五章","title":"被子植物 ",'
          '"sections":[{"no":"第一节","title":"木兰科。"}]}]}';
      expect(TocParser.fromModelJson(json, raw), isNotNull);
    });

    test('编造的章被整章丢弃', () {
      const json = '{"chapters":[{"no":"第五章","title":"被子植物","sections":[]},'
          '{"no":"第七章","title":"裸子植物","sections":[]}]}';
      final toc = TocParser.fromModelJson(json, raw);
      expect(toc!.chapterCount, 1);
      expect(toc.droppedLines.length, 1);
      expect(toc.droppedLines.first, contains('裸子植物'));
    });

    test('编造的节被单节丢弃，真节保留', () {
      const json = '{"chapters":[{"no":"第五章","title":"被子植物","sections":['
          '{"no":"第一节","title":"木兰科"},'
          '{"no":"第三节","title":"菊科"}]}]}';
      final toc = TocParser.fromModelJson(json, raw);
      expect(toc!.chapterCount, 1);
      expect(toc.sectionCount, 1);
      expect(toc.chapters.single.sections.single.title, '木兰科');
      expect(toc.droppedLines.single, contains('菊科'));
    });

    test('全部编造时返回 null（调用方退回正则结果）', () {
      const json = '{"chapters":[{"no":"第九章","title":"被子植物分类"}]}';
      expect(TocParser.fromModelJson(json, raw), isNull);
    });

    test('兼容 Markdown 代码围栏与数组形式', () {
      const fenced = '```json\n{"chapters":[{"no":"第五章","title":"被子植物"}]}\n```';
      expect(TocParser.fromModelJson(fenced, raw), isNotNull);

      const array = '[{"no":"第五章","title":"被子植物"}]';
      expect(TocParser.fromModelJson(array, raw), isNotNull);
    });

    test('非法 JSON 返回 null 而不抛异常', () {
      expect(TocParser.fromModelJson('这不是 JSON', raw), isNull);
      expect(TocParser.fromModelJson('', raw), isNull);
    });
  });
}

/// 测试里反复要用的小断言，省得每处写 chapters[0].sections[0]
extension on TocData {
  String get sectionsOfFirst => chapters.first.sections.first.title;
}