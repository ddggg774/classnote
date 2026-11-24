// test/first_batch_fixes_test.dart
// 全项目审计第一批修复的回归测试（只覆盖纯逻辑与 DB 字段更新）。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:classnote/models/note.dart';
import 'package:classnote/models/study_note.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/ai_service.dart';
import 'package:classnote/services/db_service.dart';
import 'package:classnote/services/template_service.dart';

void main() {
  group('长课堂合并沿用档位/模板', () {
    test('速览档的合并提示词不再是九段式', () {
      final p = AiService.buildMergePrompt(SummaryLevel.brief);
      expect(p, contains('速览'));
      expect(p, isNot(contains('# 例题与解题步骤')));
    });

    test('标准档仍保留九段式结构', () {
      final p = AiService.buildMergePrompt(SummaryLevel.normal);
      expect(p, contains('# 例题与解题步骤'));
    });
  });

  group('总结解析容错', () {
    test('graph 结构坏掉时仍能读出正文与待确认', () {
      const raw = '''
{"format":"classnote.detail.v2","detail":"正文还在","graph":{"branches":"不是数组"},
 "mindMap":{"root":"r","nodes":[]},"pending":[]}
''';
      final s = StudySummary.tryDecode(raw);
      expect(s, isNotNull);
      expect(s!.detailMarkdown, '正文还在');
      expect(s.graph.branches, isEmpty);
    });
  });

  group('总结回写不碰原文', () {
    setUp(() async {
      sqfliteFfiInit();
      DbService.factoryOverrideForTest = databaseFactoryFfi;
      DbService.dbPathOverrideForTest = inMemoryDatabasePath;
      await DbService().resetForTest();
    });

    tearDown(() async {
      await DbService().resetForTest();
      DbService.factoryOverrideForTest = null;
      DbService.dbPathOverrideForTest = null;
    });

    test('updateSummary 只改 summary_json/template_id，transcript 保留', () async {
      final db = DbService();
      await db.insert(Note(
        id: 'n1',
        title: '植物学',
        transcript: '用户刚刚保存的新原文',
        course: '植物学',
        createdAt: DateTime.now(),
      ));

      await db.updateSummary('n1',
          summaryJson: '{"format":"classnote.detail.v2","detail":"新总结"}',
          templateId: 'tpl-x');

      final after = await db.queryById('n1');
      expect(after!.transcript, '用户刚刚保存的新原文');
      expect(after.templateId, 'tpl-x');
      expect(after.summaryJson, contains('新总结'));
    });
  });

  test('总结提示词不再要求模型输出导图 JSON（导图改为单独生成）', () {
    for (final level in SummaryLevel.values) {
      final p = AiService.buildPromptForLevel(level);
      expect(p.contains('```json'), isFalse, reason: level.name);
    }
    final tpl = AiService.buildPrompt(
      TemplateService.defaultTemplate,
      SummaryLevel.normal,
    );
    expect(tpl.contains('```json'), isFalse);
  });
}
