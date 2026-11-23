// test/academic_review_test.dart
// 学科专家质检：路由、JSON 解析、结果清洗。
//
// 这里不测网络，只测「模型给了什么，程序怎么理解」——
// 质检结论要能追到原文，所以空片段、正名前后一致的条目必须被丢掉。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/models/academic_review.dart';
import 'package:classnote/services/academic_review_service.dart';

void main() {
  group('路由', () {
    test('解析带代码块围栏的 JSON', () async {
      final svc = AcademicReviewService(ai: (_, __) async => '''
```json
{"subject_code": "botany", "confidence": 0.93, "reason": "出现叶序、花被等词"}
```''');
      final r = await svc.route('植物学：叶序与花被');
      expect(r.subject, SubjectCode.botany);
      expect(r.confidence, closeTo(0.93, 0.001));
      expect(r.reason, contains('叶序'));
    });

    test('未知学科代码 → general', () async {
      final svc = AcademicReviewService(
          ai: (_, __) async => '{"subject_code": "chemistry", "confidence": 0.9}');
      expect((await svc.route('x')).subject, SubjectCode.general);
    });

    test('置信度过低 → general', () async {
      final svc = AcademicReviewService(
          ai: (_, __) async => '{"subject_code": "law", "confidence": 0.2}');
      expect((await svc.route('随便一段')).subject, SubjectCode.general);
    });

    test('路由输出坏 JSON 不抛异常，退回 general', () async {
      final svc = AcademicReviewService(ai: (_, __) async => '我看是植物学');
      final r = await svc.route('叶序');
      expect(r.subject, SubjectCode.general);
    });
  });

  group('质检结果解析', () {
    test('硬伤/漏洞/术语三类都能解析，术语正名过滤掉相同项', () async {
      final svc = AcademicReviewService(ai: (_, __) async => jsonEncode({
            'agent_name': '植物学质检官',
            'summary': '发现 1 处硬伤',
            'hard_errors': [
              {
                'id': 1,
                'error_type': '分类归属错误',
                'original_text': '芋头是块茎',
                'reason': '芋头是地下球茎',
                'suggestion': '芋头是球茎',
              },
              {
                'id': 2,
                'original_text': '   ',
                'reason': '',
                'suggestion': '',
              },
            ],
            'logic_flaws': [
              {
                'id': 1,
                'original_text': '所以它一定属于单子叶',
                'reason': '缺少依据',
                'suggestion': '补充分类依据',
              },
            ],
            'term_corrections': [
              {'wrong': '花被片', 'correct': '花被', 'reason': '正名'},
              {'wrong': '心皮', 'correct': '心皮', 'reason': '一致，无意义'},
            ],
            'review_advice': '对比记忆地下变态茎四类',
          }));
      final r = await svc.review('芋头是块茎。所以它一定属于单子叶。',
          subject: SubjectCode.botany);
      expect(r.subject, SubjectCode.botany);
      expect(r.agentName, '植物学质检官');
      expect(r.hardErrors.length, 1);
      expect(r.hardErrors.first.errorType, '分类归属错误');
      expect(r.logicFlaws.length, 1);
      expect(r.termCorrections.length, 1);
      expect(r.termCorrections.first.correct, '花被');
      expect(r.issueCount, 3);
    });

    test('未给 subject 时先路由', () async {
      var calls = 0;
      final svc = AcademicReviewService(ai: (system, user) async {
        calls++;
        if (system.contains('路由器')) {
          return '{"subject_code": "computer_science", "confidence": 0.9, "reason": "算法"}';
        }
        return '{"agent_name":"计算机科学质检官","summary":"ok","hard_errors":[],"logic_flaws":[],"term_corrections":[],"review_advice":""}';
      });
      final r = await svc.review('快速排序平均复杂度 O(n log n)');
      expect(calls, 2);
      expect(r.subject, SubjectCode.computerScience);
      expect(r.agentName, '计算机科学质检官');
    });

    test('正文为空直接报错，不发请求', () async {
      var called = false;
      final svc = AcademicReviewService(ai: (_, __) async {
        called = true;
        return '{}';
      });
      await expectLater(svc.review('   ', subject: SubjectCode.general),
          throwsA(isA<Exception>()));
      expect(called, isFalse);
    });
  });

  group('模型', () {
    test('encode / tryDecode 往返', () {
      final r = AcademicReview(
        agentName: '法学质检官',
        subject: SubjectCode.law,
        summary: '1 处硬伤',
        hardErrors: const [
          AcademicHardError(
            id: 1,
            errorType: '法条对不上',
            originalText: '刑法第 20 条讲侵权',
            reason: '第 20 条是正当防卫',
            suggestion: '核对法条编号',
          ),
        ],
        reviewAdvice: '按要件背',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final back = AcademicReview.tryDecode(r.encode())!;
      expect(back.subject, SubjectCode.law);
      expect(back.hardErrors.single.originalText, '刑法第 20 条讲侵权');
      expect(back.createdAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('坏 JSON 返回 null，不抛', () {
      expect(AcademicReview.tryDecode('not json'), isNull);
      expect(AcademicReview.tryDecode(''), isNull);
    });
  });

  group('单句复核', () {
    test('整段判错但单句复核说没错 → 丢掉这条误报', () async {
      final svc = AcademicReviewService(ai: (system, user) async {
        if (system.contains('路由器')) {
          return '{"subject_code":"botany","confidence":0.9,"reason":"植物"}';
        }
        if (system.contains('审稿专家')) {
          if (system.contains('【待审句子】：球茎（如荸荠）')) {
            return '{"original_sentence":"球茎（如荸荠）有明显的节和节间。","has_error":false,"evidence":"经核实无误","correction":"","review_advice":""}';
          }
          return '{"original_sentence":"芋头是块茎","has_error":true,"error_level":"fatal_error","error_category":"分类归属错误","evidence":"芋头是球茎","correction":"芋头是球茎","review_advice":"带茎字的是茎变态"}';
        }
        return '{"agent_name":"植物学质检官","summary":"2 处硬伤","hard_errors":[{"id":1,"original_text":"芋头是块茎","reason":"错","suggestion":"球茎"},{"id":2,"original_text":"球茎（如荸荠）有明显的节和节间。","reason":"错","suggestion":"根状茎"}],"logic_flaws":[],"term_corrections":[],"review_advice":""}';
      });
      final r = await svc.reviewWithVerification('芋头是块茎。球茎（如荸荠）有明显的节和节间。');
      expect(r.hardErrors.length, 1);
      expect(r.hardErrors.single.originalText, '芋头是块茎');
      expect(r.hardErrors.single.verified, isTrue);
      expect(r.hardErrors.single.suggestion, '芋头是球茎');
    });

    test('复核调用失败时保留原判定并标记未核实', () async {
      var verifyCalls = 0;
      final svc = AcademicReviewService(ai: (system, user) async {
        if (system.contains('审稿专家')) {
          verifyCalls++;
          throw Exception('网络炸了');
        }
        return '{"agent_name":"x","summary":"1","hard_errors":[{"id":1,"original_text":"甲句","reason":"r","suggestion":"s"}],"logic_flaws":[],"term_corrections":[],"review_advice":""}';
      });
      final r = await svc.reviewWithVerification('甲句', subject: SubjectCode.general);
      expect(verifyCalls, 1);
      expect(r.hardErrors.length, 1);
      expect(r.hardErrors.single.verified, isFalse);
    });
  });

  group('逐句全审', () {
    test('分句跳过标题与短句', () {
      const text = """
一、地下变态茎
芋头是典型的块茎，属于叶的变态。
球茎（如荸荠）有明显的节和节间。
短。
二、地上变态茎
茎刺与叶刺是同源结构。
""";
      final list = AcademicReviewService.splitSentences(text);
      expect(list.length, 3);
      expect(list.first, '芋头是典型的块茎，属于叶的变态。');
      expect(list.any((e) => e.startsWith('一、')), isFalse);
      expect(list.any((e) => e == '短。'), isFalse);
    });

    test('fatal_error 进硬伤，warning 进不严谨，并按句聚合成 summary', () async {
      final svc = AcademicReviewService(ai: (system, user) async {
        if (system.contains('路由器')) {
          return '{"subject_code":"botany","confidence":0.9,"reason":"植物"}';
        }
        if (system.contains('【待审句子】：芋头是典型的块茎')) {
          return '{"original_sentence":"芋头是典型的块茎。","has_error":true,"error_level":"fatal_error","error_category":"分类归属错误","evidence":"芋头是球茎","correction":"芋头是球茎。","review_advice":"茎变态"}';
        }
        if (system.contains('【待审句子】：鳞茎（如洋葱）')) {
          return '{"original_sentence":"鳞茎（如洋葱）由鳞叶包裹。","has_error":true,"error_level":"warning","error_category":"术语口语化","evidence":"应说明鳞茎盘","correction":"鳞茎由鳞茎盘和鳞叶组成。","review_advice":"补结构"}';
        }
        return '{"original_sentence":"x","has_error":false,"evidence":"经核实无误","correction":"","review_advice":""}';
      });
      final r = await svc.reviewAllSentences(
          '芋头是典型的块茎，属于叶的变态。鳞茎（如洋葱）由鳞叶包裹。球茎（如荸荠）有节和节间。');
      expect(r.summary, contains('逐句审阅'));
      expect(r.hardErrors.length, 1);
      expect(r.hardErrors.single.errorType, '分类归属错误');
      expect(r.hardErrors.single.evidence, '芋头是球茎');
      expect(r.logicFlaws.length, 1);
      expect(r.logicFlaws.single.originalText, contains('鳞茎'));
    });
  });

  group('知识库依据', () {
    test('按二字组重迭挑证据', () {
      const pool = [
        ReviewEvidence('芋头：地下变态茎中的球茎，具环状节和退化叶', source: '知识库'),
        ReviewEvidence('光合作用：把光能转成化学能', source: '知识库'),
      ];
      final picked =
          AcademicReviewService.pickEvidence('芋头是典型的块茎。', pool);
      expect(picked.length, 1);
      expect(picked.single.text, contains('芋头'));
    });

    test('没引用给定依据的硬伤降为存疑', () async {
      final svc = AcademicReviewService(ai: (system, user) async {
        if (system.contains('路由器')) {
          return '{"subject_code":"botany","confidence":0.9,"reason":"植物"}';
        }
        return '{"original_sentence":"芋头是块茎。","has_error":true,"error_level":"fatal_error","error_category":"分类归属错误","evidence":"凭我自己的记忆判断","correction":"芋头是球茎。","review_advice":""}';
      });
      final r = await svc.reviewAllSentences(
        '芋头是典型的块茎。',
        evidence: const [
          ReviewEvidence('芋头：地下变态茎中的球茎，具环状节和退化叶'),
        ],
      );
      expect(r.hardErrors, isEmpty);
      expect(r.logicFlaws.length, 1);
      expect(r.summary, contains('降为存疑'));
    });

    test('引用到给定依据时保留硬伤', () async {
      final svc = AcademicReviewService(ai: (system, user) async {
        if (system.contains('路由器')) {
          return '{"subject_code":"botany","confidence":0.9,"reason":"植物"}';
        }
        return '{"original_sentence":"芋头是块茎。","has_error":true,"error_level":"fatal_error","error_category":"分类归属错误","evidence":"知识库：芋头是地下变态茎中的球茎，具环状节和退化叶","correction":"芋头是球茎。","review_advice":""}';
      });
      final r = await svc.reviewAllSentences(
        '芋头是典型的块茎。',
        evidence: const [
          ReviewEvidence('芋头：地下变态茎中的球茎，具环状节和退化叶'),
        ],
      );
      expect(r.hardErrors.length, 1);
      expect(r.summary, isNot(contains('降为存疑')));
    });
  });

  group('向量检索接入', () {
    test('retriever 提供的依据能被引用并保留硬伤', () async {
      final svc = AcademicReviewService(ai: (system, user) async {
        if (system.contains('路由器')) {
          return '{"subject_code":"botany","confidence":0.9,"reason":"植物"}';
        }
        return '{"original_sentence":"芋头是块茎。","has_error":true,"error_level":"fatal_error","error_category":"分类归属错误","evidence":"芋头是地下变态茎中的球茎，具环状节和退化叶","correction":"芋头是球茎。","review_advice":""}';
      });
      final r = await svc.reviewAllSentences(
        '芋头是典型的块茎。',
        retriever: (sentence) => const [
          ReviewEvidence('芋头：地下变态茎中的球茎，具环状节和退化叶', source: '课堂笔记'),
        ],
      );
      expect(r.hardErrors.length, 1);
      expect(r.summary, contains('已提供'));
    });

    test('retriever 给的依据没被引用 → 降为存疑', () async {
      final svc = AcademicReviewService(ai: (system, user) async {
        if (system.contains('路由器')) {
          return '{"subject_code":"botany","confidence":0.9,"reason":"植物"}';
        }
        return '{"original_sentence":"芋头是块茎。","has_error":true,"error_level":"fatal_error","error_category":"分类归属错误","evidence":"我个人觉得不对","correction":"芋头是球茎。","review_advice":""}';
      });
      final r = await svc.reviewAllSentences(
        '芋头是典型的块茎。',
        retriever: (sentence) => const [
          ReviewEvidence('芋头：地下变态茎中的球茎，具环状节和退化叶'),
        ],
      );
      expect(r.hardErrors, isEmpty);
      expect(r.logicFlaws.length, 1);
    });
  });
}