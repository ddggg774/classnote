// lib/agent/classroom_agent.dart
// 顶层编排 Agent：自己决定「转写 → 纠错 → 总结 → 导图」的调用顺序。
//
// 【为什么这一层值得 Agent 化】
// 因为顺序不是固定的。举个真实场景：
//   · 用户手上已经有转写稿（从别处粘贴来的）→ 不该再调 transcribe
//   · 转写只有几十字 → 不值得起纠错子 Agent，直接总结更划算
//   · 用户只想要导图 → 不需要跑详细总结
//   · 纠错失败 → 应该带着未纠错的文本继续走，而不是整体失败
// 这些判断用 if/else 写会变成一坨胶水代码，而且每加一种情况就要改一次。
// 交给模型编排，它读工具描述自己决定。
//
// 【骨架阶段的重要说明】
// 本文件当前四个工具都还是「桩」：它们返回结构化的假数据，
// 用来先验证 Agent 循环、日志、步数控制是否工作正常。
// 第二步/第三步会把桩替换成真实实现（transcribe → CloudAsrService，
// summarize → AiService，等等）。这样做的原因是不让业务逻辑和
// Agent 机制在同一次改动里纠缠——先证明骨架对，再接真东西。
import 'package:flutter/foundation.dart';

import 'agent_loop.dart';
import 'agent_tool.dart';

/// 用户对本次任务的要求
class ClassroomRequest {
  final String courseName;
  final String chapter;
  /// 详细度：brief 速览 / normal 标准 / detail 详细
  final String detailLevel;
  /// 已有的转写稿；为空表示需要从音频转写
  final String? existingTranscript;
  /// 音频文件路径；为空表示没有音频
  final String? audioPath;

  const ClassroomRequest({
    required this.courseName,
    required this.chapter,
    this.detailLevel = 'normal',
    this.existingTranscript,
    this.audioPath,
  });

  bool get hasTranscript =>
      existingTranscript != null && existingTranscript!.trim().isNotEmpty;
  bool get hasAudio => audioPath != null && audioPath!.trim().isNotEmpty;
}

/// 编排产物
class ClassroomResult {
  final String answer;
  final List<AgentStep> steps;
  final bool hitStepLimit;
  final bool failed;

  /// 各环节产出（由工具回填）
  final String? transcript;
  final String? corrected;
  final String? summary;
  final String? mindmap;

  const ClassroomResult({
    required this.answer,
    this.steps = const [],
    this.hitStepLimit = false,
    this.failed = false,
    this.transcript,
    this.corrected,
    this.summary,
    this.mindmap,
  });

  String get logText => steps.map((s) => s.line).join('\n');
}

/// 编排 Agent 运行期的上下文：工具之间靠它传递中间结果
class _PipelineContext {
  String? transcript;
  String? corrected;
  String? summary;
  String? mindmap;
}

/// 顶层编排 Agent
class ClassroomAgent {
  final String apiKey;

  /// 纠错子 Agent 的入口（骨架阶段先留 hook，第二步接真实现）
  final Future<String> Function(String transcript, String course, String chapter)?
      correctionRunner;

  ClassroomAgent({required this.apiKey, this.correctionRunner});

  static const String systemPrompt = '''
你是课堂笔记的处理编排 Agent。你有一组工具，需要自己判断调用顺序。

## 可用工具
- transcribe(audio_path)：把音频转成文字。仅当用户提供了音频、且没有现成转写稿时使用。
- run_correction_agent(transcript, course, chapter)：调用纠错子 Agent 修正术语错误。
  文本较长（超过约 200 字）或含专业术语时使用；文本很短时可直接跳过。
- summarize(transcript, course, chapter, level)：生成总结。
  level 可选 brief（速览）/ normal（标准）/ detail（详细）。
- generate_mindmap(transcript, course, chapter)：生成思维导图。

## 编排原则
1. 先看用户给了什么：有转写稿就不必转写；只有音频就先转写。
2. 顺序上，纠错要在总结之前——总结吃的应该是纠错后的文本。
3. 不要重复调用同一个工具。同一个环节跑成功一次就够了。
4. 某个工具失败时，判断能否带着已有结果继续：
   比如纠错失败，可以拿未纠错的原文去做总结，并在最终回复里说明。
5. 所有环节完成后，用一段话告诉用户：做了哪些步骤、每步结果如何、
   哪些地方需要人工确认。

## 铁律
- 不要编造工具返回的内容。
- 不要跳过 transcribe 就直接总结（没有文本时）。
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
      ..writeln('详细度要求：${request.detailLevel}')
      ..writeln('是否已有转写稿：${request.hasTranscript ? '是' : '否'}')
      ..writeln('是否提供音频：${request.hasAudio ? '是' : '否'}');
    if (request.hasTranscript) {
      final t = request.existingTranscript!;
      task
        ..writeln('转写稿长度：${t.length} 字')
        ..writeln()
        ..writeln('----- 转写稿 -----')
        ..write(t.length > 2000 ? '${t.substring(0, 2000)}…（后略）' : t);
    }
    task.writeln();
    task.writeln('请安排处理流程。');

    final result = await loop.run(task.toString());

    return ClassroomResult(
      answer: result.answer,
      steps: result.steps,
      hitStepLimit: result.hitStepLimit,
      failed: result.failed,
      transcript: ctx.transcript,
      corrected: ctx.corrected,
      summary: ctx.summary,
      mindmap: ctx.mindmap,
    );
  }

  ToolRegistry _buildTools(_PipelineContext ctx, ClassroomRequest request) {
    return ToolRegistry([
      AgentTool(
        name: 'transcribe',
        description: '把音频文件转写成文字。仅在用户提供了音频且没有现成转写稿时调用。',
        parameters: Schema.object(
          properties: {
            'audio_path': Schema.string('音频文件路径'),
          },
          required: ['audio_path'],
        ),
        execute: (args) async {
          final path = (args['audio_path'] ?? '').toString().trim();
          if (path.isEmpty) {
            return ToolResult.error('audio_path 不能为空');
          }
          // TODO(第三步): 接 CloudAsrService.recognize(path)
          debugPrint('[agent] transcribe 桩调用: $path');
          final fake = '（骨架阶段占位：这里将返回 $path 的转写文本）';
          ctx.transcript = fake;
          return ToolResult.ok('转写完成，共 ${fake.length} 字。\n$fake');
        },
      ),
      AgentTool(
        name: 'run_correction_agent',
        description: '调用纠错子 Agent 修正术语错误。文本较长或含专业术语时使用。',
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
          // 接纠错子 Agent；没注入就走降级（原样返回）
          final corrected = correctionRunner == null
              ? text
              : await correctionRunner!(text, course, chapter);
          ctx.corrected = corrected;
          return ToolResult.ok('纠错完成，输出 ${corrected.length} 字。');
        },
      ),
      AgentTool(
        name: 'summarize',
        description: '生成课堂总结。level 选 brief/normal/detail。',
        parameters: Schema.object(
          properties: {
            'transcript': Schema.string('用于总结的文本（应为纠错后的文本）'),
            'course': Schema.string('课程名'),
            'chapter': Schema.string('章节名'),
            'level': {
              'type': 'string',
              'enum': ['brief', 'normal', 'detail'],
              'description': '总结详细度',
            },
          },
          required: ['transcript', 'course', 'chapter', 'level'],
        ),
        execute: (args) async {
          final text = (args['transcript'] ?? '').toString();
          final level = (args['level'] ?? 'normal').toString();
          if (text.trim().isEmpty) {
            return ToolResult.error('没有可总结的文本');
          }
          // TODO(第三步): 接 AiService.summarize + 分档
          debugPrint('[agent] summarize 桩调用: level=$level, ${text.length} 字');
          final fake = '（骨架阶段占位：$level 档总结）';
          ctx.summary = fake;
          return ToolResult.ok('总结完成（$level 档）。\n$fake');
        },
      ),
      AgentTool(
        name: 'generate_mindmap',
        description: '根据文本生成思维导图（主图 + 子图，3-5 级）。',
        parameters: Schema.object(
          properties: {
            'transcript': Schema.string('用于生成导图的文本'),
            'course': Schema.string('课程名'),
            'chapter': Schema.string('章节名'),
          },
          required: ['transcript', 'course', 'chapter'],
        ),
        execute: (args) async {
          final text = (args['transcript'] ?? '').toString();
          if (text.trim().isEmpty) {
            return ToolResult.error('没有可用于生成导图的文本');
          }
          // TODO(第三步): 接 AiService 产出的 MindGraph
          debugPrint('[agent] generate_mindmap 桩调用: ${text.length} 字');
          const fake = '（骨架阶段占位：思维导图）';
          ctx.mindmap = fake;
          return ToolResult.ok('导图生成完成。\n$fake');
        },
      ),
    ]);
  }
}