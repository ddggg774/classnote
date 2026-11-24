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
import 'package:classnote/models/terminology.dart';

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
    graph: hasGraph ? graph : const MindGraph(root: '', branches: []),
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

    }, timeout: const Timeout(Duration(minutes: 5)));

    test('待确认项带上位置并能随总结落库', () async {
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
      print('=== Agent 返回的待确认项 ${result.pendingNotes.length} 条');
      for (final n in result.pendingNotes) {
        // ignore: avoid_print
        print('  · $n');
      }

      // 把待确认项按 record_page 的方式构造并定位
      final source = result.finalText ?? '';
      final items = <PendingItem>[];
      for (final note in result.pendingNotes) {
        if (note.startsWith('〔缺失〕')) {
          items.add(PendingItem(snippet: note.substring(4).trim()));
          continue;
        }
        final m = RegExp(r'^(.*?)(?:〔疑似：(.*?)〕)?$').firstMatch(note);
        final snippet = (m?.group(1) ?? note).trim();
        final candRaw = m?.group(2) ?? '';
        items.add(PendingItem(
          snippet: snippet,
          candidates: candRaw
              .split('/')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        ));
      }
      final located = CalibrationReport(
        annotatedText: '',
        pending: items,
      ).withLocations(source);

      // ignore: avoid_print
      print('=== 定位结果（共 ${located.pending.length} 条）');
      for (final p in located.pending) {
        // ignore: avoid_print
        print('  · ${p.snippet} → '
            '${p.canLocate ? '可定位 @${p.firstPosition}' : '不可定位'}');
      }

      // 落库往返
      final json = StudySummary(
        detailMarkdown: result.summary ?? '',
        graph: result.graph ?? const MindGraph(root: '', branches: []),
        pending: located.pending,
      ).encode();
      final decoded = StudySummary.tryDecode(json);
      expect(decoded, isNotNull);
      expect(decoded!.pending.length, located.pending.length,
          reason: '待确认项必须随总结落库并能读回');

      // 有定位的项，位置必须在正文范围内
      for (final p in decoded.pending.where((p) => p.canLocate)) {
        expect(p.firstPosition! >= 0, isTrue);
        expect(p.firstPosition! + p.snippet.length <= source.length, isTrue,
            reason: '位置越界会导致跳转时选中错误内容');
      }
      // ignore: avoid_print
      print('=== 往返解码后 ${decoded.pending.length} 条，'
          '其中 ${decoded.pending.where((p) => p.canLocate).length} 条可定位');
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