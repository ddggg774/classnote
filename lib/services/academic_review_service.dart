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