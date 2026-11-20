// test/real_api_quickrun_test.dart
// 「一键处理」端到端验证（需 DS_KEY，默认跳过）。
//
// 模拟录音页的完整调用路径：给定文本 → ClassroomAgent.run →
// 拿 ClassroomResult 拼 summaryJson → 再解码回来验证能读。
// 这一段最容易出错的是"存进去了但详情页读不出来"，所以必须做往返验证。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/agent/classroom_agent.dart';
import 'package:classnote/models/mind_graph.dart';
import 'package:classnote/models/note.dart';
import 'package:classnote/models/study_note.dart';
import 'package:classnote/models/summary_level.dart';

const _transcript = '''
今天我们讲被子植物的木兰科。木兰科它是原始被子植物的代表类群。
大家看这个 Magnolia denudata，就是白玉兰，它的花被片是不分化的。
心皮的数目要注意，木兰科是离生心皮，多数螺旋状排列在延长的花托上。
雄蕊群也是多数，花丝短，花药长。雌蕊群在花托的顶部。
这个离生心皮的结构在考试里会考，要能画出来。
作业是画木兰科花部的纵切图，下周三交，交到学习通。
''';

/// 复刻 record_page 里的落库逻辑，确保测的就是真实那份
String? buildSummaryJson(ClassroomResult result) {
  final md = (result.summary ?? '').trim();
  final graph = result.graph;
  final hasGraph = graph != null && graph.branches.isNotEmpty;
  if (md.isEmpty && !hasGraph) return null;

  final nodes = <MindNode>[];
  if (hasGraph) {
    for (final branch in graph.branches) {
      final children = <String>[];
      for (final child in branch.children) {
        children.add(child.title);
        for (final grand in child.children) {
          children.add(grand.title);
        }
      }
      nodes.add(MindNode(topic: branch.title, children: children));
    }
  }

  return StudySummary(
    detailMarkdown: md,
    mindMap: hasGraph
        ? MindMapData(
            root: graph.root,
            nodes: nodes,
          )
        : MindMapData(root: '', nodes: const []),
    graph: hasGraph
        ? graph
        : MindGraph.fromLegacyMindMap(MindMapData(root: '', nodes: const [])),
  ).encode();
}

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;

  group('一键处理端到端', () {
    test('跑通并落库往返可读', () async {
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
      print('=== 步骤日志 ===');
      // ignore: avoid_print
      print(result.logText);

      expect(result.hitStepLimit, isFalse);
      expect(result.hasSummary, isTrue, reason: '应该产出总结');

      // ① 落库 JSON 能生成
      final json = buildSummaryJson(result);
      expect(json, isNotNull);
      // ignore: avoid_print
      print('=== summaryJson ${json!.length} 字节');

      // ② 往返：详情页的解析逻辑能读回来
      final decoded = StudySummary.tryDecode(json);
      expect(decoded, isNotNull, reason: '存进去的 JSON 必须能被详情页解码');
      expect(decoded!.detailMarkdown.trim(), isNotEmpty);
      // ignore: avoid_print
      print('=== 解码后：正文 ${decoded.detailMarkdown.length} 字，'
          '导图 ${decoded.graph.branches.length} 分支 '
          '${decoded.graph.totalNodes} 节点 最深 ${decoded.graph.maxDepth} 级');

      // ③ 导图结构可用
      expect(decoded.graph.branches, isNotEmpty);
      expect(decoded.graph.maxDepth, greaterThanOrEqualTo(2));

      // ④ legacy 大纲也有内容（旧 Tab 与 PNG 导出依赖它）
      expect(decoded.mindMap.nodes, isNotEmpty,
          reason: 'legacy mindMap 必须由 graph 反推出来，否则大纲 Tab 会空白');
      // ignore: avoid_print
      print('=== legacy 大纲 ${decoded.mindMap.nodes.length} 个一级节点');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('关掉导图时不产出导图', () async {
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
          wantMindMap: false,
        ),
      );

      // ignore: avoid_print
      print('=== 关闭导图后日志 ===');
      // ignore: avoid_print
      print(result.logText);

      expect(result.hasSummary, isTrue);
      // 关了开关就不该留下导图（否则等于没关）
      expect(result.graph, isNull,
          reason: 'wantMindMap=false 时不该保留导图');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}