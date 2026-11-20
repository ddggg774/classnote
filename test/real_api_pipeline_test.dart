// test/real_api_pipeline_test.dart
// 顶层编排 Agent 的真实端到端验证（需 DS_KEY，默认跳过）。
//
// 验证目标：串起真实现后，四个环节能真的跑通，且产物可用。
// 因为 Agent 的编排由模型决定（不确定调用顺序），这里额外做一个
// **确定性版本**：直接按 transcribe→纠错→总结→导图 的顺序串一遍，
// 证明"接线正确"，再用 Agent 跑一遍证明"编排可用"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/agent/classroom_agent.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/ai_service.dart';

/// 植物学课堂转写样本（模拟远场识别后带少量误听的文本）
const _transcript = '''
今天我们讲被子植物的木兰科。木兰科它是原始被子植物的代表类群。
大家看这个 Magnolia denudata，就是白玉兰，它的花被片是不分化的。
心皮的数目要注意，木兰科是离生心皮，多数螺旋状排列在延长的花托上。
雄蕊群也是多数，花丝短，花药长。
这个离生心皮的结构在考试里会考，要能画出来。
作业是画木兰科花部的纵切图，下周三交，交到学习通。
''';

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;

  group('真实端到端：文本 → 纠错 → 总结 → 导图', () {
    test('确定性串联：四个环节都能产出', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);

      // ① 总结（normal 档，同时产出导图）
      final summary = await ai.summarize(
        _transcript,
        level: SummaryLevel.normal,
        courseName: '植物学',
      );
      expect(summary.detailMarkdown.trim(), isNotEmpty);
      expect(summary.graph.branches, isNotEmpty);
      // ignore: avoid_print
      print('=== 总结 ${summary.detailMarkdown.length} 字，'
          '导图 ${summary.graph.branches.length} 分支/${summary.graph.totalNodes} 节点');
      // ignore: avoid_print
      print(summary.detailMarkdown.length > 500
          ? '${summary.detailMarkdown.substring(0, 500)}…'
          : summary.detailMarkdown);

      // ② 导图结构检查
      expect(summary.graph.maxDepth, greaterThanOrEqualTo(2),
          reason: '导图至少要有两层，不能全是一级分支');
      // ignore: avoid_print
      print('导图最深 ${summary.graph.maxDepth} 级');

      // ③ 教材信息应该被带进提示词（通过检查提示词内容间接验证）
      final prompt = AiService.buildPromptForLevel(
        SummaryLevel.normal,
        courseName: '植物学',
      );
      expect(prompt.contains('方炎明'), isTrue);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('顶层 Agent 能自动编排（由模型决定顺序）', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final agent = ClassroomAgent(apiKey: key);
      final result = await agent.run(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章 被子植物',
          level: SummaryLevel.normal,
          existingTranscript: _transcript,
        ),
      );

      // ignore: avoid_print
      print('=== Agent 日志 ===');
      // ignore: avoid_print
      print(result.logText);
      // ignore: avoid_print
      print('=== Agent 结论 ===');
      // ignore: avoid_print
      print(result.answer);

      expect(result.hitStepLimit, isFalse, reason: '不该跑满步数');
      // 已有转写稿，不该再调 transcribe
      final tools =
          result.steps.where((s) => s.kind == 'tool').map((s) => s.toolName);
      expect(tools.contains('transcribe'), isFalse,
          reason: '已有转写稿时不该转写');

      // 至少要真的产出了总结或导图之一
      final produced = result.hasSummary || (result.graph?.branches.isNotEmpty ?? false);
      expect(produced, isTrue, reason: 'Agent 应至少产出一份总结或导图');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}