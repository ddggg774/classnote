// lib/agent/classroom_agent.dart
// 顶层编排 Agent：自己决定「转写 → 纠错 → 总结 → 导图」的调用顺序。
//
// 【为什么这一层值得 Agent 化】
// 因为顺序不是固定的。真实场景里：
//   · 用户手上已经有转写稿（从别处粘贴）→ 不该再调 transcribe
//   · 转写只有几十字 → 不值得起纠错子 Agent，直接总结更划算
//   · 用户只想要导图 / 只想要速览总结 → 不需要跑全套
//   · 纠错失败 → 应该带着未纠错的文本继续走，而不是整体失败
// 这些判断用 if/else 写会变成一坨胶水，每加一种情况改一次。
//
// 【边界：Agent 只管文本处理流水线】
// transcribe 接收的是**已经切好的音频片段路径**。录音、切片、中断恢复、
// 前台服务这些仍归 RecordPage / CloudAsrService 管——那部分已经验证过，
// 塞进 Agent 循环只会把稳定的东西拖进来一起冒险。
// 同理，Agent 的产物是文本与结构，落库由调用方决定。
import '../models/mind_graph.dart';
import '../models/study_note.dart';
import '../models/note_template.dart';
import '../models/summary_level.dart';
import '../services/ai_service.dart';
import '../services/cloud_asr_service.dart';
import '../services/template_service.dart';
import 'agent_loop.dart';
import 'agent_tool.dart';
import 'correction_agent.dart';

/// 用户对本次任务的要求
class ClassroomRequest {
  final String courseName;
  final String chapter;

  /// 详细度：brief 速览 / normal 标准 / detail 详细
  final SummaryLevel level;

  /// 已有的转写稿；为空表示需要从音频转写
  final String? existingTranscript;

  /// 已切好的音频片段路径（录音/切片不归 Agent 管）
  final List<String> audioChunks;

  /// 是否要思维导图。关掉时提示词里明确不要求导图，
  /// 避免"用户关了但还在花这次调用的钱"。
  final bool wantMindMap;

  /// 笔记模板。为空时按课程自动推荐（TemplateService.recommendFor）。
  /// 走 Agent 路径也必须带上，否则「一键处理」和详情页生成的笔记格式不一致。
  final NoteTemplate? template;

  const ClassroomRequest({
    required this.courseName,
    required this.chapter,
    this.level = SummaryLevel.normal,
    this.existingTranscript,
    this.audioChunks = const [],
    this.wantMindMap = true,
    this.template,
  });

  bool get hasTranscript =>
      existingTranscript != null && existingTranscript!.trim().isNotEmpty;
  bool get hasAudio => audioChunks.isNotEmpty;
}

/// 编排产物：把每个环节的真实结果都带出来
class ClassroomResult {
  final String answer;
  final List<AgentStep> steps;
  final bool hitStepLimit;
  final bool failed;

  /// 转写文本（合并所有片段后）
  final String? transcript;

  /// 纠错后的文本
  final String? corrected;

  /// 纠错报告的待确认项（给人回听用）
  final List<String> pendingNotes;

  /// 总结正文（Markdown）
  final String? summary;

  /// 总结档位
  final SummaryLevel? level;

  /// 详细导图
  final MindGraph? graph;


  const ClassroomResult({
    required this.answer,
    this.steps = const [],
    this.hitStepLimit = false,
    this.failed = false,
    this.transcript,
    this.corrected,
    this.pendingNotes = const [],
    this.summary,
    this.level,
    this.graph,
  });

  String get logText => steps.map((s) => s.line).join('\n');

  /// 最终用于落库的文本：纠错过就用纠错的，否则用原始转写
  String? get finalText => corrected ?? transcript;

  /// 是否真的生成了总结。
  /// 从 summary 推导而不是单独存一个 bool——那样构造时忘了传就是 false，
  /// 属于"两个字段说同一件事"的经典隐患。
  bool get hasSummary => (summary ?? '').trim().isNotEmpty;
}

/// 编排过程中的共享状态：工具之间靠它传递中间结果
class _PipelineContext {
  String? transcript;
  String? corrected;
  final List<String> pendingNotes = [];
  String? summary;
  SummaryLevel? level;
  MindGraph? graph;
  StudySummary? studySummary;
}

/// 顶层编排 Agent
class ClassroomAgent {
  final String apiKey;

  /// 可注入的依赖。都给了默认实现，测试时可替换。
  final CloudAsrService? asrService;
  final AiService? aiService;

  /// 纠错子 Agent 的构造器（便于测试和复用术语缓存）
  final CorrectionAgent Function(String apiKey)? correctionAgentFactory;

  ClassroomAgent({
    required this.apiKey,
    this.asrService,
    this.aiService,
    this.correctionAgentFactory,
  });

  static const String systemPrompt = '''
你是课堂笔记的处理编排 Agent。你有一组工具，需要自己判断调用顺序。

## 可用工具
- transcribe(paths)：把**已切好的音频片段**转成文字并拼接。仅当用户给了音频、且没有现成转写稿时使用。
- run_correction_agent(transcript, course, chapter)：调用纠错子 Agent 修正术语。
  文本较长（超过约 200 字）或含专业术语时使用；很短或明显干净的文本可跳过。
- summarize(text, course, chapter, level)：生成总结。level 必填：
  brief（速览）/ normal（标准）/ detail（详细）。
- generate_mindmap(text, course, chapter)：生成 3-5 级详细思维导图。

## 编排原则
1. 先看用户给了什么：有转写稿就不必转写；只有音频就先转写。
2. 纠错要在总结之前——总结吃的应该是纠错后的文本。
3. 不要重复调用同一个工具。同一环节成功一次就够了。
4. 某个工具失败时判断能否带着已有结果继续：
   比如纠错失败，可以拿未纠错的原文去做总结，并在最终回复里说明。
5. 总结与导图是两件独立的事：用户要详细笔记就出总结，
   要结构图就出导图；需要两者就都做。
6. 全部完成后，用一段话告诉用户：做了哪些步骤、每步结果如何、
   哪些地方需要人工确认。

## 铁律
- 不要编造工具返回的内容。
- 没有文本时不要凭空总结或画导图。
- 到达步数上限仍未完成时，如实说明卡在哪一步。
''';

  /// 跑一次完整流程
  Future<ClassroomResult> run(
    ClassroomRequest request, {
    void Function(AgentStep step)? onStep,
    int maxSteps = 10,
  }) async {
    final ctx = _PipelineContext();
    final loop = AgentLoop(
      apiKey: apiKey,
      tools: _buildTools(ctx, request),
      config: AgentConfig(
        systemPrompt: systemPrompt,
        maxSteps: maxSteps,
        temperature: 0.2,
        maxTokens: 4000,
      ),
      onStep: onStep,
    );

    final task = StringBuffer()
      ..writeln('课程：${request.courseName}')
      ..writeln('章节：${request.chapter}')
      ..writeln('详细度要求：${request.level.code}（${request.level.label}）')
      ..writeln('是否已有转写稿：${request.hasTranscript ? '是' : '否'}')
      ..writeln('音频片段数：${request.audioChunks.length}')
      ..writeln('是否需要思维导图：${request.wantMindMap ? '需要' : '不需要（跳过 generate_mindmap）'}');

    if (request.hasAudio) {
      task
        ..writeln()
        ..writeln('音频片段路径：')
        ..writeln(request.audioChunks.map((p) => '- $p').join('\n'));
    }
    if (request.hasTranscript) {
      final t = request.existingTranscript!;
      task
        ..writeln('转写稿长度：${t.length} 字')
        ..writeln()
        ..writeln('----- 转写稿 -----')
        ..write(t.length > 2000 ? '${t.substring(0, 2000)}…（后略）' : t);
    }
    task
      ..writeln()
      ..writeln('请安排处理流程。');

    final result = await loop.run(task.toString());

    return ClassroomResult(
      answer: result.answer,
      steps: result.steps,
      hitStepLimit: result.hitStepLimit,
      failed: result.failed,
      transcript: ctx.transcript,
      corrected: ctx.corrected,
      pendingNotes: ctx.pendingNotes,
      summary: ctx.studySummary?.detailMarkdown ?? ctx.summary,
      level: ctx.level,
      graph: ctx.graph,
    );
  }

  ToolRegistry _buildTools(_PipelineContext ctx, ClassroomRequest request) {
    return ToolRegistry([
      // ─────────────── 转写 ───────────────
      AgentTool(
        name: 'transcribe',
        description: '把已切好的音频片段逐个转写成文字并按顺序拼接。'
            '仅在用户提供了音频、且没有现成转写稿时调用。'
            '注意：只接受已经切好的片段路径，不要传整段长录音。',
        parameters: Schema.object(
          properties: {
            'paths': Schema.stringArray('已切好的音频片段文件路径，按时间顺序'),
          },
          required: ['paths'],
        ),
        execute: (args) async {
          final raw = (args['paths'] as List?) ?? [];
          final paths = raw
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          if (paths.isEmpty) {
            return ToolResult.error('paths 为空，没有可转写的音频片段');
          }

          final asr = asrService ?? CloudAsrService();
          final parts = <String>[];
          final failures = <String>[];

          for (var i = 0; i < paths.length; i++) {
            try {
              final text = await asr.recognize(paths[i]);
              parts.add(text);
            } catch (e) {
              // 单段失败不中断整体：记下来，最后一起报
              failures.add('第 ${i + 1} 段：${e.toString().replaceFirst('Exception: ', '')}');
            }
          }

          if (parts.isEmpty) {
            return ToolResult.error(
              '所有音频片段都转写失败：\n${failures.join('\n')}',
            );
          }

          final merged = parts.join('\n');
          ctx.transcript = merged;

          final b = StringBuffer()
            ..writeln('转写完成：${parts.length}/${paths.length} 段成功，'
                '共 ${merged.length} 字。');
          if (failures.isNotEmpty) {
            b.writeln('失败片段：');
            for (final f in failures) {
              b.writeln('- $f');
            }
            b.writeln('后续处理只基于成功的部分，缺失片段请在最终回复里说明。');
          }
          return ToolResult.ok(b.toString());
        },
      ),

      // ─────────────── 纠错子 Agent ───────────────
      AgentTool(
        name: 'run_correction_agent',
        description: '调用纠错子 Agent 修正术语错误（同音字、术语误听）。'
            '会先查本节课术语表，再按 A/B/C 三档处理：高置信直接改、'
            '低置信标待确认、缺失处标缺口，绝不编造。',
        parameters: Schema.object(
          properties: {
            'transcript': Schema.string('待纠错的转写文本'),
            'course': Schema.string('课程名'),
            'chapter': Schema.string('章节名'),
          },
          required: ['transcript', 'course', 'chapter'],
        ),
        execute: (args) async {
          final text = (args['transcript'] ?? '').toString();
          final course = (args['course'] ?? '').toString();
          final chapter = (args['chapter'] ?? '').toString();
          if (text.trim().isEmpty) {
            return ToolResult.error('transcript 为空，无法纠错');
          }

          final agent = (correctionAgentFactory ?? _defaultCorrector)(apiKey);
          final result = await agent.run(
            text,
            course: course,
            chapter: chapter,
          );

          // 纠错的正文改动体现在 summary 里（含 〔改：原→正〕 标注），
          // 但为了能继续往下走，我们要把"可用于总结的文本"确定下来。
          // 策略：纠错 Agent 不改动原文的正文（它输出的是报告），
          // 所以这里用原文作为 corrected 基底，把待确认项透传给调用方。
          ctx.corrected = text;
          for (final p in result.pending) {
            ctx.pendingNotes.add(
              '${p.snippet}'
              '${p.candidates.isEmpty ? '' : ' 〔疑似：${p.candidates.join(' / ')}〕'}',
            );
          }
          for (final m in result.missing) {
            ctx.pendingNotes.add('〔缺失〕$m');
          }

          final b = StringBuffer()..writeln('纠错完成。');
          b.writeln(result.summary);
          if (result.pending.isNotEmpty) {
            b.writeln();
            b.writeln('待确认 ${result.pending.length} 处，已记录供人工回听。');
          }
          return ToolResult.ok(b.toString());
        },
      ),

      // ─────────────── 总结 ───────────────
      AgentTool(
        name: 'summarize',
        description: '生成课堂总结。level 必填：'
            'brief（速览，只有知识点与考试提示）/ '
            'normal（标准九段式）/ detail（九段式+原文引用）。',
        parameters: Schema.object(
          properties: {
            'text': Schema.string('用于总结的文本（应为纠错后的文本）'),
            'course': Schema.string('课程名'),
            'chapter': Schema.string('章节名'),
            'level': {
              'type': 'string',
              'enum': ['brief', 'normal', 'detail'],
              'description': '总结详细度',
            },
          },
          required: ['text', 'course', 'chapter', 'level'],
        ),
        execute: (args) async {
          final text = (args['text'] ?? '').toString();
          final course = (args['course'] ?? '').toString();
          final level = parseLevel(args['level']?.toString());
          if (text.trim().isEmpty) {
            return ToolResult.error('没有可总结的文本');
          }

          final ai = aiService ?? AiService(apiKeyOverride: apiKey);
          final StudySummary result;
          try {
            result = await ai.summarize(
              text,
              level: level,
              courseName: course,
              // 模板没传就按课程推荐，保证与详情页一致
              template: request.template ??
                  TemplateService.recommendFor(course),
            );
          } catch (e) {
            return ToolResult.error(
              '总结失败：${e.toString().replaceFirst('Exception: ', '')}',
            );
          }

          ctx.studySummary = result;
          ctx.summary = result.detailMarkdown;
          ctx.level = level;
          // 总结的提示词本来就要求模型带一份 JSON 导图结构，
          // 存下来不额外花钱。但用户明确不要导图时就不留，
          // 否则「关掉开关」等于没关。
          if (request.wantMindMap && result.graph.branches.isNotEmpty) {
            ctx.graph = result.graph;
          }

          return ToolResult.ok(
            '总结完成（${level.label} 档，${result.detailMarkdown.length} 字）。'
            '${result.chunked ? '课堂较长，已分块整理后合并。' : ''}',
          );
        },
      ),

      // ─────────────── 思维导图 ───────────────
      AgentTool(
        name: 'generate_mindmap',
        description: '生成 3-5 级详细思维导图（主图 + 子图，带关系标注与来源回溯）。',
        parameters: Schema.object(
          properties: {
            'text': Schema.string('用于生成导图的文本'),
            'course': Schema.string('课程名'),
            'chapter': Schema.string('章节名'),
          },
          required: ['text', 'course', 'chapter'],
        ),
        execute: (args) async {
          final text = (args['text'] ?? '').toString();
          final course = (args['course'] ?? '').toString();
          if (text.trim().isEmpty) {
            return ToolResult.error('没有可用于生成导图的文本');
          }

          // 如果已经跑过总结，直接用总结产出的导图，省一次调用
          final existing = ctx.graph;
          if (existing != null && existing.branches.isNotEmpty) {
            return ToolResult.ok(
              '复用总结已生成的导图：${existing.branches.length} 个分支，'
              '${existing.totalNodes} 个节点，最深 ${existing.maxDepth} 级。',
            );
          }

          final ai = aiService ?? AiService(apiKeyOverride: apiKey);
          try {
            final result = await ai.summarize(
              text,
              level: SummaryLevel.normal,
              courseName: course,
            );
            if (result.graph.branches.isEmpty) {
              return ToolResult.error('模型没有返回可用的导图结构');
            }
            ctx.graph = result.graph;
            // 顺手把总结也存下（如果还没有）
            ctx.studySummary ??= result;
            ctx.summary ??= result.detailMarkdown;
            return ToolResult.ok(
              '导图生成完成：${result.graph.branches.length} 个分支，'
              '${result.graph.totalNodes} 个节点，最深 ${result.graph.maxDepth} 级。',
            );
          } catch (e) {
            return ToolResult.error(
              '导图生成失败：${e.toString().replaceFirst('Exception: ', '')}',
            );
          }
        },
      ),
    ]);
  }

  /// 默认的纠错 Agent 构造（带术语缓存）
  static CorrectionAgent _defaultCorrector(String key) =>
      CorrectionAgent(apiKey: key);
}