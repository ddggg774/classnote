// test/prompt_build_test.dart
// 三档提示词的纯字符串测试（不调 API、不需要 Key）。
// 这层最容易出的错是"插值没生效""教材没带上""档位内容串了"，
// 用纯字符串断言就能抓出来，不用花钱。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/config.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/ai_service.dart';

void main() {
  group('教材匹配', () {
    test('植物学匹配到方炎明版', () {
      final t = AppConfig.textbookOf('植物学');
      expect(t, isNotNull);
      expect(t!.book, contains('植物学'));
      expect(t.author, contains('方炎明'));
      expect(t.publisher, contains('中国林业出版社'));
    });

    test('建筑制图匹配到东南大学版', () {
      final t = AppConfig.textbookOf('建筑制图');
      expect(t, isNotNull);
      expect(t!.publisher, contains('东南大学出版社'));
    });

    test('园林制图能匹配', () {
      expect(AppConfig.textbookOf('园林制图'), isNotNull);
    });

    test('模糊匹配：只写"植物"也能命中', () {
      expect(AppConfig.textbookOf('植物'), isNotNull);
    });

    test('匹配不到返回 null，不瞎塞', () {
      expect(AppConfig.textbookOf('量子力学'), isNull);
      expect(AppConfig.textbookLine('量子力学'), isEmpty);
    });

    test('textbookLine 把书名作者出版社拼起来', () {
      final line = AppConfig.textbookLine('植物学');
      expect(line, contains('植物学'));
      expect(line, contains('方炎明'));
      expect(line, contains('中国林业出版社'));
    });
  });

  group('三档提示词构造', () {
    test('normal 档带上教材', () {
      final p = AiService.buildPromptForLevel(SummaryLevel.normal,
          courseName: '植物学');
      expect(p, contains('方炎明'),
          reason: '教材信息应该被拼进提示词');
      expect(p, contains('中国林业出版社'));
      // 九段式章节应该在
      expect(p, contains('课程信息'));
      expect(p, contains('例题'));
      expect(p, contains('术语'));
    });

    test('detail 档也带教材，且含引用要求', () {
      final p = AiService.buildPromptForLevel(SummaryLevel.detail,
          courseName: '植物学');
      expect(p, contains('方炎明'));
      expect(p.contains('原文引用') || p.contains('「'), isTrue,
          reason: 'detail 档要有原文引证要求');
      expect(p.contains('时间戳') || p.contains('03:20'), isTrue);
    });

    test('brief 档带教材，但只要求三节', () {
      final p = AiService.buildPromptForLevel(SummaryLevel.brief,
          courseName: '植物学');
      expect(p, contains('方炎明'));
      expect(p, contains('速览'));
      expect(p, contains('知识点'));
      // brief 不该要求例题/术语表这类展开章节
      expect(p.contains('例题与解题步骤'), isFalse,
          reason: 'brief 档不该要求例题章节');
    });

    test('三档提示词互不相同', () {
      final brief =
          AiService.buildPromptForLevel(SummaryLevel.brief, courseName: '植物学');
      final normal = AiService.buildPromptForLevel(SummaryLevel.normal,
          courseName: '植物学');
      final detail = AiService.buildPromptForLevel(SummaryLevel.detail,
          courseName: '植物学');
      expect(brief != normal, isTrue);
      expect(normal != detail, isTrue);
      expect(brief != detail, isTrue);
    });

    test('课程名匹配不到时不塞无关教材', () {
      final p = AiService.buildPromptForLevel(SummaryLevel.normal,
          courseName: '量子力学');
      expect(p.contains('方炎明'), isFalse);
      expect(p.contains('东南大学出版社'), isFalse);
    });

    test('不传课程名也不崩，且不含教材段', () {
      final p = AiService.buildPromptForLevel(SummaryLevel.normal);
      expect(p, contains('课程信息'));
      expect(p.contains('## 教材'), isFalse);
    });
  });

  group('SummaryLevel 解析', () {
    test('code 与中文都能解析', () {
      expect(SummaryLevel.fromCode('brief'), SummaryLevel.brief);
      expect(SummaryLevel.fromCode('detail'), SummaryLevel.detail);
      expect(SummaryLevel.fromCode('normal'), SummaryLevel.normal);
      expect(SummaryLevel.fromCode('乱写'), SummaryLevel.normal);
      expect(SummaryLevel.fromCode(null), SummaryLevel.normal);
    });

    test('parseLevel 容忍中文与大小写', () {
      expect(parseLevel('BRIEF'), SummaryLevel.brief);
      expect(parseLevel('速览'), SummaryLevel.brief);
      expect(parseLevel('详细'), SummaryLevel.detail);
      expect(parseLevel('完整版'), SummaryLevel.detail);
      expect(parseLevel(''), SummaryLevel.normal);
    });

    test('只有 detail 需要引证', () {
      expect(SummaryLevel.detail.needsCitations, isTrue);
      expect(SummaryLevel.normal.needsCitations, isFalse);
      expect(SummaryLevel.brief.needsCitations, isFalse);
    });
  });
}