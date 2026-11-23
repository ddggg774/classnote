// lib/models/academic_review.dart
import 'dart:convert';
// 学科专家质检的结果模型。
//
// 与「术语校准」的区别：校准只解决「字写错了」，这里是判断「知识对不对」。
// 所以硬伤（分类/机制/因果）与逻辑不严谨分开记，术语纠正是附带产物。

/// 支持的学科。新增学科时在这里加一项，并在服务里补领域规则。
enum SubjectCode { botany, computerScience, law, general }

extension SubjectCodeX on SubjectCode {
  String get code => switch (this) {
        SubjectCode.botany => 'botany',
        SubjectCode.computerScience => 'computer_science',
        SubjectCode.law => 'law',
        SubjectCode.general => 'general',
      };

  String get label => switch (this) {
        SubjectCode.botany => '植物学',
        SubjectCode.computerScience => '计算机科学',
        SubjectCode.law => '法学',
        SubjectCode.general => '通用学术',
      };

  static SubjectCode fromCode(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    for (final s in SubjectCode.values) {
      if (s.code == v) return s;
    }
    return SubjectCode.general;
  }
}

/// 路由结果：这段笔记该交给哪个学科专家
class SubjectRoute {
  final SubjectCode subject;
  final double confidence;
  final String reason;

  const SubjectRoute({
    required this.subject,
    this.confidence = 0,
    this.reason = '',
  });
}

/// 硬伤：违背科学事实（分类归属、概念混淆、机制错误）
class AcademicHardError {
  final int id;
  final String errorType;
  final String originalText;
  final String reason;
  final String suggestion;

  const AcademicHardError({
    required this.id,
    this.errorType = '',
    required this.originalText,
    this.reason = '',
    this.suggestion = '',
  });
}

/// 逻辑不严谨：不一定是错的，但会丢分或产生误解
class AcademicLogicFlaw {
  final int id;
  final String originalText;
  final String reason;
  final String suggestion;

  const AcademicLogicFlaw({
    required this.id,
    required this.originalText,
    this.reason = '',
    this.suggestion = '',
  });
}

/// 术语纠正：口语化/错误写法 → 标准术语
class AcademicTermCorrection {
  final String wrong;
  final String correct;
  final String reason;

  const AcademicTermCorrection({
    required this.wrong,
    required this.correct,
    this.reason = '',
  });
}

/// 一次完整的学科质检结果
class AcademicReview {
  final String agentName;
  final SubjectCode subject;
  final String summary;
  final List<AcademicHardError> hardErrors;
  final List<AcademicLogicFlaw> logicFlaws;
  final List<AcademicTermCorrection> termCorrections;
  final String reviewAdvice;
  final DateTime createdAt;

  const AcademicReview({
    required this.agentName,
    required this.subject,
    required this.summary,
    this.hardErrors = const [],
    this.logicFlaws = const [],
    this.termCorrections = const [],
    this.reviewAdvice = '',
    required this.createdAt,
  });

  int get issueCount =>
      hardErrors.length + logicFlaws.length + termCorrections.length;

  Map<String, dynamic> toJson() => {
        'agentName': agentName,
        'subject': subject.code,
        'summary': summary,
        'hardErrors': hardErrors
            .map((e) => {
                  'id': e.id,
                  'errorType': e.errorType,
                  'originalText': e.originalText,
                  'reason': e.reason,
                  'suggestion': e.suggestion,
                })
            .toList(),
        'logicFlaws': logicFlaws
            .map((e) => {
                  'id': e.id,
                  'originalText': e.originalText,
                  'reason': e.reason,
                  'suggestion': e.suggestion,
                })
            .toList(),
        'termCorrections': termCorrections
            .map((e) => {
                  'wrong': e.wrong,
                  'correct': e.correct,
                  'reason': e.reason,
                })
            .toList(),
        'reviewAdvice': reviewAdvice,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  String encode() => jsonEncode(toJson());

  factory AcademicReview.fromJson(Map<String, dynamic> json) {
    // 模型按提示词输出 snake_case，本地存的是 camelCase，两种都认。
    Object? pick(String camel, String snake) => json[camel] ?? json[snake];

    List<Map<String, dynamic>> list(String camel, String snake) =>
        ((pick(camel, snake) as List?) ?? [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();

    return AcademicReview(
      agentName: (pick('agentName', 'agent_name') ?? '学科质检官').toString(),
      subject: SubjectCodeX.fromCode(json['subject']?.toString()),
      summary: (json['summary'] ?? '').toString(),
      hardErrors: list('hardErrors', 'hard_errors')
          .map((m) => AcademicHardError(
                id: (m['id'] as num?)?.toInt() ?? 0,
                errorType:
                    (m['errorType'] ?? m['error_type'] ?? '').toString(),
                originalText:
                    (m['originalText'] ?? m['original_text'] ?? '').toString(),
                reason: (m['reason'] ?? '').toString(),
                suggestion: (m['suggestion'] ?? '').toString(),
              ))
          .toList(),
      logicFlaws: list('logicFlaws', 'logic_flaws')
          .map((m) => AcademicLogicFlaw(
                id: (m['id'] as num?)?.toInt() ?? 0,
                originalText:
                    (m['originalText'] ?? m['original_text'] ?? '').toString(),
                reason: (m['reason'] ?? '').toString(),
                suggestion: (m['suggestion'] ?? '').toString(),
              ))
          .toList(),
      termCorrections: list('termCorrections', 'term_corrections')
          .map((m) => AcademicTermCorrection(
                wrong: (m['wrong'] ?? '').toString(),
                correct: (m['correct'] ?? '').toString(),
                reason: (m['reason'] ?? '').toString(),
              ))
          .toList(),
      reviewAdvice:
          (pick('reviewAdvice', 'review_advice') ?? '').toString(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch),
    );
  }

  static AcademicReview? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return AcademicReview.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}