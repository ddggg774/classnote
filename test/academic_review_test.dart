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
}