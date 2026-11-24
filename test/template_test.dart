// test/template_test.dart
// 模板系统的纯逻辑测试（不调 API、不花钱）。
//
// 这里盯的是四件事：
//   ① 内置模板本身合规（有必需节、章节标题不重复、能通过 validate）
//   ② 课程匹配不要乱猜——没绑定课程的模板不该抢别人的课
//   ③ 序列化往返不丢内容（自定义模板要靠它存库）
//   ④ **模板真的改变提示词结构**——这是整个功能的意义所在，
//      如果实验报告模板产出的 prompt 和九段式一样，那等于没做
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/note_template.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/ai_service.dart';
import 'package:classnote/services/template_service.dart';

void main() {
  group('内置模板自身合规', () {
    test('每个内置模板都能通过校验', () {
      for (final t in TemplateService.builtins) {
        expect(TemplateService.validate(t), isNull,
            reason: '${t.name} 未通过校验：${TemplateService.validate(t)}');
      }
    });

    test('内置模板数量与 ID 唯一性', () {
      expect(TemplateService.builtins.length, 4);
      final ids = TemplateService.builtins.map((t) => t.id).toSet();
      expect(ids.length, 4, reason: '内置模板 ID 有重复');
    });

    test('每个内置模板都标了 builtin 且有场景说明', () {
      for (final t in TemplateService.builtins) {
        expect(t.builtin, isTrue);
        expect(t.scene.trim(), isNotEmpty, reason: '${t.name} 缺场景说明');
      }
    });

    test('defaultTemplate 是九段式', () {
      expect(TemplateService.defaultTemplate.id, BuiltinTemplate.general);
      expect(TemplateService.defaultTemplate.name, '九段式');
    });

    test('九段式有 9 节，速览只有 3 节', () {
      final general = TemplateService.builtinById(BuiltinTemplate.general)!;
      final brief = TemplateService.builtinById(BuiltinTemplate.brief)!;
      expect(general.sections.length, 9);
      expect(brief.sections.length, 3);
    });

    test('实验报告模板含报告必备章节', () {
      final lab = TemplateService.builtinById(BuiltinTemplate.lab)!;
      final titles = lab.sectionTitles;
      expect(titles.any((t) => t.contains('目的')), isTrue);
      expect(titles.any((t) => t.contains('材料')), isTrue);
      expect(titles.any((t) => t.contains('步骤')), isTrue);
      expect(titles.any((t) => t.contains('结果')), isTrue);
      expect(titles.any((t) => t.contains('结论')), isTrue);
    });

    test('制图模板含规范类章节', () {
      final d = TemplateService.builtinById(BuiltinTemplate.drawing)!;
      final titles = d.sectionTitles;
      expect(titles.any((t) => t.contains('线型')), isTrue);
      expect(titles.any((t) => t.contains('尺寸标注')), isTrue);
      expect(titles.any((t) => t.contains('图幅')), isTrue);
    });

    test('制图模板内明确禁止编造线型代号', () {
      final d = TemplateService.builtinById(BuiltinTemplate.drawing)!;
      final allReq = d.sections
          .expand((s) => s.requirements)
          .join('\n');
      expect(allReq.contains('不编造') || allReq.contains('不要编造'), isTrue,
          reason: '制图模板必须写明不编造规范编号/线型代号');
    });

    test('除速览外每个模板都至少有一节必需', () {
      for (final t in TemplateService.builtins) {
        expect(t.sections.any((s) => s.required), isTrue,
            reason: '${t.name} 没有任何必需节');
      }
    });
  });

  group('课程匹配', () {
    test('制图模板绑定「制图」，能匹配建筑制图与园林制图', () {
      final d = TemplateService.builtinById(BuiltinTemplate.drawing)!;
      expect(d.matchesCourse('建筑制图'), isTrue);
      expect(d.matchesCourse('园林制图'), isTrue);
      expect(d.matchesCourse('植物学'), isFalse);
    });

    test('通用模板不绑定课程，任何课都匹配', () {
      final g = TemplateService.builtinById(BuiltinTemplate.general)!;
      expect(g.course, isEmpty);
      expect(g.matchesCourse('植物学'), isTrue);
      expect(g.matchesCourse('量子力学'), isTrue);
    });

    test('空课程名不匹配任何绑定课程', () {
      final d = TemplateService.builtinById(BuiltinTemplate.drawing)!;
      expect(d.matchesCourse(''), isFalse);
      expect(d.matchesCourse('   '), isFalse);
    });

    test('recommendFor：制图课推荐制图模板', () {
      expect(TemplateService.recommendFor('建筑制图').id,
          BuiltinTemplate.drawing);
      expect(TemplateService.recommendFor('园林制图').id,
          BuiltinTemplate.drawing);
    });

    test('recommendFor：植物学推荐九段式（没有专门的植物学模板）', () {
      expect(
          TemplateService.recommendFor('植物学').id, BuiltinTemplate.general);
    });

    test('recommendFor：空课程名给默认模板，不崩', () {
      expect(TemplateService.recommendFor('').id, BuiltinTemplate.general);
    });
  });

  group('序列化往返', () {
    test('完整往返不丢字段', () {
      const original = NoteTemplate(
        id: 'custom-1',
        name: '我的模板',
        scene: '自己用',
        course: '植物学',
        sections: [
          TemplateSection(
            title: '第一节',
            required: true,
            requirements: ['写清楚', '别编造'],
            needQuote: true,
            needTable: true,
          ),
          TemplateSection(title: '第二节', required: false),
        ],
        sortOrder: 5,
      );
      final decoded = NoteTemplate.tryDecode(original.encode())!;
      expect(decoded.id, 'custom-1');
      expect(decoded.name, '我的模板');
      expect(decoded.scene, '自己用');
      expect(decoded.course, '植物学');
      expect(decoded.sections.length, 2);
      expect(decoded.sections.first.requirements, ['写清楚', '别编造']);
      expect(decoded.sections.first.needQuote, isTrue);
      expect(decoded.sections.first.needTable, isTrue);
      expect(decoded.sections[1].required, isFalse);
      expect(decoded.sortOrder, 5);
    });

    test('没有章节的模板解析为 null（不当成有效模板）', () {
      expect(NoteTemplate.tryDecode('{"id":"x","name":"空"}'), isNull);
    });

    test('坏 JSON 返回 null 不抛异常', () {
      expect(NoteTemplate.tryDecode('{{{'), isNull);
      expect(NoteTemplate.tryDecode(''), isNull);
      expect(NoteTemplate.tryDecode(null), isNull);
    });

    test('内置模板往返后仍合规', () {
      for (final t in TemplateService.builtins) {
        final back = NoteTemplate.tryDecode(t.encode())!;
        expect(back.name, t.name);
        expect(back.sections.length, t.sections.length);
        expect(TemplateService.validate(back), isNull);
      }
    });
  });

  group('自定义模板校验', () {
    test('空名被拒', () {
      const t = NoteTemplate(
          id: 'x', name: '  ', sections: [TemplateSection(title: 'A')]);
      expect(TemplateService.validate(t), contains('模板名'));
    });

    test('无章节被拒', () {
      const t = NoteTemplate(id: 'x', name: 'n', sections: []);
      expect(TemplateService.validate(t), contains('一节'));
    });

    test('章节标题重复被拒', () {
      const t = NoteTemplate(id: 'x', name: 'n', sections: [
        TemplateSection(title: '同名'),
        TemplateSection(title: '同名'),
      ]);
      expect(TemplateService.validate(t), contains('重复'));
    });

    test('没有必需节被拒（否则可能生成空笔记）', () {
      const t = NoteTemplate(id: 'x', name: 'n', sections: [
        TemplateSection(title: 'A', required: false),
      ]);
      expect(TemplateService.validate(t), contains('必需'));
    });
  });

  group('模板合并排序', () {
    test('内置在前，自定义在后', () {
      const custom = NoteTemplate(
        id: 'c1',
        name: '自定义',
        sections: [TemplateSection(title: 'A')],
      );
      final merged = TemplateService.merge(custom: [custom]);
      expect(merged.length, TemplateService.builtins.length + 1);
      expect(merged.first.builtin, isTrue);
      expect(merged.last.id, 'c1');
    });

    test('空自定义列表只返回内置', () {
      final merged = TemplateService.merge(custom: const []);
      expect(merged.length, TemplateService.builtins.length);
    });
  });

  group('模板真的改变提示词结构（功能存在的意义）', () {
    test('实验报告与九段式产出的章节不同', () {
      final lab = TemplateService.builtinById(BuiltinTemplate.lab)!;
      final pLab = AiService.buildPrompt(lab, SummaryLevel.normal);
      final pGeneral = AiService.buildPrompt(
          TemplateService.defaultTemplate, SummaryLevel.normal);

      expect(pLab.contains('实验目的'), isTrue);
      expect(pLab.contains('材料与仪器'), isTrue);
      expect(pLab.contains('讨论与误差分析'), isTrue);

      expect(pGeneral.contains('实验目的'), isFalse,
          reason: '九段式不该出现实验报告章节');
      expect(pGeneral.contains('知识点结构'), isTrue);

      expect(pLab, isNot(pGeneral));
    });

    test('制图模板产出制图章节，不含九段式的例题章节', () {
      final d = TemplateService.builtinById(BuiltinTemplate.drawing)!;
      final p = AiService.buildPrompt(d, SummaryLevel.normal);
      expect(p.contains('# 线型与线宽'), isTrue);
      expect(p.contains('# 尺寸标注规则'), isTrue);
      // 断言章节标题而不只是词：「例题与解题步骤」会出现在导图规范那段
      // （固定 11 个分支列表），不能据此判断章节存在。
      expect(p.contains('# 例题与解题步骤'), isFalse,
          reason: '制图模板不该有九段式的例题章节');
    });

    test('所有模板都继承同一套铁律（防编造底线不可被模板改掉）', () {
      for (final t in TemplateService.builtins) {
        final p = AiService.buildPrompt(t, SummaryLevel.normal);
        // 速览走旧路径，铁律措辞略不同，但都必须含"编造"禁令
        expect(p.contains('编造'), isTrue, reason: '${t.name} 丢了防编造要求');
        expect(p.contains('待确认') || p.contains('未提及'), isTrue,
            reason: '${t.name} 丢了不确定性标注要求');
      }
    });

    test('自定义模板的章节要求真的进了提示词', () {
      const t = NoteTemplate(
        id: 'custom-x',
        name: '自定义',
        sections: [
          TemplateSection(
            title: '我的专属章节',
            requirements: ['这句要求必须出现在提示词里'],
          ),
        ],
      );
      final p = AiService.buildPrompt(t, SummaryLevel.normal);
      expect(p.contains('# 我的专属章节'), isTrue);
      expect(p.contains('这句要求必须出现在提示词里'), isTrue);
    });

    test('detail 档给任何模板都追加原文引用要求', () {
      final lab = TemplateService.builtinById(BuiltinTemplate.lab)!;
      final pDetail = AiService.buildPrompt(lab, SummaryLevel.detail);
      final pNormal = AiService.buildPrompt(lab, SummaryLevel.normal);
      expect(pDetail.contains('原文引用'), isTrue);
      expect(pNormal.contains('原文引用'), isFalse);
      expect(pDetail.length, greaterThan(pNormal.length));
    });

    test('教材信息在模板路径下也不丢', () {
      final lab = TemplateService.builtinById(BuiltinTemplate.lab)!;
      final p = AiService.buildPrompt(lab, SummaryLevel.normal,
          courseName: '植物学');
      expect(p.contains('方炎明'), isTrue, reason: '模板路径丢了教材信息');
    });
  });

  group('导图与正文解耦', () {
    test('模板提示词不再包含导图分支要求', () {
      final p = AiService.buildPrompt(
          TemplateService.defaultTemplate, SummaryLevel.normal);
      expect(p.contains('一级分支固定'), isFalse);
      expect(p.contains('```json'), isFalse);
    });


  });

  group('章节渲染', () {
    test('必需节只输出标题', () {
      const s = TemplateSection(title: '唯一节');
      expect(s.render(), '# 唯一节');
    });

    test('可选节提示「未提及但必须保留标题」', () {
      const s = TemplateSection(title: '可选节', required: false);
      expect(s.render(), contains('未提及'));
      expect(s.render(), contains('标题必须保留'));
    });

    test('表格与引用要求都进渲染结果', () {
      const s = TemplateSection(
        title: 'T',
        needTable: true,
        needQuote: true,
        requirements: ['额外要求'],
      );
      final r = s.render();
      expect(r.contains('Markdown 表格'), isTrue);
      expect(r.contains('原文引用'), isTrue);
      expect(r.contains('额外要求'), isTrue);
    });
  });
}