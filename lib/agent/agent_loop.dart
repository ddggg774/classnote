// lib/agent/agent_loop.dart
// Agent 主循环：Function Calling 的「想—调—看」闭环。
//
// 【这一层只有四个职责】
//   ① 把 messages + tools 发给模型
//   ② 看模型有没有要调工具
//   ③ 有就执行工具，把结果塞回 messages，再来一轮
//   ④ 没有就结束，返回最终回复
//
// 【为什么 max_steps 必须硬性存在】
// 模型有可能反复调同一个工具、或者两个工具来回踢皮球。
// 没有步数上限就是无限烧钱 + 无限等待。到上限时把"已做了什么"如实返回，
// 而不是假装成功。
//
// 【日志为什么记在内存里返回而不是丢给 debugPrint】
// 验收标准要求"日志能看出每步成功/失败原因"。debugPrint 在 release 包里
// 看不见，用户也无从反馈。所以这里把每一步结构化成 AgentStep 存下来，
// 由调用方决定展示还是落库。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'agent_tool.dart';

/// 一步日志
class AgentStep {
  final int index;

  /// 这一步做了什么：'think' 纯思考 | 'tool' 调工具 | 'final' 出结论
  final String kind;

  /// 工具名（kind == 'tool' 时有值）
  final String? toolName;

  /// 工具入参（JSON 字符串，已截断到可读长度）
  final String? toolArgs;

  /// 结果摘要
  final String summary;

  final bool success;

  /// 耗时
  final Duration elapsed;

  const AgentStep({
    required this.index,
    required this.kind,
    this.toolName,
    this.toolArgs,
    required this.summary,
    this.success = true,
    required this.elapsed,
  });

  /// 一行可读日志，直接给界面/日志文件用
  String get line {
    final mark = success ? '✓' : '✗';
    final who = toolName == null ? kind : '$kind:$toolName';
    final args = toolArgs == null ? '' : '($toolArgs)';
    return '[$index] $mark $who$args → $summary (${elapsed.inMilliseconds}ms)';
  }
}

/// 一次 Agent 运行的完整结果
class AgentRunResult {
  /// 模型最后一轮的自然语言回复
  final String answer;

  /// 逐步日志
  final List<AgentStep> steps;

  /// 是否因为步数上限被截断
  final bool hitStepLimit;

  /// 是否中途出错（错误已写进 steps）
  final bool failed;

  const AgentRunResult({
    required this.answer,
    this.steps = const [],
    this.hitStepLimit = false,
    this.failed = false,
  });

  String get logText => steps.map((s) => s.line).join('\n');
}

/// Agent 运行配置
class AgentConfig {
  final String systemPrompt;
  final int maxSteps;
  final double temperature;
  final int maxTokens;

  const AgentConfig({
    required this.systemPrompt,
    this.maxSteps = 10,
    this.temperature = 0.3,
    this.maxTokens = 4000,
  });
}

/// Agent 循环本体
class AgentLoop {
  final String apiKey;
  final ToolRegistry tools;
  final AgentConfig config;

  /// 可选的回调：每完成一步通知一次，界面用它做实时进度
  final void Function(AgentStep step)? onStep;

  AgentLoop({
    required this.apiKey,
    required this.tools,
    required this.config,
    this.onStep,
  });

  /// 跑一轮 Agent。
  /// [userMessage] 是这次交给 Agent 的任务；[historyJson] 可带上前文的
  /// messages（用于把子 Agent 的结论接进父 Agent），一般传 null。
  Future<AgentRunResult> run(
    String userMessage, {
    List<Map<String, dynamic>>? history,
  }) async {
    final steps = <AgentStep>[];
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': config.systemPrompt},
      ...?history,
      {'role': 'user', 'content': userMessage},
    ];

    for (var i = 1; i <= config.maxSteps; i++) {
      final sw = Stopwatch()..start();

      Map<String, dynamic> response;
      try {
        response = await _post(messages);
      } catch (e) {
        final step = AgentStep(
          index: i,
          kind: 'error',
          summary: e.toString().replaceFirst('Exception: ', ''),
          success: false,
          elapsed: sw.elapsed,
        );
        steps.add(step);
        onStep?.call(step);
        return AgentRunResult(
          answer: '请求失败：${step.summary}',
          steps: steps,
          failed: true,
        );
      }
      sw.stop();

      final choice = (response['choices'] as List?)?.first;
      if (choice is! Map) {
        return AgentRunResult(
          answer: '模型返回格式异常',
          steps: steps,
          failed: true,
        );
      }
      final message = choice['message'] as Map<String, dynamic>? ?? {};
      final content = (message['content'] as String?)?.trim() ?? '';
      final toolCalls = (message['tool_calls'] as List?) ?? [];

      // 没有工具调用 → 这就是最终回答
      if (toolCalls.isEmpty) {
        final step = AgentStep(
          index: i,
          kind: 'final',
          summary: content.isEmpty ? '（空回复）' : _clip(content, 60),
          elapsed: sw.elapsed,
        );
        steps.add(step);
        onStep?.call(step);
        return AgentRunResult(answer: content, steps: steps);
      }

      // 有工具调用 → 先把 assistant 这条（含 tool_calls）塞回历史
      messages.add({
        'role': 'assistant',
        'content': content,
        'tool_calls': toolCalls,
      });

      // 逐条执行，结果按 tool_call_id 回填
      for (final call in toolCalls) {
        final callMap = call as Map<String, dynamic>;
        final callId = callMap['id']?.toString() ?? '';
        final fn = callMap['function'] as Map<String, dynamic>? ?? {};
        final name = fn['name']?.toString() ?? '';
        final rawArgs = fn['arguments']?.toString() ?? '{}';

        final toolSw = Stopwatch()..start();
        Map<String, dynamic> args = {};
        ToolResult result;

        try {
          final decoded = rawArgs.isEmpty ? <String, dynamic>{} : jsonDecode(rawArgs);
          args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
        } catch (_) {
          args = <String, dynamic>{};
        }

        final tool = tools[name];
        if (tool == null) {
          result = ToolResult.error('不存在名为 $name 的工具');
        } else {
          result = await tool.call(args);
        }
        toolSw.stop();

        final step = AgentStep(
          index: i,
          kind: 'tool',
          toolName: name,
          toolArgs: _clip(rawArgs, 80),
          summary: _clip(result.content, 80),
          success: !result.isError,
          elapsed: toolSw.elapsed,
        );
        steps.add(step);
        onStep?.call(step);

        // 工具结果必须以 tool 角色回填，且带 tool_call_id，否则模型串不上
        messages.add({
          'role': 'tool',
          'tool_call_id': callId,
          'content': result.content,
        });
      }
    }

    // 到步数上限
    return AgentRunResult(
      answer: '已达到最大步数 ${config.maxSteps}，任务未完成。已执行步骤见日志。',
      steps: steps,
      hitStepLimit: true,
      failed: true,
    );
  }

  Future<Map<String, dynamic>> _post(List<Map<String, dynamic>> messages) async {
    final body = <String, dynamic>{
      'model': AppConfig.deepSeekModel,
      'messages': messages,
      'temperature': config.temperature,
      'max_tokens': config.maxTokens,
    };
    if (tools.names.isNotEmpty) {
      body['tools'] = tools.toApiSchemas();
      // auto：让模型自己决定调用哪个工具、调几次
      body['tool_choice'] = 'auto';
    }

    final response = await http
        .post(
          Uri.parse(AppConfig.deepSeekBaseUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 180));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('API Key 无效，请到设置里检查');
    }
    if (response.statusCode == 402) {
      throw Exception('账户余额不足');
    }
    if (response.statusCode == 429) {
      throw Exception('请求太频繁，请稍后再试');
    }
    if (response.statusCode != 200) {
      throw Exception('请求失败（状态码 ${response.statusCode}）');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static String _clip(String s, int max) {
    final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
  }
}