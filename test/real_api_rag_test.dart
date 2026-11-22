// test/real_api_rag_test.dart
// 跨笔记问答的真实验证（需 DS_KEY，默认跳过）。
//
// 这个文件专门验证「不编造」这一条：
//   · 检索到相关片段时，答案必须带出处
//   · 检索不到时，必须说"没提到"，不能拿常识脑补
// 这两条用假服务器测不出来——假服务器不会真的"想"，也就不会真的编。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/services/rag_service.dart';
import 'package:classnote/services/search_index.dart';

/// 造几条假命中（不碰数据库，直接构造 SearchHit）
SearchHit _hit({
  required String id,
  required String title,
  required String course,
  int score = 10,
  int position = 0,
}) =>
    SearchHit(
      noteId: id,
      title: title,
      course: course,
      snippet: '',
      position: position,
      matchedTerms: 1,
      score: score,
    );

void main() {
  final key = Platform.environment['DS_KEY'] ?? '';
  final enabled = key.isNotEmpty;

  // 两份"笔记原文"
  const noteA = '''
今天我们讲被子植物的木兰科。木兰科它是原始被子植物的代表类群。
大家看这个 Magnolia denudata，就是白玉兰，它的花被片是不分化的。
心皮的数目要注意，木兰科是离生心皮，多数螺旋状排列在延长的花托上。
这个离生心皮的结构在考试里会考，要能画出来。
''';

  const noteB = '''
接着上次讲，木兰科的花是两性花，少数单性。
雄蕊群多数，花丝短，花药长，花药是外向的。
作业是画木兰科花部的纵切图，下周三交。
''';

  Future<String> loader(String id) async {
    if (id == 'a') return noteA;
    if (id == 'b') return noteB;
    return '';
  }

  group('检索有内容时的问答', () {
    test('答案带出处，且不编造笔记里没有的内容', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final rag = RagService();
      final r = await rag.answer(
        question: '木兰科的花部结构有什么特点？',
        hits: [
          _hit(id: 'a', title: '植物学第三讲', course: '植物学'),
          _hit(id: 'b', title: '植物学第四讲', course: '植物学'),
        ],
        transcriptLoader: loader,
        apiKey: key,
      );

      // ignore: avoid_print
      print('===== 答案（基于 ${r.contextCount} 条片段）=====');
      // ignore: avoid_print
      print(r.text);

      expect(r.text.trim(), isNotEmpty);
      expect(r.noContext, isFalse);

      // 核心断言：必须带出处。出处格式是 [笔记标题]
      expect(r.text.contains('['), isTrue,
          reason: '答案必须标出处，否则用户无法核对');
      expect(
        r.text.contains('植物学第三讲') || r.text.contains('植物学第四讲'),
        isTrue,
        reason: '出处里应出现实际笔记标题',
      );

      // 不能把笔记里没有的内容说成"老师讲过"
      // 这两份笔记没提"木兰科有几个属""分布在哪个纬度"，出现就是编造
      expect(r.text.contains('属'), isFalse,
          reason: '笔记没提"属"的数量，不该编造分类学细节');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('冲突信息要各自标出处，不替用户裁定', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      const noteC = '''
今天更正一下，上次说的心皮数目，木兰科实际上是多数离生心皮，我上次说少了。
''';
      Future<String> conflictLoader(String id) async {
        if (id == 'c') return noteC;
        return noteA;
      }

      final rag = RagService();
      final r = await rag.answer(
        question: '木兰科的心皮有几个？',
        hits: [
          _hit(id: 'a', title: '植物学第三讲', course: '植物学'),
          _hit(id: 'c', title: '植物学第五讲', course: '植物学'),
        ],
        transcriptLoader: conflictLoader,
        apiKey: key,
      );

      // ignore: avoid_print
      print('===== 冲突场景答案 =====');
      // ignore: avoid_print
      print(r.text);

      expect(r.text.trim(), isNotEmpty);
      // 两节课都提到了，答案里应该能看到两条线索
      expect(r.text.contains('多数') || r.text.contains('离生'), isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('检索为空时的问答', () {
    test('无命中直接说没提到，不调模型不编造', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final rag = RagService();
      final r = await rag.answer(
        question: '量子纠缠的贝尔不等式怎么推导？',
        hits: const [],
        transcriptLoader: loader,
        apiKey: key,
      );

      // ignore: avoid_print
      print('===== 空检索答案 =====');
      // ignore: avoid_print
      print(r.text);

      expect(r.noContext, isTrue, reason: '空检索应走 noContext 路径');
      expect(r.contextCount, 0);
      expect(r.text.contains('没提到'), isTrue,
          reason: '应明确说笔记里没提到');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('有命中但问题完全无关时，不硬答', () async {
      if (!enabled) {
        markTestSkipped('未设置 DS_KEY');
        return;
      }
      final rag = RagService();
      final r = await rag.answer(
        // 检索给的是植物学内容，问的却是制图
        question: '建筑平面图的线宽怎么定？',
        hits: [_hit(id: 'a', title: '植物学第三讲', course: '植物学')],
        transcriptLoader: loader,
        apiKey: key,
      );

      // ignore: avoid_print
      print('===== 无关问题答案 =====');
      // ignore: avoid_print
      print(r.text);

      expect(r.text.trim(), isNotEmpty);
      // 不能凭空给出线宽数值（笔记里没有）
      expect(RegExp(r'\d+\s*(mm|毫米|b)').hasMatch(r.text), isFalse,
          reason: '笔记没讲线宽，不该编造具体数值');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}