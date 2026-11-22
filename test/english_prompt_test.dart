// test/english_prompt_test.dart
// 英语课的提示词有没有"只加不换"。
//
// 两条都要钉住：
//   · 中文课：提示词里绝不能出现英语块（否则中文笔记的生成质量会漂）
//   · 英语课：必须带上语言约束、术语格式、以及「老师说：」保留规则

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/models/note_template.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/ai_service.dart';
import 'package:classnote/services/template_service.dart';

const _marker = '语言要求（英语课）';

void main() {
  group('中文课提示词不带英语块', () {
    test('默认参数与显式 zh 完全一致', () {
      final a = AiService.buildPromptForLevel(SummaryLevel.normal);
      final b = AiService.buildPromptForLevel(SummaryLevel.normal, language: 'zh');
      expect(a, b);
      expect(a.contains(_marker), isFalse);
    });

    test('三档都不带', () {
      for (final level in SummaryLevel.values) {
        expect(
          AiService.buildPromptForLevel(level, courseName: '植物学').contains(_marker),
          isFalse,
          reason: '$level 被污染了',
        );
      }
    });

    test('分块与合并提示词也不带', () {
      expect(AiService.buildChunkPrompt().contains(_marker), isFalse);
      expect(
        AiService.buildMergePrompt(SummaryLevel.normal).contains(_marker),
        isFalse,
      );
    });
  });

  group('英语课提示词带上约束', () {
    test('主提示词含语言块与术语格式', () {
      final p = AiService.buildPromptForLevel(
        SummaryLevel.normal,
        courseName: '大学英语',
        language: 'en',
      );
      expect(p, contains(_marker));
      expect(p, contains('细胞壁（cell wall）'));
      expect(p, contains('老师说'));
      // 原有正文不能被替换掉
      expect(p, contains('课程信息'));
    });

    test('分块/合并也带语言块（长课堂照样是中文）', () {
      expect(AiService.buildChunkPrompt(language: 'en'), contains(_marker));
      expect(
        AiService.buildMergePrompt(SummaryLevel.normal, language: 'en'),
        contains(_marker),
      );
    });

    test('模板路径同样带语言块', () {
      final NoteTemplate template = TemplateService.defaultTemplate;
      final p = AiService.buildPrompt(
        template,
        SummaryLevel.normal,
        courseName: '大学英语',
        language: 'en',
      );
      expect(p, contains(_marker));
    });
  });
}