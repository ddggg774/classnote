// test/real_api_levels_test.dart
// 三档总结的真实效果对比（需 DS_KEY，默认跳过）。
//
// 关键点：AiService 用 apiKeyOverride 直接读环境变量里的 Key，
// 绕开 SharedPreferences。这样就不需要 WidgetsBinding，
// 也就不会被 flutter test 的 HTTP 拦截（返回 400）搞坏。
//
// 验证的是"档位是否真的产生结构差异"，不是精确文本（模型每次不同）：
//   brief  只有 3 节，篇幅明显更短
//   normal 九段式
//   detail 九段式 + 原文引用（出现「」）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/services/ai_service.dart';

/// 一段植物学课堂转写（模拟远场识别后的样子，含教材里的核心术语）
const _sample = '''
今天我们讲被子植物的木兰科。木兰科它是原始被子植物的代表类群。
大家看这个 Magnolia denudata，就是白玉兰，它的花被片是不分化的，没有花萼和花冠的区别。
心皮的数目要注意，木兰科是离生心皮，多数螺旋状排列在延长的花托上。
雄蕊群也是多数，花丝短，花药长。
这个离生心皮的结构在考试里会考，要能画出来。
作业是画木兰科花部的纵切图，下周三交，交到学习通。
还有一个重点，木兰科的花是两性花，少数单性。
''';

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;

  group('三档总结结构差异', () {
    test('三档都能跑通，且长度关系符合设计', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final lengths = <SummaryLevel, int>{};

      for (final level in SummaryLevel.values) {
        final result = await ai.summarize(
          _sample,
          level: level,
          courseName: '植物学',
        );
        final md = result.detailMarkdown;
        lengths[level] = md.length;

        // ignore: avoid_print
        print('===== ${level.label}（${level.code}）长度 ${md.length} 字 =====');
        // ignore: avoid_print
        print(md.length > 800 ? '${md.substring(0, 800)}…' : md);
        // ignore: avoid_print
        print('');

        expect(md.trim(), isNotEmpty, reason: '${level.code} 档没有正文');
        expect(md.contains('木兰'), isTrue,
            reason: '${level.code} 档丢了核心术语木兰科');
      }

      expect(lengths[SummaryLevel.brief]!,
          lessThan(lengths[SummaryLevel.normal]!),
          reason: 'brief 应比 normal 短');
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('brief 档只保留三节，不展开例题与术语表', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final r = await ai.summarize(
        _sample,
        level: SummaryLevel.brief,
        courseName: '植物学',
      );
      final md = r.detailMarkdown;
      expect(md.contains('课程信息') || md.contains('知识点'), isTrue);
      expect(md.contains('例题与解题步骤'), isFalse,
          reason: 'brief 档不该展开例题');
      expect(md.contains('术语/公式/英文缩写表'), isFalse,
          reason: 'brief 档不写术语表');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('detail 档带原文引用', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final ai = AiService(apiKeyOverride: key);
      final r = await ai.summarize(
        _sample,
        level: SummaryLevel.detail,
        courseName: '植物学',
      );
      final md = r.detailMarkdown;
      final quoteCount = RegExp('「').allMatches(md).length;
      // ignore: avoid_print
      print('detail 档原文引用数：$quoteCount');
      expect(quoteCount, greaterThan(0), reason: 'detail 档应带原文引用');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}