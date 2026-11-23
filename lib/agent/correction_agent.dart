// lib/agent/correction_agent.dart
// 纠错子 Agent：只做术语纠错，需要模型反复判断的那部分。
//
// 【为什么把它做成 Agent 而不是普通函数】
// 现有 TranscriptCorrector.calibrate() 是一次性的：进去一段文本，出来一份报告。
// 它会一次给出全部结论，但没法"中途查证"——比如遇到 Latin 学名时，
// 它并不能真的去查术语表再决定改不改。
// Agent 化的价值在于：模型可以分步走——先查术语表，再对着表逐条判断，
// 拿不准的调 flag_uncertain 标出来，看到断句就调 mark_missing。
// 每一步都是一次独立判断，而不是一次成型。
//
// 【关键设计：工具是真的在做事，不是装饰】
//   lookup_terminology → 真的从术语包里按课程+章节检索，只回相关的那几十条
//   flag_uncertain     → 真的把待确认项累积进结果集，最终汇总
//   mark_missing       → 真的记录缺失位置，最终输出
// 这些累积结果由 AgentSession 持有，Agent 跑完后一起取出来。
// 如果工具只是"返回一句 OK"，那这套 Agent 就是假的——这点我很在意。
import '../config.dart';
import '../models/terminology.dart';
import '../services/pending_budget.dart';
import '../services/terminology_service.dart';
import 'agent_loop.dart';
import 'agent_tool.dart';
import 'terminology_store.dart';

/// 纠错 Agent 运行期累积的产物
class CorrectionSession {
  /// 模型通过 flag_uncertain 标出的待确认项
  final List<PendingItem> pending = [];

  /// 模型通过 mark_missing 标出的缺失位置
  final List<String> missing = [];

  /// 模型查过哪些课程/章节的术语（用于日志与调试）
  final List<String> lookups = [];

  /// 本次用到的术语包
  TerminologyPack? pack;

  /// 术语表是否直接命中缓存（用于日志与成本提示）
  bool cacheHit = false;

  bool get hasFindings => pending.isNotEmpty || missing.isNotEmpty;
}

/// 纠错子 Agent
class CorrectionAgent {
  final String apiKey;

  /// 术语检索的数据源。默认走 TerminologyService（按课程+章节现生成），
  /// 也可以在构造时注入一个现成的术语包（测试/离线场景用）。
  final TerminologyPack? presetPack;

  /// 术语生成服务。带上 apiKey，避免在没有 SharedPreferences 的环境
  /// （命令行/测试）里读不到 Key 导致术语表检索整体失败。
  late final TerminologyService _terminologyService =
      TerminologyService(apiKeyOverride: apiKey);

  /// 术语表缓存仓库。传 null 表示不用缓存（测试场景）。
  final TerminologyStore? _store;

  CorrectionAgent({
    required this.apiKey,
    this.presetPack,
    TerminologyStore? store,
  }) : _store = store;

  /// 英语课的纠错提示词：只许修拼写/专名/同音，禁止翻译与改写。
  /// 中文课仍走上面的 [systemPrompt]，一个字不改。
  static const String englishSystemPrompt = '''
你是「英语课」录音转写的术语纠错子 Agent。你的唯一职责是修正英语转写里被听错的词。

## 工作方式（必须真的调用工具）
1. lookup_terminology(course, chapter) —— 先查本节课术语表
2. flag_uncertain(span, candidates) —— 拿不准的标出来
3. mark_missing(context) —— 明显缺词时标出位置

## 允许的修改（仅三类）
A. 明显拼写错误：recieve → receive
B. 专有名词大小写/连字符：darwin → Darwin
C. 同音/近音误听，且上下文能唯一确定：sell wall → cell wall

## 待确认预算（硬性）
- flag_uncertain 最多 5 次；只标最值得回听的 5 处；
- 纯标点/数字/单字、原文本来就对、能高置信改的，不标。

## 严禁
- 把英文翻译成中文；不许新增原文没有的汉字（原文本身的中文解释保留）
- 改写句子结构、删减内容、润色、合并句子
- 把术语换成同义词

## 拿不准
保留原文，调用 flag_uncertain 标注候选。宁可标待确认，不要猜。

## 输出
先给一段简短的纠错报告（改了什么、哪些待确认），不要重复贴全文。
''';

  /// 系统提示词：把之前定好的 A/B/C 三档规则原样写死在代码里。
  /// 这不是给用户看的说明，是给模型的硬约束。
  static const String systemPrompt = '''
你是课堂录音转写的「术语纠错子 Agent」。你的唯一职责是纠正远场转写里的术语错误。

## 工作方式
你有三个工具，必须真的调用它们来完成任务，不要凭空判断：
1. lookup_terminology(course, chapter) —— 先查本节课的术语表。
   拿到术语表后，才能判断某个词是不是听错了。
2. flag_uncertain(span, candidates) —— 拿不准的地方，标出来交给人回听。
3. mark_missing(context) —— 句子明显缺词、逻辑断裂时，标出缺失位置。

## 待确认预算（硬性）
- flag_uncertain 最多调用 5 次；超过 5 处疑似的，只标最值得人回听的 5 处；
- 排序：命中高优先术语 > 同一处反复出现 > 候选唯一 > 其他；
- 纯标点/纯数字/单字、原文通顺且非术语、你能高置信直接改的，一律不标。

## 三档处理规则（严格执行）

### A 档：高置信度直接改
满足以下任意一条，直接替换，并在该句末尾标 〔改：原→正〕：
- 与术语表某条的「常见误听形式」音近/形近高度匹配（前后鼻音、平翘舌、声调相近都算）
- 英文/缩写与标准写法仅差大小写、连字符、空格（pass name → pathname）
- 数字/单位明显转错且上下文唯一确定

### B 档：低置信度只标注
疑似术语错误但无法确定正确形式时：
- 保留原文不动，标 〔疑似：候选1 / 候选2，待确认〕
- 严禁为了通顺而编造术语替换进去
- 同时调用 flag_uncertain 把这一处登记下来

### C 档：远场缺失
句子不完整、明显缺词时，不要补全。标：
〔此处可能缺失：前文在讲……，后文转向……，中间待确认〕
同时调用 mark_missing 登记。

## 学科专属约束
- 植物学：拉丁学名严格保留双名法原样（属名首字母大写、种加词小写、斜体意义不体现在纯文本里但要保留大小写）；
  科名（-aceae 结尾）、属名、器官名、细胞结构名不得意译、不得改写。拉丁名拿不准时标待确认，**绝不臆造拼写**。
- 专业制图：保留规范编号、图名、线型名称、尺寸标注术语原样。
  **制图类型不明确时标"待确认"，不编造规范编号**（如 GB/T 编号、线型代号）。

## 铁律
1. 不确定 > 猜测。标待确认永远优于填一个看似合理的错词。
2. 不改写句子结构，不润色，不补充原文没有的内容。
3. 只纠正术语与明显听错，不做全文重写。
4. 完成后，用一段话总结：改了几处、标了几处待确认、几处缺失。
   完整的纠错后正文由程序从你的标注中提取，你不需要重复粘贴全文。
''';

  /// 组装工具集。每次运行新建，绑定到本次的 session。
  ToolRegistry _buildTools(CorrectionSession session, {String language = 'zh'}) {
    return ToolRegistry([
      AgentTool(
        name: 'lookup_terminology',
        description: '按课程名与章节查询本节课的术语表。'
            '返回该章节的术语及其常见误听形式。纠错前必须先调用它。',
        parameters: Schema.object(
          properties: {
            'course': Schema.string('课程名，例如"植物学"'),
            'chapter': Schema.string('章节名，例如"第三章 被子植物"'),
          },
          required: ['course', 'chapter'],
        ),
        execute: (args) async {
          final course = (args['course'] ?? '').toString().trim();
          final chapter = (args['chapter'] ?? '').toString().trim();
          session.lookups.add('$course/$chapter');

          // 优先级：外部注入 > 本次已查过 > 数据库缓存 > 现场生成
          // 现场生成要调模型、花钱花时间，所以能复用就复用。
          var pack = presetPack ?? session.pack;

          if (pack == null && _store != null) {
            pack = await _store!.get(course, chapter, language: language);
            if (pack != null) {
              session.pack = pack;
              session.cacheHit = true;
            }
          }

          if (pack == null) {
            try {
              pack = await _terminologyService.prepare(
                courseName: course,
                topic: chapter,
                // 教材名/编者/出版社一起带上：模型知道是哪本书的哪一版，
                // 才能按那套术语体系去猜误听词，而不是泛泛给"这门课的术语"
                material: AppConfig.textbookLine(course),
                language: language,
              );
              session.pack = pack;
              // 生成成功后写缓存，下次同章节直接读
              await _store?.put(course, chapter, pack, language: language);
            } catch (e) {
              return ToolResult.error(
                '术语表检索失败（$e）。此时只能修正非常明显的同音错误，'
                '其余一律标待确认。',
              );
            }
          }
          if (pack.terms.isEmpty) {
            return const ToolResult(
              '该课程章节暂无术语表。请只修正非常明显的同音错误，'
              '拿不准的一律标待确认并调用 flag_uncertain。',
            );
          }
          return ToolResult.ok(
            '本节课术语表（共 ${pack.terms.length} 条）：\n'
            '${pack.termsAsPromptText}',
          );
        },
      ),
      AgentTool(
        name: 'flag_uncertain',
        description: '把一处拿不准的术语标为待确认，交给人回听核对。'
            '调用后这一处结论会进入最终的待确认清单。',
        parameters: Schema.object(
          properties: {
            'span': Schema.string('原文片段（这一处所在的词或短句）'),
            'candidates': Schema.stringArray('可能的正确写法，可以为空数组'),
            'reason': Schema.string('为什么拿不准（可选）'),
          },
          required: ['span', 'candidates'],
        ),
        execute: (args) async {
          final span = (args['span'] ?? '').toString().trim();
          if (span.isEmpty) {
            return ToolResult.error('span 不能为空');
          }
          final candidates = ((args['candidates'] as List?) ?? [])
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          // 同一片段重复标记时合并计数
          final existing = session.pending.where((p) => p.snippet == span);
          if (existing.isNotEmpty) {
            final old = existing.first;
            final idx = session.pending.indexOf(old);
            session.pending[idx] = PendingItem(
              snippet: old.snippet,
              candidates: {...old.candidates, ...candidates}.toList(),
              count: old.count + 1,
              timestamp: old.timestamp,
            );
            return ToolResult.ok('已登记（该片段第 ${old.count + 1} 次出现）：$span');
          }
          session.pending.add(PendingItem(
            snippet: span,
            candidates: candidates,
          ));
          return ToolResult.ok(
            '已登记待确认：$span'
            '${candidates.isEmpty ? '' : '（候选：${candidates.join(' / ')}）'}',
          );
        },
      ),
      AgentTool(
        name: 'mark_missing',
        description: '标记一处因远场拾音导致的缺失。不补全内容，只记录缺口位置。',
        parameters: Schema.object(
          properties: {
            'context': Schema.string(
                '缺失处的上下文描述，例如"前文在讲叶片结构，后文转向花的形态"'),
          },
          required: ['context'],
        ),
        execute: (args) async {
          final ctx = (args['context'] ?? '').toString().trim();
          if (ctx.isEmpty) {
            return ToolResult.error('context 不能为空');
          }
          session.missing.add(ctx);
          return ToolResult.ok('已登记缺失：$ctx');
        },
      ),
    ]);
  }

  /// 跑一次纠错。
  /// [transcript] 转写原文；[course]/[chapter] 用于查术语表；
  /// [onStep] 可选，实时回传每一步日志。
  Future<CorrectionAgentResult> run(
    String transcript, {
    required String course,
    required String chapter,
    void Function(AgentStep step)? onStep,
    int maxSteps = 5,
    String language = 'zh',
  }) async {
    final session = CorrectionSession();
    final loop = AgentLoop(
      apiKey: apiKey,
      tools: _buildTools(session, language: language),
      config: AgentConfig(
        systemPrompt: language == 'en' ? englishSystemPrompt : systemPrompt,
        maxSteps: maxSteps,
        // 纠错要保守，温度压低，避免顺手润色
        temperature: 0.1,
        maxTokens: 8000,
      ),
      onStep: onStep,
    );

    final task = StringBuffer()
      ..writeln('课程：$course')
      ..writeln('章节：$chapter')
      ..writeln()
      ..writeln('请对下面这段转写做术语纠错。')
      ..writeln('先调用 lookup_terminology 查术语表，再对照表逐处判断。')
      ..writeln()
      ..writeln('----- 转写原文 -----')
      ..write(transcript);

    final result = await loop.run(task.toString());

    // 预算收口：过滤噪音、合并同义、排序、截断到 5 条
    final pack = session.pack;
    final highTerms = pack?.terms
            .where((t) => t.level == TermLevel.high)
            .map((t) => t.term)
            .toSet() ??
        const <String>{};
    final highMisheard = pack?.terms
            .where((t) => t.level == TermLevel.high)
            .expand((t) => t.misheardList)
            .toSet() ??
        const <String>{};
    final trimmed = PendingBudget.trim(
      session.pending,
      max: PendingBudget.defaultMax,
      highPriorityTerms: highTerms,
      highPriorityMisheard: highMisheard,
    );

    return CorrectionAgentResult(
      summary: result.answer,
      steps: result.steps,
      pending: trimmed.kept,
      suppressedCount: trimmed.suppressed,
      missing: session.missing,
      pack: session.pack,
      hitStepLimit: result.hitStepLimit,
      failed: result.failed,
    );
  }
}

/// 纠错 Agent 的返回值
class CorrectionAgentResult {
  final String summary;
  final List<AgentStep> steps;
  final List<PendingItem> pending;
  final List<String> missing;
  final TerminologyPack? pack;
  final bool hitStepLimit;
  final bool failed;

  /// 因预算被压掉的待确认条数（界面显示「另有 N 处未列出」）
  final int suppressedCount;

  const CorrectionAgentResult({
    required this.summary,
    this.steps = const [],
    this.pending = const [],
    this.missing = const [],
    this.pack,
    this.hitStepLimit = false,
    this.failed = false,
    this.suppressedCount = 0,
  });

  String get logText => steps.map((s) => s.line).join('\n');

  /// 给 UI/报告用的组合文本
  String get reportText {
    final b = StringBuffer()..writeln(summary);
    if (pending.isNotEmpty) {
      b.writeln();
      b.writeln('## 待确认清单');
      for (final p in pending) {
        b.writeln('- ${p.snippet}'
            '${p.candidates.isEmpty ? '' : '〔疑似：${p.candidates.join(' / ')}〕'}'
            '${p.count > 1 ? '（出现 ${p.count} 次）' : ''}');
      }
    }
    if (missing.isNotEmpty) {
      b.writeln();
      b.writeln('## 缺失位置');
      for (final m in missing) {
        b.writeln('- $m');
      }
    }
    return b.toString();
  }
}