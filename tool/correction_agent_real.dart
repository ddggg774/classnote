// tool/correction_agent_real.dart
// 用真实 DeepSeek API 跑纠错子 Agent，验证两件事：
//   ① Function Calling 真的被触发（工具调用计数 > 0）
//   ② 低置信度内容只标待确认、不编造
//
// 运行方式（Key 从环境变量读，不写进代码）：
//   DS_KEY=sk-xxx dart run tool/correction_agent_real.dart
import 'dart:io';

import 'package:classnote/agent/agent_loop.dart';
import 'package:classnote/agent/correction_agent.dart';
import 'package:classnote/models/terminology.dart';

void main() async {
  final key = Platform.environment['DS_KEY'] ?? '';
  if (key.isEmpty) {
    stdout.writeln('用法: DS_KEY=sk-xxx dart run tool/correction_agent_real.dart');
    exit(1);
  }

  // 构造一份「已知答案」的术语包：
  // 这样能判断 Agent 是真的拿术语表在纠错，还是凭感觉猜。
  final pack = TerminologyPack(
    courseName: '植物学',
    topic: '第三章 被子植物',
    terms: const [
      Term(term: '木兰科', misheard: '木兰颗/木蓝科', level: TermLevel.high),
      Term(term: 'Magnolia denudata', misheard: 'magnolia denudata', level: TermLevel.high),
      Term(term: '心皮', misheard: '心脾/新皮', level: TermLevel.high),
      Term(term: '雄蕊群', misheard: '雄瑞群/熊蕊群', level: TermLevel.mid),
      Term(term: '离生心皮', misheard: '离心皮/里生心皮', level: TermLevel.mid),
      Term(term: '花被片', misheard: '花背部/花瓣片', level: TermLevel.mid),
      Term(term: '托叶', misheard: '拖叶/脱叶', level: TermLevel.low),
    ],
    initialPrompt: '本节课涉及：木兰科、Magnolia denudata、心皮、雄蕊群。',
    riskHints: const [
      '拉丁学名远场易被整体吞掉或大小写错乱',
      '前后鼻音词（心皮/新皮）易混',
    ],
    createdAt: DateTime.now(),
  );

  // 故意混入：3 处可修正的误听 + 1 处无法判断的乱码 + 1 处断句
  const transcript = '''
今天讲被子植物的木兰科。这个木兰颗啊，是原始被子植物的代表。
你们看这个 Magnolia denudata，它的花被片是分化的。
注意心脾的数目，离生心皮的排列方式要记住。
那个雄瑞群和雌蕊群的位置关系，考试会考。
然后这个拖叶的形态，嗯，那个叫什么的，就是前面提到的那东西。
还有这一段：老师说这个结构很重要，但是录音到这里就断了。
''';

  stdout.writeln('=== 课程: ${pack.courseName} / ${pack.topic}');
  stdout.writeln('=== 术语表: ${pack.terms.length} 条（已注入，不现生成）');
  stdout.writeln('=== 输入转写: ${transcript.trim().length} 字');
  stdout.writeln();

  // 用 presetPack 注入术语包，避免现场再生成一遍（省一次调用）
  final agent = CorrectionAgent(
    apiKey: key,
    presetPack: pack,
  );

  final sw = Stopwatch()..start();
  final result = await agent.run(
    transcript,
    course: '植物学',
    chapter: '第三章 被子植物',
    onStep: (step) {
      stdout.writeln('  · ${step.line}');
    },
  );
  sw.stop();

  stdout.writeln();
  stdout.writeln('=== 耗时: ${sw.elapsed.inSeconds}s');
  stdout.writeln('=== 步数: ${result.steps.length}');
  final toolCalls = result.steps.where((s) => s.kind == 'tool').length;
  stdout.writeln('=== 工具调用次数: $toolCalls');

  stdout.writeln();
  stdout.writeln('=== 是否触达步数上限: ${result.hitStepLimit}');
  stdout.writeln('=== 是否失败: ${result.failed}');

  stdout.writeln();
  stdout.writeln('===== Agent 总结 =====');
  stdout.writeln(result.summary);

  stdout.writeln();
  stdout.writeln('===== 待确认清单（${result.pending.length} 项）=====');
  for (final p in result.pending) {
    stdout.writeln('- ${p.snippet}'
        '${p.candidates.isEmpty ? '' : ' 〔疑似：${p.candidates.join(' / ')}〕'}'
        '${p.count > 1 ? '（${p.count} 次）' : ''}');
  }

  stdout.writeln();
  stdout.writeln('===== 缺失位置（${result.missing.length} 处）=====');
  for (final m in result.missing) {
    stdout.writeln('- $m');
  }

  // 自动验收：工具是否真被调用
  stdout.writeln();
  stdout.writeln('===== 验收 =====');
  stdout.writeln(toolCalls > 0 ? '✓ 工具被调用（Function Calling 生效）' : '✗ 工具未被调用');
  stdout.writeln(result.pending.isNotEmpty
      ? '✓ 有待确认项（说明没有硬猜）'
      : '⚠ 没有待确认项，需人工检查是否过度自信');
}
