// test/real_api_skill_test.dart
// 新技能的真实验证（需 DS_KEY，默认跳过）。
//
// 验证的是「关掉技能真的不调对应工具」以及
// 考点/复习题两个新技能能产出可用内容。
//
// 注意：这里走真实 Agent 循环，模型会自己决定调什么。
// 所以断言不能太死（比如"必须调用 3 次"），
// 只能断言「调用了什么」和「没调用什么」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/agent/classroom_agent.dart';
import 'package:classnote/models/skill.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/skill_registry.dart';

const _transcript = '''
今天我们讲被子植物的木兰科。木兰科它是原始被子植物的代表类群。
大家看这个 Magnolia denudata，就是白玉兰，它的花被片是不分化的。
心皮的数目要注意，木兰科是离生心皮，多数螺旋状排列在延长的花托上。
这个离生心皮的结构在考试里会考，要能画出来，这是重点。
托叶早落，脱落后留下托叶痕，这个容易记混，注意区分。
作业是画木兰科花部的纵切图，下周三交，交到学习通。
雄蕊群也是多数，花丝短，药长，药外向。这个不考，了解一下就行。
''';

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;

  Skill skillOf(String id) => SkillRegistry.byId(id)!;

  group('技能裁剪：关掉的技能真的调不到', () {
    test('只启用术语纠错时，不调用 summarize / generate_mindmap', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final agent = ClassroomAgent(apiKey: key);
      final result = await agent.run(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章',
          existingTranscript: _transcript,
        ),
        skills: SkillSet([skillOf(BuiltinSkill.termFix)]),
      );

      // 只看「成功调用」的工具。
      // 模型可能硬调不存在的工具——那会记录成 success=false 的 tool 步骤，
      // 恰恰证明过滤生效了（工具不在它眼前）。所以不能把失败尝试算作调用。
      final okTools = result.steps
          .where((s) => s.kind == 'tool' && s.success)
          .map((s) => s.toolName)
          .toList();
      final attempted = result.steps
          .where((s) => s.kind == 'tool')
          .map((s) => s.toolName)
          .toList();
      // ignore: avoid_print
      print('===== 成功调用：$okTools');
      // ignore: avoid_print
      print('===== 全部尝试（含失败）：$attempted');
      // ignore: avoid_print
      print(result.logText);

      expect(okTools.contains('summarize'), isFalse,
          reason: '没启用生成笔记技能，summarize 不该被成功调用');
      expect(okTools.contains('generate_mindmap'), isFalse,
          reason: '没启用思维导图技能，不该成功调用 generate_mindmap');
      expect(result.hasSummary, isFalse);
      expect(result.graph, isNull);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('只启用生成笔记时，不调用纠错', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final agent = ClassroomAgent(apiKey: key);
      final result = await agent.run(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章',
          level: SummaryLevel.brief,
          existingTranscript: _transcript,
        ),
        skills: SkillSet([skillOf(BuiltinSkill.summary)]),
      );

      final tools = result.steps
          .where((s) => s.kind == 'tool')
          .map((s) => s.toolName)
          .toList();
      // ignore: avoid_print
      print('===== 只启用生成笔记，实际调用：$tools');

      expect(tools.contains('run_correction_agent'), isFalse,
          reason: '没启用纠错技能，不该调用纠错 Agent');
      expect(result.hasSummary, isTrue, reason: '应真的生成了总结');
    }, timeout: const Timeout(Duration(minutes: 4)));
  });

  group('新技能产出', () {
    test('提取考点能产出，且只提老师强调过的', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final agent = ClassroomAgent(apiKey: key);
      final result = await agent.run(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章',
          existingTranscript: _transcript,
        ),
        skills: SkillSet([skillOf(BuiltinSkill.examPoints)]),
      );

      final md = result.extras[BuiltinSkill.examPoints] ?? '';
      // ignore: avoid_print
      print('===== 考点清单 ${md.length} 字 =====');
      // ignore: avoid_print
      print(md.length > 800 ? '${md.substring(0, 800)}…' : md);

      expect(md.trim(), isNotEmpty, reason: '考点技能应产出内容');
      // 原文明确说了"会考""重点""容易记混"，应该被抓到
      expect(md.contains('离生心皮') || md.contains('心皮'), isTrue,
          reason: '原文说「考试里会考」的内容应该进考点清单');
      // 原文明确说「不考」的内容不该被列为必考重点。
      // 但「不考」这个词本身可能出现在"故未列入"这类说明里，
      // 所以只断言"必考重点"那一节里不带它。
      final mustKnow = md.contains('必考重点')
          ? md.split('必考重点').last.split('##').first
          : md;
      expect(mustKnow.contains('雄蕊群'), isFalse,
          reason: '老师明确说「这个不考」的内容不该进必考重点');
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('生成复习题能产出，且带答案依据', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final agent = ClassroomAgent(apiKey: key);
      final result = await agent.run(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章',
          existingTranscript: _transcript,
        ),
        skills: SkillSet([skillOf(BuiltinSkill.quiz)]),
      );

      final md = result.extras[BuiltinSkill.quiz] ?? '';
      // ignore: avoid_print
      print('===== 复习题 ${md.length} 字 =====');
      // ignore: avoid_print
      print(md.length > 900 ? '${md.substring(0, 900)}…' : md);

      expect(md.trim(), isNotEmpty, reason: '复习题技能应产出内容');
      // 答案要带依据
      expect(md.contains('依据') || md.contains('原文'), isTrue,
          reason: '答案应该给出原文依据，否则没法核对');
      // 不能考原文没讲的内容
      expect(md.contains('蔷薇科'), isFalse,
          reason: '原文没讲蔷薇科，不该出现在题目里');
    }, timeout: const Timeout(Duration(minutes: 4)));
  });

  group('多技能组合', () {
    test('纠错 + 笔记 都启用时，纠错在总结之前', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final agent = ClassroomAgent(apiKey: key);
      final result = await agent.run(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章',
          level: SummaryLevel.brief,
          existingTranscript: _transcript,
        ),
        skills: SkillSet([
          skillOf(BuiltinSkill.termFix),
          skillOf(BuiltinSkill.summary),
        ]),
      );

      final toolOrder = result.steps
          .where((s) => s.kind == 'tool')
          .map((s) => s.toolName)
          .whereType<String>()
          .toList();
      // ignore: avoid_print
      print('===== 调用顺序：$toolOrder');

      expect(toolOrder.contains('run_correction_agent'), isTrue);
      expect(toolOrder.contains('summarize'), isTrue);

      final correctIdx = toolOrder.indexOf('run_correction_agent');
      final summaryIdx = toolOrder.indexOf('summarize');
      expect(correctIdx, lessThan(summaryIdx),
          reason: '纠错应在总结之前——总结吃的该是纠错后的文本');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}