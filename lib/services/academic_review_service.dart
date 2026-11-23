// lib/services/academic_review_service.dart
// 学科专家质检：先路由到学科，再由该学科专家判断「知识对不对」。
//
// 分工：
//   route()  —— 便宜的小调用，只看前 800 字，决定交给谁；
//   review() —— 学科专家，查硬伤（违背科学事实）、逻辑漏洞、术语正名。
//
// 设计取舍：
//   · 不喂全文，只喂正文前 8000 字；超了截断并在结果里说明（成本可控）。
//   · 强制 JSON，解析失败直接报错，不猜、不降级成「看起来像」的结果。
//   · 只出结论，不改正文；正文改动由界面上的「替换」按钮触发。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/academic_review.dart';
import 'settings_service.dart';

/// 一条可引用的证据（来自术语表 / 知识库 / 以后的教材片段）
class ReviewEvidence {
  final String text;
  final String source;
  const ReviewEvidence(this.text, {this.source = '知识库'});
}

class AcademicReviewService {
  /// 测试注入：给定 (system, user) 返回模型原始输出
  final Future<String> Function(String system, String user)? ai;

  /// 直接注入 Key（命令行/测试无 SharedPreferences 时用）
  final String? apiKeyOverride;

  final SettingsService _settings = SettingsService();

  AcademicReviewService({this.ai, this.apiKeyOverride});

  /// 送进质检的正文字数上限（约 8000 字，成本约 0.01~0.02 元）
  static const int maxNoteChars = 8000;

  /// 路由只看前 800 字，别为一句话的学科判断付全文的钱
  static const int routePreviewChars = 800;

  // ───────────────── 学科规则库 ─────────────────
  // 新增学科：在这里加一项，同时给 SubjectCode 加枚举值。

  static const Map<SubjectCode, ({String name, String rules})> subjects = {
    SubjectCode.botany: (
      name: '植物学',
      rules: '''
1. 严禁混淆茎变态与叶变态（如把球茎错归为叶的变态）。
2. 区分茎卷须与叶卷须、托叶卷须（豌豆是叶卷须，菝葜是托叶卷须）。
3. 严禁把「同功不同源」当成同源结构（如茎刺与叶刺：同功不同源）。
4. 芋头是典型的地下球茎，具环状节和退化叶，不能归为块茎。
5. 天南星科（如红掌）的保护结构应准确称呼为「佛焰苞」。
6. 捕虫叶的生理机制：区分触发机制（刚毛触碰）与消化机制（消化腺分泌蛋白酶）。
7. 地下变态茎的适应意义：核心是「储藏营养 + 度过不良环境 + 营养繁殖」。''',
    ),
    SubjectCode.computerScience: (
      name: '计算机科学',
      rules: '''
1. 严查算法时间/空间复杂度是否算错（如把 O(n log n) 写成 O(n)）。
2. 核查数据结构定义是否严谨（树与图的区别、指针与引用、栈与队列）。
3. 检查代码/伪代码是否存在死循环、越界、空指针等明显逻辑漏洞。
4. 检查操作系统概念（进程与线程、死锁四个必要条件、页表与缓存）。''',
    ),
    SubjectCode.law: (
      name: '法学',
      rules: '''
1. 法条编号、名称与内容必须对应，不能张冠李戴。
2. 区分法律主体、客体与法律关系，注意权利能力与行为能力。
3. 构成要件不得遗漏或合并（如侵权责任的四个要件）。
4. 程序顺序不能颠倒（起诉—受理—审理—判决—上诉）。
5. 只做知识性核对，不提供具体案件的法律意见。''',
    ),
    SubjectCode.general: (
      name: '通用学术',
      rules: '''
1. 定义必须能站住：被定义项不能出现在定义里（循环定义）。
2. 分类要满足互斥且穷尽，不能同一层级混用不同分类标准。
3. 因果关系不能拿相关当因果；时间先后不等于因果。
4. 数据要有单位、口径与来源；百分比要说明基数。
5. 类比只能帮助理解，不能当作论证结论。''',
    ),
  };

  // ───────────────── 提示词 ─────────────────

  static const String routerPrompt = '''
你是课堂笔记应用 ClassNote 的「学科意图识别路由器」。
阅读用户给的笔记片段（标题 + 大纲或前 800 字），判断它最可能属于哪个学科，输出对应代码。

支持的学科代码：
- botany: 植物学、林学、农学、生物学相关
- computer_science: 计算机科学、编程、算法、软件工程相关
- law: 法学、法律条文、案例分析相关
- general: 通识类、无法明确归类，或涉及多学科交叉

只输出 JSON，不要寒暄、不要解释、不要代码块围栏：
{"subject_code": "botany", "confidence": 0.95, "reason": "简短说明"}''';

  /// 学科专家的通用模板。{{SUBJECT_NAME}} 与 {{DOMAIN_RULES}} 会被替换。
  static const String expertTemplate = '''
# Role
你是一位极其严谨的{{SUBJECT_NAME}}教授与学术质检官。你的核心使命是审阅学生提交的课堂笔记/思维导图文本，进行深度的「底层知识性自检」。

# Objective
拒绝停留在表面的「纠词」（如同音字），必须穿透文本，检查其背后的专业概念、分类逻辑、因果推导和机制是否符合科学事实。同时，基于你的专业领域规范，纠正笔记中的术语。

# Subject Domain Rules（专属领域排雷规则）
在执行任务时，请重点排查以下专属领域的硬伤：
{{DOMAIN_RULES}}

# 判定纪律
- 只依据笔记文本与学科常识判断；证据不足时不要硬判，给出「存疑」措辞并说明缺什么证据。
- 一条问题只报一次，不要把同一处拆成多条凑数。
- 只针对**该句本身**判断：上一句有错不代表这一句也错；原文正确的句子不要因为相邻内容错误而被列入。
- original_text 必须是笔记里**原样出现**的片段（不超过 60 字），便于前端定位；找不到原文就不要报。
- 没有发现就返回空数组，不要为了显得认真而编造问题。
- 不评价排版、不评价总结质量、不改写整段文字。

# Output Format（必须严格输出 JSON，不要用 markdown 代码块包裹）
{
  "agent_name": "{{SUBJECT_NAME}}质检官",
  "summary": "一句话总结本次质检结果（如：发现 2 处硬伤，3 处表述不严谨）",
  "hard_errors": [
    {
      "id": 1,
      "error_type": "分类归属错误/概念混淆/机制错误",
      "original_text": "原文中出错的句子或片段",
      "reason": "基于专业知识的详细解释（为什么错）",
      "suggestion": "修改建议或正确表述"
    }
  ],
  "logic_flaws": [
    {
      "id": 1,
      "original_text": "原文中表述不严谨的句子",
      "reason": "为什么容易丢分或产生误解",
      "suggestion": "如何严谨地表述"
    }
  ],
  "term_corrections": [
    {
      "wrong": "原笔记中的错误/口语化词汇",
      "correct": "标准专业术语",
      "reason": "正名原因"
    }
  ],
  "review_advice": "基于以上错误，给出 1-2 条高效的对比记忆建议或复习策略"
}''';

  /// 单句复核模板：只对这一句负责，宁可漏报不许误报。
  /// 这是对整段质检的「二审」——整段模型容易把上一句的错误前提带进下一句。
  static const String sentenceTemplate = '''
# Role
你是一位极其严谨、只认证据的{{SUBJECT_NAME}}审稿专家。你的任务是审阅单条课堂笔记，判断其是否存在知识性硬伤。

# Crucial Rules (核心纪律，必须严格遵守)
0. **先查后判**：如果【可参考的教材片段】里提供了【维基百科】检索结果，必须先看它再判断；你的 evidence 必须摘抄其中原句。搜索结果不足以证明笔记有错时，只能判 warning 或 correct，严禁直接判 fatal_error。
1. **上下文隔离**：你当前只需要且只能对【待审句子】负责。不管前一秒看了什么错误概念，绝不能把上一句的错误前提代入到当前句子中进行推断。
2. **证据驱动**：如果没有 100% 的把握，或者无法在你的知识库中检索到确切依据，**严禁凭空臆断**。宁可不报错，也绝不能误报。
3. **区分概念**：严格区分各类易混概念与形态学特征。

# Subject Domain Rules（领域排雷规则）
{{DOMAIN_RULES}}

# Input
- 【待审句子】：{{CURRENT_SENTENCE}}
- 【可参考的教材片段（可选）】：{{RAG_EVIDENCE}}

# Task
请执行以下两步推理，并最终输出严格的 JSON 格式：
1. 提取【待审句子】中的核心专业概念。
2. 结合教材片段或绝对确信的专业知识，判断该句子是否成立。

# Output Format (严格输出 JSON，禁止使用 markdown 代码块包裹)
{
  "original_sentence": "回显待审句子",
  "has_error": false,
  "error_level": null,
  "error_category": null,
  "evidence": "该句的确切定义，或引用教材原话。如果 has_error 为 false，这里写「经核实无误」。",
  "correction": "如果 has_error 为 true，给出修改后的正确表述；如果为 false，留空。",
  "review_advice": "针对该考点的简短避坑记忆法（仅当 has_error 为 true 时生成）"
}

{{EXAMPLES}}
''';

  /// 植物学的两个锚点示例（其它学科不硬塞，避免示例本身带偏）
  static const String botanyExamples = '''
# Examples
【输入】待审句子：球茎（如荸荠）有明显的节和节间。
【输出】
{"original_sentence":"球茎（如荸荠）有明显的节和节间。","has_error":false,"error_level":null,"error_category":null,"evidence":"经核实无误，地下变态茎（球茎、根状茎）的本质特征就是具有节和节间。","correction":"","review_advice":""}

【输入】待审句子：芋头是典型的块茎，属于叶的变态。
【输出】
{"original_sentence":"芋头是典型的块茎，属于叶的变态。","has_error":true,"error_level":"fatal_error","error_category":"分类归属错误","evidence":"植物学中，芋头属于地下变态茎中的球茎，具环状节和退化叶；所有地下变态茎均属于茎的变态，不属于叶的变态。","correction":"芋头是典型的球茎，属于茎的变态。","review_advice":"带「茎」字的（根状茎、块茎、鳞茎、球茎）都是茎变态；叶变态重点是卷须、刺、捕虫叶。"}
''';

  // ───────────────── 对外 API ─────────────────

  /// 路由：判断这段笔记该交给哪个专家。解析失败/未知学科一律按 general。
  Future<SubjectRoute> route(String noteText) async {
    final preview = noteText.trim();
    if (preview.isEmpty) {
      return const SubjectRoute(
          subject: SubjectCode.general, reason: '笔记为空，走通用质检');
    }
    final text = preview.length > routePreviewChars
        ? preview.substring(0, routePreviewChars)
        : preview;
    try {
      final raw = await _chat(routerPrompt, '笔记内容：\n$text', maxTokens: 200);
      final json = _jsonObject(raw);
      final code = SubjectCodeX.fromCode(json['subject_code']?.toString());
      final confidence =
          ((json['confidence'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
      // 路由置信度过低时别硬塞给某个专家，交给通用质检更稳
      if (confidence < 0.35 && code != SubjectCode.general) {
        return SubjectRoute(
          subject: SubjectCode.general,
          confidence: confidence,
          reason: '${json['reason'] ?? ''}（置信度过低，转通用质检）',
        );
      }
      return SubjectRoute(
        subject: code,
        confidence: confidence,
        reason: (json['reason'] ?? '').toString(),
      );
    } catch (_) {
      // 路由失败不该让整个质检失败：直接用通用规则
      return const SubjectRoute(
          subject: SubjectCode.general, reason: '路由失败，按通用规则质检');
    }
  }

  static Set<String> _bigrams(String s) {
    final clean = s.replaceAll(RegExp(r'\s+'), '');
    final out = <String>{};
    for (var i = 0; i + 1 < clean.length; i++) {
      out.add(clean.substring(i, i + 2));
    }
    return out;
  }

  /// 为一句挑证据：按二字组重叠排序，取前 3 条。
  static List<ReviewEvidence> pickEvidence(
    String sentence,
    List<ReviewEvidence> pool, {
    int max = 3,
  }) {
    if (pool.isEmpty) return const [];
    final target = _bigrams(sentence);
    final scored = <({ReviewEvidence e, int score})>[];
    for (final e in pool) {
      final overlap = _bigrams(e.text).intersection(target).length;
      // 一个二字组就够：证据池很小，宁多带一条也别一句都带不上
      if (overlap >= 1) scored.add((e: e, score: overlap));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(max).map((x) => x.e).toList();
  }

  /// 复核给出的依据是否真的引用了我们提供的材料。
  /// 没引用就不许算「有据硬伤」，降为 warning。
  static bool groundedIn(String evidence, List<ReviewEvidence> provided) {
    if (provided.isEmpty) return false;
    final e = _bigrams(evidence);
    for (final p in provided) {
      if (_bigrams(p.text).intersection(e).length >= 3) return true;
    }
    return false;
  }

  /// 把笔记切成句子：按中文句末标点与换行切，跳过标题行与过短片段。
  /// 标题（「一、地下变态茎」「二、地上变态茎」）不是知识点，送进去只会浪费调用。
  static List<String> splitSentences(String text) {
    final out = <String>[];
    final normalized = text.replaceAll('\r', '');
    for (final block in normalized.split(RegExp(r'[\n]+'))) {
      final line = block.trim();
      if (line.isEmpty) continue;
      // 标题行：序号开头，或冒号结尾且没有句号
      if (RegExp(r'^[一二三四五六七八九十]+[、.．]').hasMatch(line)) continue;
      if (line.endsWith('：') || line.endsWith(':')) continue;
      final pieces = line.split(RegExp(r'(?<=[。！？!?；;])'));
      for (final raw in pieces) {
        final s = raw.trim();
        if (s.length < 8) continue;
        out.add(s);
      }
    }
    return out;
  }

  /// 逐句全审：每一句都单独判，不看上下文。
  ///
  /// 与 reviewWithVerification 的区别：
  ///   · 那个是「整段找候选 + 复核少数几条」，便宜但有漏报可能；
  ///   · 这个是「每句都判」，慢、贵，但漏报最少。
  /// 两句以上并发 4 路，60 句约 20 秒。
  Future<AcademicReview> reviewAllSentences(
    String noteText, {
    SubjectCode? subject,
    String course = '',
    int maxSentences = 60,
    List<ReviewEvidence> evidence = const [],
    Future<List<ReviewEvidence>> Function(String sentence)? retriever,
    void Function(int done, int total)? onProgress,
  }) async {
    final text = noteText.trim();
    if (text.isEmpty) throw Exception('笔记正文为空，无法质检');

    final chosen = subject ?? (await route(text)).subject;
    final all = splitSentences(text);
    if (all.isEmpty) throw Exception('没有可审阅的完整句子');
    final limited = all.take(maxSentences).toList();
    final skipped = all.length - limited.length;

    final verdicts = List<SentenceVerdict?>.filled(limited.length, null);
    final pickedPer =
        List<List<ReviewEvidence>>.generate(limited.length, (_) => const []);
    var cursor = 0;
    var done = 0;
    var failed = 0;

    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= limited.length) return;
        // 先问向量检索（笔记/知识库句子），再补术语表这类短证据，去重后取前 3
        final merged = <ReviewEvidence>[];
        final seen = <String>{};
        void take(ReviewEvidence e) {
          if (merged.length >= 3) return;
          final key = e.text.trim();
          if (key.isEmpty || !seen.add(key)) return;
          merged.add(e);
        }

        if (retriever != null) {
          final remote = await retriever(limited[i]);
          remote.forEach(take);
        }
        pickEvidence(limited[i], evidence).forEach(take);
        final picked = merged;
        pickedPer[i] = picked;
        final rag = picked
            .map((p) => '【${p.source}】${p.text}')
            .join('\n');
        try {
          verdicts[i] =
              await verifySentence(limited[i], subject: chosen, ragEvidence: rag);
        } catch (_) {
          failed++;
        }
        done++;
        onProgress?.call(done, limited.length);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));

    final hard = <AcademicHardError>[];
    final flaws = <AcademicLogicFlaw>[];
    var hi = 1;
    var fi = 1;
    var downgraded = 0;
    for (var i = 0; i < verdicts.length; i++) {
      final v = verdicts[i];
      if (v == null || !v.hasError) continue;
      var evidence = v.evidence.trim();
      final correction = v.correction.trim();
      final category = (v.errorCategory ?? '').trim().isEmpty
          ? '知识性问题'
          : v.errorCategory!.trim();

      final picked = pickedPer[i];
      var level = v.errorLevel ?? 'fatal_error';
      // 接地校验：说「有错」却一个字都没引用我们给的材料 → 降为存疑
      if (level == 'fatal_error' &&
          picked.isNotEmpty &&
          !groundedIn(evidence, picked)) {
        level = 'warning';
        downgraded++;
        evidence =
            '$evidence（未引用提供的知识库依据，按存疑处理）';
      }
      if (level == 'fatal_error') {
        hard.add(AcademicHardError(
          id: hi++,
          errorType: category,
          originalText: v.originalSentence,
          reason: evidence,
          suggestion: correction,
          evidence: evidence,
          verified: true,
        ));
      } else {
        flaws.add(AcademicLogicFlaw(
          id: fi++,
          originalText: v.originalSentence,
          reason: evidence,
          suggestion: correction,
        ));
      }
    }

    final covered = limited.length - failed;
    final summary = StringBuffer()
      ..write('逐句审阅 $covered 句：${hard.length} 处硬伤、${flaws.length} 处表述不严谨');
    if (failed > 0) summary.write('；$failed 句复核失败未计入');
    if (skipped > 0) summary.write('；超出上限，另有 $skipped 句未审');
    if (downgraded > 0) summary.write('；$downgraded 处因未引用知识库依据降为存疑');
    final providedTexts = pickedPer
        .expand((e) => e)
        .map((e) => e.text.trim())
        .where((t) => t.isNotEmpty)
        .toSet();
    if (providedTexts.isEmpty) {
      summary.write('；本次无知识库依据，结论仅凭模型知识');
    } else if (downgraded == 0) {
      summary.write('；已提供 ${providedTexts.length} 条依据（术语表/知识库/笔记）');
    }

    final spec = subjects[chosen]!;
    return AcademicReview(
      agentName: '${spec.name}质检官',
      subject: chosen,
      summary: summary.toString(),
      hardErrors: hard,
      logicFlaws: flaws,
      termCorrections: const [],
      reviewAdvice: hard.isEmpty && flaws.isEmpty
          ? '本段未发现知识性硬伤，建议按教材目录再过一遍概念定义。'
          : '',
      createdAt: DateTime.now(),
    );
  }

  /// 单句复核：只判这一句，按证据说话。
  ///
  /// [ragEvidence] 是教材原文片段（暂未接入 RAG 时留空），
  /// 留空时模型只能依赖自身知识，此时它被要求「没把握就不报」。
  Future<SentenceVerdict> verifySentence(
    String sentence, {
    SubjectCode subject = SubjectCode.general,
    String ragEvidence = '',
  }) async {
    final s = sentence.trim();
    if (s.isEmpty) {
      return const SentenceVerdict(originalSentence: '', hasError: false);
    }
    final spec = subjects[subject]!;
    final prompt = sentenceTemplate
        .replaceAll('{{SUBJECT_NAME}}', spec.name)
        .replaceAll('{{DOMAIN_RULES}}', spec.rules)
        .replaceAll('{{CURRENT_SENTENCE}}', s)
        .replaceAll('{{RAG_EVIDENCE}}', ragEvidence.trim())
        .replaceAll('{{EXAMPLES}}',
            subject == SubjectCode.botany ? botanyExamples : '');

    final raw = await _chat(prompt, '请审阅并输出 JSON。', maxTokens: 800);
    final json = _jsonObject(raw);
    final v = SentenceVerdict.fromJson(json);
    return SentenceVerdict(
      originalSentence:
          v.originalSentence.trim().isEmpty ? s : v.originalSentence,
      hasError: v.hasError,
      errorLevel: v.errorLevel?.isEmpty == true ? null : v.errorLevel,
      errorCategory: v.errorCategory?.isEmpty == true ? null : v.errorCategory,
      evidence: v.evidence,
      correction: v.correction,
      reviewAdvice: v.reviewAdvice,
    );
  }

  /// 整段质检 + 逐条单句复核。
  ///
  /// 为什么要有二审：整段模型会把上一句的错误前提带进下一句，
  /// 实测「球茎（如荸荠）有明显的节和节间」被两次误判。
  /// 这里对每条硬伤单独复核，只留下复核确认的；复核失败的保留但标记未核实。
  Future<AcademicReview> reviewWithVerification(
    String noteText, {
    SubjectCode? subject,
    String course = '',
  }) async {
    final base = await review(noteText, subject: subject, course: course);
    final kept = <AcademicHardError>[];
    var nextId = 1;

    for (final e in base.hardErrors) {
      var confirmed = true;
      var evidence = '';
      var correction = e.suggestion;
      try {
        final v = await verifySentence(
          e.originalText,
          subject: base.subject,
        );
        confirmed = v.hasError;
        evidence = v.evidence;
        if (v.correction.trim().isNotEmpty) correction = v.correction;
      } catch (_) {
        // 复核本身失败：不放大也不缩小，保留原判定但标记未核实
        confirmed = true;
      }
      if (!confirmed) continue;
      kept.add(AcademicHardError(
        id: nextId++,
        errorType: e.errorType,
        originalText: e.originalText,
        reason: e.reason,
        suggestion: correction,
        evidence: evidence,
        verified: evidence.trim().isNotEmpty,
      ));
    }

    // 复核会砍掉误报，summary 必须跟着改，否则会出现「说 5 处、只列 4 条」
    final summary = kept.length == base.hardErrors.length
        ? base.summary
        : '复核后保留 ${kept.length} 处硬伤、'
            '${base.logicFlaws.length} 处表述不严谨、'
            '${base.termCorrections.length} 处术语需正名'
            '（初审 ${base.hardErrors.length} 处，已剔除单句复核不成立的误报）';

    return AcademicReview(
      agentName: base.agentName,
      subject: base.subject,
      summary: summary,
      hardErrors: kept,
      logicFlaws: base.logicFlaws,
      termCorrections: base.termCorrections,
      reviewAdvice: base.reviewAdvice,
      createdAt: base.createdAt,
    );
  }

  /// 学科质检。subject 为空时先路由。
  Future<AcademicReview> review(
    String noteText, {
    SubjectCode? subject,
    String course = '',
  }) async {
    final text = noteText.trim();
    if (text.isEmpty) throw Exception('笔记正文为空，无法质检');

    final chosen = subject ?? (await route(text)).subject;
    final spec = subjects[chosen]!;
    final system = expertTemplate
        .replaceAll('{{SUBJECT_NAME}}', spec.name)
        .replaceAll('{{DOMAIN_RULES}}', spec.rules);

    final clipped = text.length > maxNoteChars
        ? '${text.substring(0, maxNoteChars)}\n（正文过长，已截断，只质检前 $maxNoteChars 字）'
        : text;

    final user = StringBuffer();
    if (course.trim().isNotEmpty) user.writeln('课程：${course.trim()}');
    user.writeln('笔记正文：');
    user.write(clipped);

    final raw = await _chat(system, user.toString(), maxTokens: 3000);
    final json = _jsonObject(raw);

    final review = AcademicReview.fromJson({
      ...json,
      'subject': chosen.code,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    // 兜底清洗：空片段/正名前后一致的条目没有意义
    final hard = review.hardErrors
        .where((e) => e.originalText.trim().isNotEmpty)
        .toList();
    final flaws = review.logicFlaws
        .where((e) => e.originalText.trim().isNotEmpty)
        .toList();
    final terms = review.termCorrections
        .where((e) =>
            e.wrong.trim().isNotEmpty &&
            e.correct.trim().isNotEmpty &&
            e.wrong.trim() != e.correct.trim())
        .toList();

    return AcademicReview(
      agentName: review.agentName.isEmpty
          ? '${spec.name}质检官'
          : review.agentName,
      subject: chosen,
      summary: review.summary,
      hardErrors: hard,
      logicFlaws: flaws,
      termCorrections: terms,
      reviewAdvice: review.reviewAdvice,
      createdAt: review.createdAt,
    );
  }

  // ───────────────── 内部 ─────────────────

  /// 从模型输出里抠出 JSON 对象：容忍代码块围栏、前后废话。
  static Map<String, dynamic> _jsonObject(String raw) {
    var text = raw.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw Exception('质检结果不是 JSON');
    }
    final decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is! Map<String, dynamic>) {
      throw Exception('质检结果不是 JSON 对象');
    }
    return decoded;
  }

  Future<String> _chat(String system, String user,
      {required int maxTokens}) async {
    final injected = ai;
    if (injected != null) return injected(system, user);

    final key = (apiKeyOverride ?? await _settings.getApiKey()).trim();
    if (key.isEmpty) {
      throw Exception('请先在设置里填写 DeepSeek API Key');
    }

    late final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(AppConfig.deepSeekBaseUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': AppConfig.deepSeekModel,
              'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
              ],
              'temperature': 0.2,
              'max_tokens': maxTokens,
            }),
          )
          .timeout(const Duration(seconds: 120));
    } catch (_) {
      throw Exception('网络请求失败，质检未完成');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('DeepSeek API Key 无效，请到设置里检查');
    }
    if (response.statusCode == 402) {
      throw Exception('DeepSeek 账户余额不足');
    }
    if (response.statusCode != 200) {
      throw Exception('质检失败（状态码 ${response.statusCode}）');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['choices'][0]['message']['content'] as String;
    } catch (_) {
      throw Exception('质检返回格式异常');
    }
  }
}