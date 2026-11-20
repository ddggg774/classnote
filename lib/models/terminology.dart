// lib/models/terminology.dart
// 课堂术语表与转写质量校准的数据模型。
//
// 设计目标来自一套「术语纠错与质量校准层」的规格：
//   ① 课前先按课程信息生成术语表（高/中/低三级 + 常见误听形式）；
//   ② 生成 Whisper initial_prompt 与拾音风险提示；
//   ③ 转写后按 A/B/C 三档规则处理：高置信直接改、低置信标注、远场缺失标注；
//   ④ 产出四段报告：纠错正文 / 术语命中 / 待确认清单 / 拾音建议。
//
// 为什么术语要带「常见误听形式」：
//   ASR 出错不是随机的，而是系统性地把术语听成音近/形近的另一个词
//   （"洛必达"→"洛比达"、"pathname"→"pass name"）。把这个映射前置写好，
//   纠错时才有"音素依据"可循，而不是让模型凭感觉猜。
import 'dart:convert';

/// 术语优先级。高 = 本节课核心概念/公式名/定理名/人名；
/// 中 = 一般专业词汇；低 = 英文缩写/代码名/工具名。
enum TermLevel {
  high('高', '核心概念、公式名、定理名、人名'),
  mid('中', '一般专业词汇'),
  low('低', '英文缩写、代码名、工具名');

  const TermLevel(this.label, this.meaning);
  final String label;
  final String meaning;

  static TermLevel fromCode(String? code) {
    switch (code) {
      case 'high':
      case '高':
        return TermLevel.high;
      case 'mid':
      case '中':
        return TermLevel.mid;
      case 'low':
      case '低':
        return TermLevel.low;
      default:
        return TermLevel.mid;
    }
  }

  String get code {
    switch (this) {
      case TermLevel.high:
        return 'high';
      case TermLevel.mid:
        return 'mid';
      case TermLevel.low:
        return 'low';
    }
  }
}

/// 一条术语
class Term {
  /// 标准写法（纠错时的目标）
  final String term;

  /// 常见误听形式：用「/」分隔的多个候选，如 "洛比达/洛必塔"
  final String misheard;

  final TermLevel level;

  const Term({
    required this.term,
    this.misheard = '',
    this.level = TermLevel.mid,
  });

  factory Term.fromJson(Map<String, dynamic> json) => Term(
        term: (json['term'] ?? '').toString().trim(),
        misheard: (json['misheard'] ?? '').toString().trim(),
        level: TermLevel.fromCode(json['level']?.toString()),
      );

  Map<String, dynamic> toJson() => {
        'term': term,
        if (misheard.isNotEmpty) 'misheard': misheard,
        'level': level.code,
      };

  /// 误听形式列表（去掉空项）
  List<String> get misheardList => misheard
      .split(RegExp(r'[/／,，、;；]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// 界面展示用：术语 | 常见误听形式
  String get display =>
      misheard.isEmpty ? term : '$term | $misheard';
}

/// 一节课的术语包（课前准备产物）
class TerminologyPack {
  final String courseName;
  final String topic;
  final String material;
  final List<Term> terms;

  /// 给 Whisper 类工具用的 initial_prompt（≤50 词 / 80 token）
  final String initialPrompt;

  /// 拾音风险提示（3–5 条）
  final List<String> riskHints;

  final DateTime createdAt;

  const TerminologyPack({
    this.courseName = '',
    this.topic = '',
    this.material = '',
    this.terms = const [],
    this.initialPrompt = '',
    this.riskHints = const [],
    required this.createdAt,
  });

  factory TerminologyPack.fromJson(Map<String, dynamic> json) {
    final rawTerms = (json['terms'] as List?) ?? [];
    final rawHints = (json['riskHints'] as List?) ?? [];
    return TerminologyPack(
      courseName: (json['courseName'] ?? '').toString(),
      topic: (json['topic'] ?? '').toString(),
      material: (json['material'] ?? '').toString(),
      terms: rawTerms
          .whereType<Map<String, dynamic>>()
          .map(Term.fromJson)
          .where((t) => t.term.isNotEmpty)
          .toList(),
      initialPrompt: (json['initialPrompt'] ?? '').toString(),
      riskHints: rawHints
          .map((e) => e.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'courseName': courseName,
        'topic': topic,
        'material': material,
        'terms': terms.map((t) => t.toJson()).toList(),
        'initialPrompt': initialPrompt,
        'riskHints': riskHints,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  String encode() => jsonEncode(toJson());

  static TerminologyPack? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map<String, dynamic>) return null;
      return TerminologyPack.fromJson(d);
    } catch (_) {
      return null;
    }
  }

  bool get isEmpty => terms.isEmpty;

  List<Term> byLevel(TermLevel level) =>
      terms.where((t) => t.level == level).toList();

  /// 高优先级术语（用于拼 initial_prompt）
  List<Term> get highTerms => byLevel(TermLevel.high);

  /// 术语表纯文本（喂给纠错提示词 / 用户复制）
  String get termsAsPromptText {
    final b = StringBuffer();
    for (final level in TermLevel.values) {
      final list = byLevel(level);
      if (list.isEmpty) continue;
      b.writeln('【${level.label}优先级】');
      for (final t in list) {
        b.writeln('- ${t.term}${t.misheard.isEmpty ? '' : '（常见误听：${t.misheard}）'}');
      }
    }
    return b.toString();
  }
}

/// 一处「高置信度修正」
class TermFix {
  final String before;
  final String after;

  /// 修正依据：音近 / 形近 / 缩写漂移 / 上下文唯一
  final String basis;

  const TermFix({
    required this.before,
    required this.after,
    this.basis = '',
  });
}

/// 一条「待确认」
class PendingItem {
  /// 原文片段
  final String snippet;

  /// 候选术语（可能空）
  final List<String> candidates;

  /// 出现次数（同一疑似错误在全文中反复出现）
  final int count;

  /// 时间戳（转写文本带时间戳时才有）
  final String? timestamp;

  const PendingItem({
    required this.snippet,
    this.candidates = const [],
    this.count = 1,
    this.timestamp,
  });
}

/// 术语命中情况
class TermHit {
  final String term;
  final bool corrected; // true = 经修改后才命中
  final int occurrences;

  const TermHit({
    required this.term,
    this.corrected = false,
    this.occurrences = 1,
  });
}

/// 一次质量校准的完整报告（对应规格的第三部分四段输出）
class CalibrationReport {
  /// ① 纠错后正文（含 〔改：原→正〕 / 〔疑似：…〕 / 〔此处可能缺失：…〕 标注）
  final String annotatedText;

  /// ② 命中：被正确识别或经修正后命中的术语
  final List<TermHit> hits;

  /// ② 完全未出现的术语（建议回听）
  final List<String> missedTerms;

  /// ③ 待确认清单
  final List<PendingItem> pending;

  /// ④ 拾音改进建议（1–3 条）
  final List<String> micAdvice;

  /// 转写可用性评估（质量过低时才有内容）
  final String? usability;

  const CalibrationReport({
    required this.annotatedText,
    this.hits = const [],
    this.missedTerms = const [],
    this.pending = const [],
    this.micAdvice = const [],
    this.usability,
  });

  int get fixCount => hits.where((h) => h.corrected).length;
  bool get hasText => annotatedText.trim().isNotEmpty;
  bool get isLowQuality => (usability ?? '').trim().isNotEmpty;
}