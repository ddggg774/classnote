// lib/services/ai_service.dart
// AI 总结服务：把课堂原文整理成「详细可复习笔记」+「思维导图结构」。
// 这是"网络层"：唯一会联网的地方，失败时抛 AiException 由页面展示。
//
// 【为什么重写过一次】
// 旧版提示词自己把输出掐死了：nodes 3~6 个要点、children 2~4 条且每条不超过 15 字。
// 用户反馈"太简略"，根因就在这里——不是模型能力不够，是要求就是这么写的。
// 现在的目标是「详细版长度约为转写原文的 20%–40%，以完整可复习为先」，
// 并且有硬约束：不编造、缺失处必须标注「转写缺失 / 待确认」。
//
// 【长文本处理】
// 两小时的课堂转写有 2–4 万字，一次性塞进 deepseek-chat 会超上下文（400）。
// 所以按字数分块，每块整理成「中间笔记」，再合并成一份最终九段式 Markdown。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/mind_graph.dart';
import '../models/note.dart';
import '../models/note_template.dart';
import '../models/summary_level.dart';
import 'template_service.dart';
import '../models/study_note.dart';
import 'settings_service.dart';

/// AI 调用失败：区分「用户该去改设置」和「重试就行」，页面据此给不同引导。
class AiException implements Exception {
  final String message;
  final bool needSettings; // true = Key 缺失/无效，应引导去设置页
  final bool retryable;

  AiException(this.message, {this.needSettings = false, this.retryable = true});

  @override
  String toString() => message;
}

class AiService {
  final SettingsService _settings = SettingsService();

  /// 直接注入的 API Key。传了就优先用它，跳过 SharedPreferences。
  /// 用途：命令行/测试环境没有 App 的 SharedPreferences，但需要跑真实调用。
  final String? apiKeyOverride;

  AiService({this.apiKeyOverride});

  /// 单次请求能安全送进去的字数。deepseek-chat 上下文 64K token，
  /// 中文约 1 字 ≈ 1 token，留出 system 提示与输出空间后取 8000 字比较稳。
  static const int chunkChars = 8000;

  /// 拆块时的重叠字数：避免要点恰好被切断在半句上
  static const int overlapChars = 200;

  /// 详细笔记的输出上限。20%~40% 的篇幅比原来的几百字长得多，
  /// max_tokens 给足（12000），否则长课堂会被硬截断成半截文档。
  static const int _maxTokens = 12000;

  // ───────────────────────── 提示词 ─────────────────────────

  /// 九段式详细笔记的主提示词。
  /// 关键设计：
  /// 1) 先定死章节顺序与标题，保证每次输出都是同一套结构，方便复习和二次编辑；
  /// 2) 明确列出「不许编造 / 缺失必须标注」，这是验收标准里最硬的一条；
  /// 3) 明确要求说明逻辑关系、而不是堆关键词；
  /// 4) 末尾要求附一段 JSON 供思维导图用，一次调用产出两份东西。
  /// 提示词通用开头。所有模板共用，不含任何随模板变化的内容。
  static const String _promptHeader = '''
你是一名严谨的大学课堂笔记整理专家。你的任务是把课堂录音转写稿，整理成一份**详细、可直接用来复习**的结构化笔记。

''';

  /// 防编造铁律。**任何模板都不得覆盖这一段**——这是产出可信的底线。
  static const String _promptIronRules = '''
## 最高优先级铁律（违反即不合格）
1. **绝对不能编造**。原文没说的定义、公式、数字、人名、结论，一律不许补。
2. 转写听不清、句子断裂、公式或数字可疑、人名/术语拿不准的地方，**必须**标注 `〔待确认〕` 或 `〔转写缺失〕` 并写清哪里可疑。
3. 公式、术语、代码、英文缩写**保留原样**，不要翻译、不要改写大小写。
4. 如果某一节原文里确实没有对应内容，写「本节未提及」，**不要**为了凑结构而虚构。
5. 输出只允许是 Markdown 正文，不要加任何解释性开场白。

''';

  /// 通用整理要求（去口语、书面语重述、标来源、保留时间戳）。所有模板共用。
  static const String _promptWritingRules = '''
## 整理要求
- 去掉口语重复、语气词（"啊/呢/那个/就是说"）和明显的转写错误；用书面语重述，但**不改变原意**。
- 不要只列关键词。每个知识点要说明**逻辑关系**：是什么 → 为什么 → 怎么用 → 适用条件。
- 能判断信息来源时，用小标签区分：`〔讲授〕`、`〔板书/PPT〕`、`〔师生问答〕`、`〔作业布置〕`。
- 详细程度：**约为原文长度的 20%~40%**，以"完整可复习"为先，宁详勿略。
- 原文里出现的时间点（如果转写稿带时间戳）请尽量保留；没有时间戳就引用原文片段代替，用「」括起来。

''';

  /// 九段式的章节正文。抽出来是为了让详情档的「加引用要求」能插在它前面，
  /// 也方便对照模板系统的等价实现。
  static const String _detailSections = '''
# 课程信息
- 课程名 / 本节主题 / 学习目标 / 与前后知识的关联

# 知识点结构
按层级组织（## 一级知识点、### 二级），每个知识点包含：
- 概念定义
- 公式/定理（如有，保留原式）
- 推导步骤（如有）
- 适用条件
- 老师强调点
- 逻辑关系说明（前后知识点怎么连起来的）

# 例题与解题步骤
每道例题用以下字段，**步骤缺失必须标注**：
- 题干：
- 解题思路：
- 关键步骤：（逐条，缺步骤时写 `〔转写缺失〕`）
- 答案：（不确定写 `〔待确认〕`）
- 易错点：

# 老师强调与考试作业提示
- 重点 / 难点 / 易错点
- 考试范围
- 作业要求 / 提交方式 / 截止时间（没提到就写"未提及"）

# 课堂互动问答
逐条列：学生问 → 老师答 → 结论

# 术语/公式/英文缩写表
用 Markdown 表格：| 术语 | 原文中的位置或片段 | 简要解释 |

# 学习任务表
用 Markdown 表格：| 任务 | 类型(作业/预习/复习) | 截止时间 | 提交方式 |
没有的内容一律写"未提及"。

# 疑问与待确认清单
逐条列出所有不确定的地方，格式：- 位置/原文片段：不确定的原因 → `待确认`

# 时间戳回溯
关键知识点、例题、作业考试提示的时间点或原文片段索引。

''';

  /// 思维导图 JSON 的输出规范。与章节解耦：模板只决定正文结构，
  /// 导图默认仍用 11 个固定一级分支（MindGraph.requiredBranches）。
  static const String _promptMindmapSpec = '''
## 额外要求
在 Markdown 正文的**最末尾**，附一个 JSON 代码块，内容是一棵**详细思维导图**（同样不许编造）。
这份导图会被渲染成树形浏览 + 导出到 XMind，所以结构必须规范：

```json
{"root":"课程主题","branches":[
 {"id":"b0","title":"课程信息","mark":"none","children":[
   {"id":"b0-1","title":"具体节点名","relation":"包含","details":["说明1","说明2"],"source":"12:30「原文片段」","mark":"key","children":[]}
 ]}
]}
```

导图硬性要求：
1. **一级分支固定这 11 个，顺序不变**：课程信息、学习目标、知识点结构、公式/定理、
   例题与解题步骤、易错点、老师强调、考试/作业提示、课堂问答、术语表、待确认清单。
   某个分支原文里没有内容，就把该分支写成 `{"title":"该分支名","children":[{"id":"x","title":"未提及"}]}`，
   **不要省略这个分支**。
2. **层级 3~5 级**：一级分支 → 二级（知识点/例题/公式名）→ 三级（概念/适用条件/步骤）→ 四~五级（细节）。
   节点标题必须具体（写"洛必达法则的适用条件"而不是"重点"；写"例3：求 lim(x→0) sin x/x"而不是"例题1"）。
3. **节点内容按类型展开**（放在 details 数组里，每条一句、简短）：
   - 概念节点：定义 + 成立条件
   - 公式节点：公式原文 + 各变量含义 + 适用条件
   - 例题节点：题干摘要 + 思路 + 关键步骤 + 答案 + 易错点（步骤缺失写"〔转写缺失〕"）
   - 作业节点：要求 + 截止时间 + 提交方式（没有就写"未提及"）
4. **relation 字段**标注与父节点的关系，从这些里选：前提、推导、因果、对比、包含、易错、考试相关。
   说不清就省略该字段，不要乱填。
5. **source 字段**：关键知识点、公式、例题、考试作业提示节点，尽量给时间戳或「原文片段」。
   转写听不清的，写"待确认"并把 mark 设为 "unconfirmed"。
6. **mark 字段**（视觉编码）只能是这几个值之一：`key`(★重点) `hard`(▲难点)
   `pitfall`(⚠易错) `exam`(◆考点) `unconfirmed`(❓待确认) `quote`(「」老师原话) `none`。
7. details 是 **字符串数组**，不是对象；children 是 **节点数组**，没有子节点就给 `[]` 或省略。
''';

  /// 九段式完整提示词。由上面的分段拼成，行为与拆分前完全一致：
  /// 铁律与整理要求一字未改，只是从一段大字符串拆成了可复用的常量。
  static const String _detailSystemPrompt = '''
$_promptHeader
$_promptIronRules
$_promptWritingRules
## 输出结构（严格按此顺序与标题）
$_detailSections
$_promptMindmapSpec
''';

  /// 超长课堂的「分块整理」提示词：只整理结构，不做最终排版
  static const String _chunkSystemPrompt = '''
你是一名严谨的大学课堂笔记整理专家。现在只给你一节课转写稿的**其中一段**，
请把这一段整理成结构化的中间笔记，供后续合并使用。

铁律：
1. 绝对不许编造原文没有的内容。
2. 转写不清、公式/数字/人名/术语可疑的地方，标注 `〔待确认〕`，并写出可疑的原文片段。
3. 公式、术语、代码、英文缩写保留原样。
4. 注意记录这段里出现的：概念定义、公式定理、推导步骤、适用条件、老师强调点、
   例题（题干/思路/步骤/答案/易错点）、考试与作业要求（含截止时间与提交方式）、
   师生问答、以及所有可疑点。
5. 输出 Markdown，不要开场白。信息不足的类别直接省略，不要写空标题。
''';

  // ───────────────────── 按档位构造提示词 ─────────────────────

  /// 教材信息片段：匹配到教材就带上，否则空串。
  /// 带教材名的意义：模型知道"方炎明《植物学》第三版"这一章的通常术语体系，
  /// 纠错时更可能认对"木兰科/离生心皮"这类词，而不是瞎猜。
  static String _textbookBlock(String courseName) {
    final line = AppConfig.textbookLine(courseName);
    if (line.isEmpty) return '';
    return '\n## 教材\n$line\n（术语与章节体系以该教材为准；不确定的内容仍要标待确认，不许凭空补）\n';
  }

  /// 英语课总结的语言约束。中文课不拼这段，保证提示词逐字不变。
  static const String _englishSummaryBlock = '''
## 语言要求（英语课）
- 输入是英语课堂转写，可能夹着老师用中文做的解释
- 总结正文一律用简体中文，不要整篇写成英文
- 专业术语第一次出现写成「中文（English）」，例如：细胞壁（cell wall）
- 老师用中文说的话原样保留，写成「老师说：…」
- 引用原文时保留英文原句，不要翻译后再引用
''';

  static String _withLanguage(String prompt, String language) =>
      language == 'en' ? '$prompt\n$_englishSummaryBlock' : prompt;

  /// 按档位组装主提示词。
  /// 三档的差异只在「保留哪些章节」+「是否要原文引证」，不按字数裁剪——
  /// 按字数会逼模型注水或删干货。
  static String buildPromptForLevel(
    SummaryLevel level, {
    String courseName = '',
    String language = 'zh',
  }) {
    final base = _buildPromptForLevelBase(level, courseName: courseName);
    return _withLanguage(base, language);
  }

  static String _buildPromptForLevelBase(
    SummaryLevel level, {
    String courseName = '',
  }) {
    final textbook = _textbookBlock(courseName);

    switch (level) {
      case SummaryLevel.brief:
        return '''
你是一名课堂笔记整理助手。请把课堂转写稿整理成一份**速览版**笔记，目标是考前一分钟能扫完。
$textbook
## 只输出这三节，不要写别的
# 课程信息
- 课程名 / 本节主题

# 知识点结构
按层级列出核心知识点（只写知识点名称与一句话定义，不展开推导、不写例题）

# 老师强调与考试作业提示
- 重点 / 易错点 / 考试范围 / 作业要求与截止时间（没提到写"未提及"）

## 规则
- 绝对不编造。缺失内容写"未提及"。
- 这一档只求"能快速扫一遍回忆起讲了什么"，不要展开细节。
- 篇幅控制在原文的 5%~10%。

最后附一个 JSON 代码块供思维导图使用（没有内容的分支也要保留，内部写"未提及"）：
```json
{"root":"课程主题","branches":[{"id":"b0","title":"知识点结构","children":[{"id":"b0-1","title":"具体节点名","details":["一句话说明"],"children":[]}]}]}
```
''';

      case SummaryLevel.detail:
        // 先做档位替换，再把教材拼上去——顺序反了教材会丢
        final detailPrompt = _detailSystemPrompt.replaceFirst(
          '## 整理要求',
          '''## 本档特别要求（详细版）
在下面所有章节里，**每个知识点、每道例题、每条考试作业提示**都要附上：
- 原文引用：用「」引出老师原话片段
- 时间戳：如果转写稿带时间戳就标（如 12:30），没有就省略时间戳只留引用

引用必须逐字来自原文，不许改写、不许编造。
引用和正文用换行分开，格式示例：
  - 定义：……（正文）
    > 「老师原话……」（03:20）

## 整理要求''',
        );
        return textbook.isEmpty
            ? detailPrompt
            : '$detailPrompt\n$textbook';

      case SummaryLevel.normal:
        return textbook.isEmpty
            ? _detailSystemPrompt
            : '$_detailSystemPrompt\n$textbook';
    }
  }

  /// 按「模板 + 档位」组装主提示词。
  ///
  /// 【分派策略：内置模板走原路径，新模板走通用拼装】
  /// 九段式与速览是现在线上跑通的形态，让它们继续走 buildPromptForLevel，
  /// 产出与改造前逐字一致——零回归风险。
  /// 其余模板（实验报告 / 制图 / 用户自定义）走 _buildFromTemplate，
  /// 用同一套铁律与整理要求，只替换章节部分。
  ///
  /// 这样做的代价是有两条路径，但换来的是「改模板不会碰坏已验证的产出质量」，
  /// 对一个已经能用的 App 来说这笔交易划算。
  static String buildPrompt(
    NoteTemplate template,
    SummaryLevel level, {
    String courseName = '',
    String language = 'zh',
  }) {
    final base = _buildPromptBase(template, level, courseName: courseName);
    return _withLanguage(base, language);
  }

  static String _buildPromptBase(
    NoteTemplate template,
    SummaryLevel level, {
    String courseName = '',
  }) {
    switch (template.id) {
      case BuiltinTemplate.general:
        return _buildPromptForLevelBase(level, courseName: courseName);
      case BuiltinTemplate.brief:
        // 速览模板本身就是「brief 档那三节」，档位再叠加没有意义
        return _buildPromptForLevelBase(SummaryLevel.brief,
            courseName: courseName);
      default:
        return _buildFromTemplate(template, level, courseName: courseName);
    }
  }

  /// 用模板的章节拼出提示词。
  /// 铁律与整理要求原样复用，只换「输出结构」那一段。
  static String _buildFromTemplate(
    NoteTemplate template,
    SummaryLevel level, {
    String courseName = '',
  }) {
    final textbook = _textbookBlock(courseName);
    final b = StringBuffer()
      ..writeln(_promptHeader.trimRight())
      ..writeln()
      ..writeln(_promptIronRules.trimRight())
      ..writeln()
      // 详细档的加分要求插在整理要求之前，与现有 detail 档保持同一位置
      ..writeln(_levelExtraRules(level))
      ..writeln(_promptWritingRules.trimRight())
      ..writeln()
      ..writeln('## 输出结构（严格按此顺序与标题）')
      ..writeln();

    for (final section in template.sections) {
      b.writeln(section.render());
      b.writeln();
    }

    b.writeln(_mindmapSpecFor(template));
    final body = b.toString().trimRight();
    return textbook.isEmpty ? body : '$body\n$textbook';
  }

  /// 档位叠加的额外要求（空串表示不加）
  static String _levelExtraRules(SummaryLevel level) {
    if (level != SummaryLevel.detail) return '';
    return '''## 本档特别要求（详细版）
在下面所有章节里，**每个知识点、每道例题、每条考试作业提示**都要附上：
- 原文引用：用「」引出老师原话片段
- 时间戳：如果转写稿带时间戳就标（如 12:30），没有就省略时间戳只留引用

引用必须逐字来自原文，不许改写、不许编造。
引用和正文用换行分开，格式示例：
  - 定义：……（正文）
    > 「老师原话……」（03:20）
''';
  }

  /// 导图规范。模板声明了 mindmapBranches 就用它，否则沿用 11 个固定分支。
  ///
  /// 为什么默认沿用固定 11 个：MindGraph.requiredBranches、
  /// 导出器与既有测试全都依赖这 11 个分支名，
  /// 让模板静默换掉它们会把渲染和导出一起弄坏。
  static String _mindmapSpecFor(NoteTemplate template) {
    if (!template.overridesMindmap) return _promptMindmapSpec.trimRight();
    final branches = template.mindmapBranches
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (branches.isEmpty) return _promptMindmapSpec.trimRight();
    return _promptMindmapSpec
        .trimRight()
        .replaceFirst(
          RegExp(r'一级分支固定这 \d+ 个，顺序不变\*\*：[^。]*。',
              multiLine: true),
          '一级分支固定这 ${branches.length} 个，顺序不变**：'
          '${branches.join('、')}。',
        );
  }

  /// 分块整理用的提示词（长课堂才有），带上教材信息
  static String buildChunkPrompt({
    String courseName = '',
    String language = 'zh',
  }) {
    final textbook = _textbookBlock(courseName);
    final base = textbook.isEmpty ? _chunkSystemPrompt : '$textbook\n$_chunkSystemPrompt';
    return _withLanguage(base, language);
  }

  /// 合并用的提示词（长课堂才有），带上教材信息
  static String buildMergePrompt(
    SummaryLevel level, {
    NoteTemplate? template,
    String courseName = '',
    String language = 'zh',
  }) {
    // 合并阶段必须沿用用户选的模板与档位：原来写死九段式，
    // 长课堂选「速览/实验报告」也会被合并成九段式。
    final spec = buildPrompt(
      template ?? TemplateService.defaultTemplate,
      level,
      courseName: courseName,
      language: language,
    );
    return '你会收到同一节课若干片段的中间笔记（按讲课顺序）。'
        '请把它们合并成一份完整笔记，严格遵守下面的结构、规则与篇幅要求；'
        '不得编造片段里没有的内容；片段里标了〔待确认〕的内容必须保留标注。\n\n'
        '$spec';
  }

  /// 通用补全：给一段 system + user，要回一段文本。
  ///
  /// 存在的意义：考点提取、出题这类新技能需要调模型，但不该各自
  /// 重写一遍 HTTP 与错误处理。它们复用这一个入口。
  /// 不返回结构化数据——这些技能的产出本来就是给人读的 Markdown。
  Future<String> complete({
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2500,
  }) async {
    final apiKey = apiKeyOverride ?? await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw AiException('请先在「设置」里填写 DeepSeek API Key',
          needSettings: true, retryable: false);
    }
    return _chatWith(
      apiKey: apiKey,
      system: system,
      user: user,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  /// 与 _chat 同样的请求逻辑，但温度与 max_tokens 可调。
  /// 单独抽出来而不是改 _chat 的默认值——_chat 的行为已经被现有测试锁住。
  Future<String> _chatWith({
    required String apiKey,
    required String system,
    required String user,
    required double temperature,
    required int maxTokens,
  }) async {
    late final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(AppConfig.deepSeekBaseUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': AppConfig.deepSeekModel,
              'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
              ],
              'temperature': temperature,
              'max_tokens': maxTokens,
            }),
          )
          .timeout(const Duration(seconds: 180));
    } catch (e) {
      throw AiException('网络请求失败：$e');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AiException('API Key 无效，请到设置里检查',
          needSettings: true, retryable: false);
    }
    if (response.statusCode == 402) {
      throw AiException('账户余额不足', retryable: false);
    }
    if (response.statusCode == 429) {
      throw AiException('请求太频繁，请稍后再试');
    }
    if (response.statusCode != 200) {
      throw AiException('请求失败（状态码 ${response.statusCode}）');
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw AiException('接口返回的不是合法 JSON（可能被网关拦截或截断）');
    }
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw AiException('模型没有返回内容');
    }
    final first = choices.first as Map;
    if (first['finish_reason'] == 'length') {
      throw AiException('模型输出被截断（达到长度上限），请减少单次处理的文本量');
    }
    final message = first['message'] as Map?;
    final content = (message?['content'] as String?)?.trim() ?? '';
    if (content.isEmpty) {
      throw AiException('模型返回了空内容');
    }
    return content;
  }

  // ───────────────────────── 对外入口 ─────────────────────────

  /// 生成课堂笔记。默认 standard（九段式）。
  ///
  /// [level] 控制详细度：
  ///   brief  只留知识点层级 + 考试作业提示
  ///   normal 完整九段式
  ///   detail 九段式 + 原文引用与时间戳
  ///
  /// [courseName] 用于自动带上教材信息（AppConfig.textbooks）。
  /// 返回 [StudySummary]（Markdown + 思维导图结构）；网络/解析失败抛 [AiException]。
  Future<StudySummary> summarize(
    String transcript, {
    SummaryLevel level = SummaryLevel.normal,
    String courseName = '',
    NoteTemplate? template,
    String language = 'zh',
  }) async {
    final text = transcript.trim();
    if (text.length < 10) {
      throw AiException('内容太短，暂时无法总结', retryable: false);
    }

    final apiKey = apiKeyOverride ?? await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw AiException('请先在「设置」里填写 DeepSeek API Key',
          needSettings: true, retryable: false);
    }

    // 按模板+档位选择提示词，并把教材信息拼进去。
    // 不传模板时用九段式，行为与改造前一致。
    final systemPrompt = buildPrompt(
      template ?? TemplateService.defaultTemplate,
      level,
      courseName: courseName,
      language: language,
    );

    // 短课堂：一次调用搞定
    if (text.length <= chunkChars) {
      final raw = await _chat(apiKey, systemPrompt, text);
      return _parseSummary(raw, chunked: false);
    }

    // 长课堂：分块整理 → 合并
    final chunks = _splitText(text);
    final partials = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final part = await _chat(
        apiKey,
        buildChunkPrompt(courseName: courseName, language: language),
        '这是同一节课转写稿的第 ${i + 1}/${chunks.length} 段：\n\n${chunks[i]}',
      );
      partials.add(part);
    }

    final merged = await _chat(
      apiKey,
      buildMergePrompt(level,
          template: template, courseName: courseName, language: language),
      partials
          .asMap()
          .entries
          .map((e) => '【第 ${e.key + 1} 段中间笔记】\n${e.value}')
          .join('\n\n'),
    );
    return _parseSummary(merged, chunked: true);
  }

  /// 只根据「详细笔记」生成思维导图（流程的后半段）。
  ///
  /// 与总结分开：详细笔记先定稿，用户再用外部 App 改写、替换，
  /// 最后才生成导图，避免导图基于被替换前的旧正文。
  Future<MindGraph> generateMindGraph(
    String detail, {
    String courseName = '',
    String language = 'zh',
  }) async {
    final text = detail.trim();
    if (text.length < 30) {
      throw AiException('详细笔记太短，先补全再生成思维导图', retryable: false);
    }
    final apiKey = apiKeyOverride ?? await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw AiException('请先在「设置」里填写 DeepSeek API Key',
          needSettings: true, retryable: false);
    }
    final textbook = _textbookBlock(courseName);
    final system = """
你是课堂笔记整理助手。请把用户给出的详细笔记整理成思维导图，只输出一个 JSON 对象，不要 Markdown 围栏、不要解释。

结构：
{"root":"课程主题","branches":[{"id":"b0","title":"知识点结构","children":[{"id":"b0-1","title":"节点名","details":["一句话说明"],"children":[]}]}]}

规则：
- 一级分支按内容取舍，不要为了凑数编造；没有内容的类别可以省略。
- 节点标题具体，3–5 层；details 写定义、条件或易错点，没有就省略。
- 绝对不能添加笔记里没有的内容。
$textbook
""";
    final raw = await _chat(apiKey, system, text);
    final jsonText = _extractJsonObject(raw);
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(jsonText) as Map<String, dynamic>;
    } catch (_) {
      throw AiException('思维导图返回的不是合法 JSON，请重试');
    }
    final graph = MindGraph.fromJson(decoded);
    if (graph.branches.isEmpty) {
      throw AiException('思维导图没有生成节点，请重试');
    }
    return graph;
  }

  /// 从模型回复里抠出第一个完整的 JSON 对象（容忍前后废话与围栏）
  static String _extractJsonObject(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      final firstNl = text.indexOf('\n');
      if (firstNl >= 0) text = text.substring(firstNl + 1);
    }
    final start = text.indexOf('{');
    if (start < 0) return text;
    var depth = 0;
    for (var i = start; i < text.length; i++) {
      final c = text[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return text.substring(start);
  }

  // ───────────────────────── 内部实现 ─────────────────────────

  /// 从模型输出里拆出「Markdown 正文」和「JSON 代码块」。
  /// JSON 里是一棵 3–5 级详细导图；同时从它推导出旧的两层 mindMap 以保持兼容。
  /// 解析不出 JSON 时退化为：只用 Markdown，导图用空壳（页面会提示重新生成）。
  StudySummary _parseSummary(String raw, {required bool chunked}) {
    var content = raw.trim();

    // 剥掉最外层 ```markdown 围栏（模型有时会把整篇包起来）。
    // 注意：剥开头的围栏后，末尾那个围栏往往是 json 块的闭合符，
    // 不能一起剥，否则 json 块会失去边界。所以只剥开头，末尾交给
    // _extractTrailingJsonBlock 处理完再清。
    if (content.startsWith('```markdown')) {
      content = content.substring('```markdown'.length).trimLeft();
    } else if (content.startsWith('```md')) {
      content = content.substring('```md'.length).trimLeft();
    }

    // 从末尾找 json 代码块
    MindGraph? graph;
    final jsonBlock = _extractTrailingJsonBlock(content);
    if (jsonBlock != null) {
      try {
        final decoded = jsonDecode(jsonBlock.json);
        if (decoded is Map<String, dynamic>) {
          graph = MindGraph.fromJson(decoded);
          content = jsonBlock.remainder;
        }
      } catch (_) {
        // JSON 坏了不影响正文，导图留空
      }
    }

    // json 块处理完后再清掉可能残留在末尾的孤立围栏
    content = content.trim();
    while (content.endsWith('```')) {
      content = content.substring(0, content.length - 3).trimRight();
    }

    // 退一步：整篇就是纯 JSON（旧版行为 / 模型没写正文）
    // 这里没有正文可写，不能把 JSON 当 detail 存进笔记——那会覆盖旧笔记，
    // 所以无论如何都抛异常，让调用方保留原有内容。
    if (graph == null && content.trim().startsWith('{')) {
      throw AiException('模型只返回了 JSON、没有正文，请再点一次「重新总结」');
    }

    if (content.trim().isEmpty) {
      throw AiException('AI 没有返回笔记正文，请再点一次「重新总结」');
    }

    graph ??= const MindGraph(root: '本课思维导图', branches: []);
    return StudySummary(
      detailMarkdown: content.trim(),
      mindMap: _graphToLegacyMindMap(graph),
      graph: graph,
      chunked: chunked,
    );
  }

  /// 把详细导图压成旧的两层 MindMap。
  /// 为什么要这一步：详情页的「大纲」Tab 和 PNG 导出仍在用 MindMapData，
  /// 由 graph 反推可以保证两者内容一致，不必让模型输出两份。
  MindMapData _graphToLegacyMindMap(MindGraph graph) {
    return MindMapData(
      root: graph.root,
      nodes: graph.branches.map((b) {
        // 二级节点作为旧结构的 children，details 也并进去，避免信息丢失
        final children = <String>[];
        for (final d in b.details) {
          children.add(d);
        }
        for (final c in b.children) {
          children.add(c.title);
        }
        return MindNode(topic: b.title, children: children);
      }).toList(),
    );
  }

  /// 匹配末尾的 ```json ... ``` 块，返回 (json 内容, 去掉该块后的正文)。
  ///
  /// 要处理的几种真实情况：
  ///  ① 正常闭合：```json {...} ```
  ///  ② 外层被 ```markdown 包住，剥外层时把 json 块的闭合 ``` 也吃掉了；
  ///  ③ 模型忘了写闭合围栏，直接以 ```json 开头到文末。
  ({String json, String remainder})? _extractTrailingJsonBlock(String text) {
    final startFence = text.lastIndexOf('```json');
    if (startFence < 0) return null;
    final jsonStart = startFence + '```json'.length;

    // 在 json 块之后找闭合围栏；没有就当它一直延伸到文末
    final endFence = text.indexOf('```', jsonStart);
    final jsonEnd = endFence < 0 ? text.length : endFence;
    final json = text.substring(jsonStart, jsonEnd).trim();
    if (!json.startsWith('{')) return null;

    final before = text.substring(0, startFence);
    final after = endFence < 0 ? '' : text.substring(endFence + 3);
    final remainder = ('$before\n$after').trim();
    return (json: json, remainder: remainder);
  }

  /// 按段落边界切块，块间留少量重叠，避免要点被切碎
  List<String> _splitText(String text) {
    final chunks = <String>[];
    if (text.isEmpty) return chunks;
    var start = 0;
    while (start < text.length) {
      var end = start + chunkChars;
      if (end >= text.length) {
        chunks.add(text.substring(start));
        break;
      }
      // 尽量在换行/句号处断开，找不到就硬切
      final slice = text.substring(start, end);
      final breakAt = _lastBreak(slice);
      if (breakAt > chunkChars * 0.6) {
        end = start + breakAt + 1;
      }
      if (end <= start) end = start + chunkChars; // 防御：绝不出现空块
      chunks.add(text.substring(start, end));
      final next = end - overlapChars;
      start = next <= start ? end : next;
    }
    return chunks;
  }

  /// 仅用于单元测试：暴露分块逻辑，避免测试依赖私有成员
  @visibleForTesting
  List<String> debugSplitText(String text) => _splitText(text);

  /// 仅用于单元测试：暴露解析逻辑
  @visibleForTesting
  StudySummary debugParseSummary(String raw) =>
      _parseSummary(raw, chunked: false);

  int _lastBreak(String slice) {
    final candidates = [
      slice.lastIndexOf('\n'),
      slice.lastIndexOf('。'),
      slice.lastIndexOf('！'),
      slice.lastIndexOf('？'),
    ];
    return candidates.reduce((a, b) => a > b ? a : b);
  }

  Future<String> _chat(String apiKey, String system, String user) async {
    late final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(AppConfig.deepSeekBaseUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': AppConfig.deepSeekModel,
              'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
              ],
              // 详细笔记是长 Markdown，不适合强制 json_object 模式
              'temperature': 0.3,
              'max_tokens': _maxTokens,
            }),
          )
          // 长文生成明显比旧版慢，超时从 90 秒放宽到 180 秒
          .timeout(const Duration(seconds: 180));
    } catch (e) {
      throw AiException('网络请求失败，请检查网络后重试');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AiException('DeepSeek API Key 无效，请到设置里检查',
          needSettings: true, retryable: false);
    }
    if (response.statusCode == 402) {
      throw AiException('DeepSeek 账户余额不足，请充值后再试',
          needSettings: true, retryable: false);
    }
    if (response.statusCode == 429) {
      throw AiException('请求太频繁，请等十几秒再点一次');
    }
    if (response.statusCode == 400) {
      throw AiException('内容过长，服务器拒绝了本次请求，请分段后再试',
          retryable: false);
    }
    if (response.statusCode != 200) {
      // 不把整段原始 JSON 塞进提示（旧版会弹出一整屏乱码）
      throw AiException('总结失败（状态码 ${response.statusCode}），请稍后重试');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final choice = body['choices'][0] as Map<String, dynamic>;
      final content = choice['message']['content'] as String;
      final finish = choice['finish_reason'] as String?;
      if (finish == 'length') {
        // 被截断了：告诉用户，而不是悄悄给半篇
        throw AiException('笔记太长被截断了，请再点一次或把原文分两次总结');
      }
      if (content.trim().isEmpty) {
        throw AiException('AI 返回了空内容，请重试');
      }
      return content;
    } catch (e) {
      if (e is AiException) rethrow;
      throw AiException('返回内容解析失败，请重试');
    }
  }
}