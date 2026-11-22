// test/real_api_template_test.dart
// 模板系统的真实效果验证（需 DS_KEY，默认跳过）。
//
// 纯字符串测试只能证明「提示词里有这些章节」，
// 证明不了「模型真的按新章节输出」。这个文件补上那一环。
//
// 验收点：
//   ① 实验报告模板产出的笔记含实验章节、不含九段式的「例题与解题步骤」
//   ② 制图模板产出制图章节（线型、尺寸标注）
//   ③ 九段式仍然正常（改造后没有退化）
//   ④ 防编造底线还在：随便一段话不该被补出不存在的实验数据
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/note_template.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/ai_service.dart';
import 'package:classnote/services/template_service.dart';

/// 植物学野外实习的一段转写（适合实验报告模板）
const _labSample = '''
今天我们去校园里做植物标本采集实习。目的是学会野外采集和压制标本的基本方法。
工具你们检查一下：标本夹、吸水纸、枝剪、小铲子、标签纸，还有记录本。
采集的时候选生长完整、有花或果的植株，同一种至少采三份。草本要连根挖。
压制的时候注意，标本要展平，叶片正面朝上一部分、反面朝上一部分，方便后面观察。
吸水纸每天换一次，换三到五天，直到摸上去是干的。标签一定要写采集地点、日期、采集人。
容易错的地方：有人把标签写好了不夹进去，最后标本全乱了。这个扣分很厉害。
下周三是上交时间，每人不低于二十份。
''';

/// 建筑制图的一段转写（适合制图模板）
const _drawingSample = '''
今天讲建筑平面图的画法。首先确定图幅，我们作业用 A3，420 乘 297。
比例用一比一百。画之前先画图框，左边留 25 毫米装订边，其他三边各留 5 毫米。
线型这块重点记：粗实线线宽 b，用于可见轮廓线；中实线零点五 b；细实线零点二五 b，用于尺寸线。
轴线用点划线，线宽细线。虚线用于不可见轮廓。
尺寸标注，尺寸线用细实线，两端画四十五度短斜线作起止符，不要用箭头。
标高以米为单位，保留三位小数；其余尺寸以毫米为单位，图上不写单位。
常见的错误是尺寸线和轮廓线用一样粗，那样整张图就没有层次了。
''';

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;

  group('模板真实产出差异', () {
    test('实验报告模板产出实验章节，不套九段式', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final lab = TemplateService.builtinById(BuiltinTemplate.lab)!;

      final r = await ai.summarize(
        _labSample,
        level: SummaryLevel.normal,
        courseName: '植物学',
        template: lab,
      );
      final md = r.detailMarkdown;

      // ignore: avoid_print
      print('===== 实验报告模板产出 ${md.length} 字 =====');
      // ignore: avoid_print
      print(md.length > 900 ? '${md.substring(0, 900)}…' : md);

      expect(md.trim(), isNotEmpty);
      // 实验报告应有的章节
      expect(md.contains('目的'), isTrue, reason: '缺实验目的');
      expect(md.contains('材料'), isTrue, reason: '缺材料与仪器');
      expect(md.contains('步骤') || md.contains('方法'), isTrue,
          reason: '缺方法与步骤');
      // 不该出现九段式特有章节
      expect(md.contains('# 例题与解题步骤'), isFalse,
          reason: '实验报告模板不该有九段式的例题章节');
      expect(md.contains('# 时间戳回溯'), isFalse,
          reason: '实验报告模板不该有九段式的时间戳回溯章节');
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('制图模板产出制图章节', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final drawing = TemplateService.builtinById(BuiltinTemplate.drawing)!;

      final r = await ai.summarize(
        _drawingSample,
        level: SummaryLevel.normal,
        courseName: '建筑制图',
        template: drawing,
      );
      final md = r.detailMarkdown;

      // ignore: avoid_print
      print('===== 制图模板产出 ${md.length} 字 =====');
      // ignore: avoid_print
      print(md.length > 900 ? '${md.substring(0, 900)}…' : md);

      expect(md.trim(), isNotEmpty);
      expect(md.contains('线型'), isTrue, reason: '缺线型章节内容');
      expect(md.contains('尺寸标注') || md.contains('标注'), isTrue,
          reason: '缺尺寸标注内容');
      expect(md.contains('图幅') || md.contains('比例'), isTrue,
          reason: '缺图幅与比例');
      // 关键数字要保留原文
      expect(md.contains('420') || md.contains('297'), isTrue,
          reason: 'A3 图幅尺寸应被保留');
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('九段式改造后没有退化', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final r = await ai.summarize(
        _drawingSample,
        level: SummaryLevel.normal,
        courseName: '建筑制图',
        // 不传模板 = 九段式，验证默认路径未被拆 prompt 改坏
      );
      final md = r.detailMarkdown;

      // ignore: avoid_print
      print('===== 九段式产出 ${md.length} 字 =====');

      expect(md.trim(), isNotEmpty);
      expect(md.contains('课程信息'), isTrue);
      expect(md.contains('知识点结构'), isTrue);
      // 导图结构也要在
      expect(r.graph.branches, isNotEmpty, reason: '导图分支丢失');
      // ignore: avoid_print
      print('九段式导图：${r.graph.branches.length} 分支 '
          '${r.graph.totalNodes} 节点 最深 ${r.graph.maxDepth} 级');
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('防编造底线：没讲的实验数据不该被补出来', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final lab = TemplateService.builtinById(BuiltinTemplate.lab)!;

      // 故意给一段几乎没有实质内容的转写
      const thin = '今天就到这里，实验课下周再说，具体安排等通知。';
      final r = await ai.summarize(
        thin,
        level: SummaryLevel.normal,
        courseName: '植物学',
        template: lab,
      );
      final md = r.detailMarkdown;

      // ignore: avoid_print
      print('===== 空转写 × 实验报告模板 =====');
      // ignore: avoid_print
      print(md);

      // 关键：不能凭空编出实验步骤/材料/结论
      expect(md.contains('未提及') || md.contains('待确认'), isTrue,
          reason: '内容不足时应标未提及/待确认，而不是编造');
      // 不能出现具体数值
      expect(RegExp(r'\d+\s*(毫升|克|度|分钟)').hasMatch(md), isFalse,
          reason: '不该编造具体实验参数');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('模板与档位组合', () {
    test('制图模板 + detail 档带原文引用', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final drawing = TemplateService.builtinById(BuiltinTemplate.drawing)!;
      final r = await ai.summarize(
        _drawingSample,
        level: SummaryLevel.detail,
        courseName: '建筑制图',
        template: drawing,
      );
      final md = r.detailMarkdown;
      final quotes = RegExp('「').allMatches(md).length;
      // ignore: avoid_print
      print('制图模板 detail 档：${md.length} 字，引用 $quotes 处');
      expect(quotes, greaterThan(0), reason: 'detail 档应带原文引用');
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}