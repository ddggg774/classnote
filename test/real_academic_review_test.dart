// test/real_academic_review_test.dart
// 真实调用：用 DS_KEY 环境变量跑一遍「路由 → 学科质检」。
//
// 没设 DS_KEY 时整组跳过，不消耗额度；设了才花钱（约 0.01~0.02 元/次）。
//
// 运行：
//   DS_KEY=sk-... flutter test --no-pub test/real_academic_review_test.dart
//
// 样例笔记故意埋了 4 个植物学硬伤，用来验证专家能不能抓到、会不会乱报。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/models/academic_review.dart';
import 'package:classnote/services/academic_review_service.dart';
import 'package:classnote/services/local_vector.dart';

const String sampleBirdNote = '''
植物学 · 第四章 茎的变态与叶的变态

一、地下变态茎
芋头是典型的块茎，属于叶的变态，表面有明显的芽眼。马铃薯也是块茎。
球茎（如荸荠）有明显的节和节间，节上有膜质鳞叶。
鳞茎（如洋葱）由肥厚的鳞叶层层包裹。

二、地上变态茎
茎刺与叶刺是同源结构，都由茎发育而来，例如山楂的刺就是叶刺。
茎卷须见于葡萄、南瓜；叶卷须见于豌豆；托叶卷须见于菝葜。

三、叶的变态
捕虫叶（如猪笼草）的捕虫机制主要靠消化腺分泌蛋白酶来触发，刚毛只是辅助结构。
天南星科的红掌，其花序外面的保护结构叫花瓣。

四、适应意义
地下变态茎的核心适应意义是储藏营养、度过不良环境、营养繁殖。
''';

void main() {
  final key = Platform.environment['DS_KEY']?.trim() ?? '';
  if (key.isEmpty) {
    test('缺少 DS_KEY，跳过真实质检', () {}, skip: '未设置 DS_KEY');
    return;
  }

  test('真实链路：路由 → 植物学专家质检', () async {
    final svc = AcademicReviewService(apiKeyOverride: key);

    final route = await svc.route(sampleBirdNote);
    // ignore: avoid_print
    print('ROUTE ${jsonEncode({
      'subject': route.subject.code,
      'confidence': route.confidence,
      'reason': route.reason,
    })}');

    final review = await svc.reviewWithVerification(
      sampleBirdNote,
      subject: route.subject,
      course: '植物学',
    );

    // ignore: avoid_print
    print('REVIEW ${jsonEncode({
      'agent': review.agentName,
      'subject': review.subject.code,
      'summary': review.summary,
      'hardErrors': review.hardErrors
          .map((e) => {
                'type': e.errorType,
                'original': e.originalText,
                'suggestion': e.suggestion,
                'verified': e.verified,
                'evidence': e.evidence,
              })
          .toList(),
      'logicFlaws': review.logicFlaws
          .map((e) => {'original': e.originalText, 'suggestion': e.suggestion})
          .toList(),
      'terms': review.termCorrections
          .map((e) => '${e.wrong}→${e.correct}')
          .toList(),
      'advice': review.reviewAdvice,
    }, toEncodable: (o) => o.toString())}');

    expect(review.summary, isNotEmpty);
    expect(review.subject, SubjectCode.botany);
    // 单句复核后：埋的 4 个硬伤至少要留下 3 个
    expect(review.hardErrors.length >= 3, isTrue,
        reason: '样例里埋了 4 个硬伤，复核后剩下不到 3 个说明二审杀过头了');
    // 回归：这句本身正确，单句复核应把它挡掉
    expect(
      review.hardErrors.any((e) => e.originalText.contains('球茎（如荸荠）')),
      isFalse,
      reason: '「球茎（如荸荠）有明显的节和节间」是对的，不该出现在硬伤里',
    );
    // 每条硬伤都能回到原文
    for (final e in review.hardErrors) {
      expect(e.originalText.trim(), isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('真实链路：逐句全审（每句单独判）', () async {
    final svc = AcademicReviewService(apiKeyOverride: key);
    const evidence = [
      ReviewEvidence('芋头：地下变态茎中的球茎，具环状节和退化叶，属茎的变态', source: '知识库'),
      ReviewEvidence('茎刺：由茎（枝）变态形成，如山楂的刺', source: '知识库'),
      ReviewEvidence('叶刺：由叶变态形成，如小檗的刺', source: '知识库'),
      ReviewEvidence('佛焰苞：天南星科花序外包被的变态叶，如红掌', source: '知识库'),
      ReviewEvidence('捕虫叶：触发靠感觉毛，消化靠消化腺分泌酶', source: '知识库'),
    ];
    final index = EvidenceIndex.build([
      for (final e in evidence)
        VectorDoc(e.text, source: e.source, course: '植物学'),
    ]);
    final review = await svc.reviewAllSentences(
      sampleBirdNote,
      course: '植物学',
      evidence: evidence,
      retriever: (sentence) async => index
          .search(sentence, k: 2)
          .map((r) => ReviewEvidence(r.doc.text, source: r.doc.source))
          .toList(),
    );
    // ignore: avoid_print
    print('ALL ${jsonEncode({
      'summary': review.summary,
      'hard': review.hardErrors
          .map((e) => {'original': e.originalText, 'type': e.errorType})
          .toList(),
      'flaws': review.logicFlaws.map((e) => e.originalText).toList(),
    }, toEncodable: (o) => o.toString())}');

    expect(review.summary, contains('逐句审阅'));
    expect(review.hardErrors.length >= 3, isTrue);
    expect(
      review.hardErrors.any((e) => e.originalText.contains('球茎（如荸荠）')),
      isFalse,
      reason: '正确句子不该被判硬伤',
    );
  }, timeout: const Timeout(Duration(minutes: 6)));
}