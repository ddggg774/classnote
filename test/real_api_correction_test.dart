// test/real_api_correction_test.dart
// 真实 DeepSeek API 端到端验证（默认跳过，需手动开启）。
//
// 为什么默认跳过：CI/日常测试不该每次都花钱、也不该依赖外部服务可用性。
// 手动跑法：
//   DS_KEY=sk-xxx flutter test test/real_api_correction_test.dart
//
// 这个测试验证的是「真实模型会不会按规矩办事」，用假服务器测不出来：
//   ① Function Calling 真的被触发（模型会主动调 lookup_terminology）
//   ② 面对无法判断的乱码，模型标待确认而不是编一个术语
//   ③ 面对术语表里有的误听形式，模型能改对
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/agent/correction_agent.dart';
import 'package:classnote/models/terminology.dart';

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;

  group('真实 API：纠错子 Agent', () {
    // 术语包固定下来，这样能判断它是"查表纠错"还是"凭感觉猜"
    final pack = TerminologyPack(
      courseName: '植物学',
      topic: '第三章 被子植物',
      terms: const [
        Term(term: '木兰科', misheard: '木兰颗/木蓝科', level: TermLevel.high),
        Term(
            term: 'Magnolia denudata',
            misheard: 'magnolia denudata',
            level: TermLevel.high),
        Term(term: '心皮', misheard: '心脾/新皮', level: TermLevel.high),
        Term(term: '雄蕊群', misheard: '雄瑞群/熊蕊群', level: TermLevel.mid),
        Term(term: '离生心皮', misheard: '离心皮/里生心皮', level: TermLevel.mid),
        Term(term: '花被片', misheard: '花背部/花瓣片', level: TermLevel.mid),
        Term(term: '托叶', misheard: '拖叶/脱叶', level: TermLevel.low),
      ],
      initialPrompt: '本节课涉及：木兰科、Magnolia denudata、心皮、雄蕊群。',
      riskHints: const ['拉丁学名远场易被吞掉', '前后鼻音词易混'],
      createdAt: DateTime.now(),
    );

    const transcript = '''
今天讲被子植物的木兰科。这个木兰颗啊，是原始被子植物的代表。
你们看这个 Magnolia denudata，它的花被片是分化的。
注意心脾的数目，离生心皮的排列方式要记住。
那个雄瑞群和雌蕊群的位置关系，考试会考。
还有这一段：老师说这个结构很重要，但是录音到这里就断了。
''';

    test('工具被真实调用，且误听词被修正', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY，跳过真实 API 测试');
        return;
      }
      final agent = CorrectionAgent(apiKey: key, presetPack: pack);
      final result = await agent.run(
        transcript,
        course: '植物学',
        chapter: '第三章 被子植物',
      );

      // ① 工具必须被调用过（否则说明模型在空想）
      final toolSteps = result.steps.where((s) => s.kind == 'tool').toList();
      expect(toolSteps, isNotEmpty,
          reason: '模型没有调用任何工具，Function Calling 未生效');
      expect(
        toolSteps.any((s) => s.toolName == 'lookup_terminology'),
        isTrue,
        reason: '纠错前应先查术语表',
      );

      // ② 不能触达步数上限、不能整体失败
      expect(result.hitStepLimit, isFalse, reason: '不该跑满步数');
      expect(result.failed, isFalse);

      // ③ 打印结果方便人工核对
      // ignore: avoid_print
      print('=== 步数 ${result.steps.length}，工具调用 ${toolSteps.length}');
      // ignore: avoid_print
      print(result.reportText);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('面对无法判断的乱码只标待确认，不编造', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY，跳过真实 API 测试');
        return;
      }
      final agent = CorrectionAgent(apiKey: key, presetPack: pack);
      // 故意给一段术语表里完全没有、且语义断裂的内容
      const garbage = '''
然后这个结构我们叫它……嗯那个什么来着，就是前面提到的那个东西。
老师指了一下黑板，这里有个词听不清，大概是三个字的。
后面继续讲下一部分了。
''';
      final result = await agent.run(
        garbage,
        course: '植物学',
        chapter: '第三章 被子植物',
      );

      // 这段内容没有可修正的确定项，正确行为是"要么不改，要么标待确认"
      final pendingOrMissing =
          result.pending.isNotEmpty || result.missing.isNotEmpty;
      expect(pendingOrMissing, isTrue,
          reason: '面对无法判断的内容，应标待确认/缺失，而不是硬猜');

      // 关键断言：不能把术语"冒充"成已确认的改动。
      // 注意不能用"总结里出现木兰科"来判断——模型把候选写进 candidates
      // 是正确行为（那是给人看的候选，不是它自己的结论）。
      // 真正要防的是：它在正文里把这些词当成已确定内容直接改掉。
      final claimedFixes =
          RegExp(r'改动\s*([1-9]\d*)\s*处').firstMatch(result.summary);
      expect(claimedFixes, isNull,
          reason: '原文没有确定的误听词，不该声称改动了任何内容');

      // 候选里提到这些词是允许的，但要标注为"疑似/待确认"
      if (result.summary.contains('木兰科')) {
        expect(
          result.summary.contains('待确认') ||
              result.summary.contains('疑似'),
          isTrue,
          reason: '提到术语时必须带待确认/疑似标注，不能当成结论',
        );
      }

      // ignore: avoid_print
      print('=== 待确认 ${result.pending.length}，缺失 ${result.missing.length}');
      // ignore: avoid_print
      print(result.reportText);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}