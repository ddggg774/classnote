// test/agent_loop_mock_test.dart
// 用本地假 LLM 服务器端到端验证 Function Calling 协议。
//
// 【为什么不直接调真实 API】
// 手里没有可用 Key，而且每次跑测试都烧钱、结果还不稳定。
// 更重要的是：这一步要验证的是**协议对接**有没有写错——
// 比如 tool_calls 的 assistant 消息格式、role=tool 的 tool_call_id 回填、
// max_steps 能不能真的拦住循环。这些用一个可控的假服务器全都测得到，
// 而且能测真实 API 测不到的场景（比如模型连续 5 次调同一工具）。
//
// 假服务器的行为可编程：给它一个「剧本」，它按剧本返回 tool_calls 或最终回复。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/agent/agent_loop.dart';
import 'package:classnote/agent/agent_tool.dart';

/// 一条剧本指令
class _Beat {
  /// 要调用的工具名（null 表示这是最终回复）
  final String? tool;
  final Map<String, dynamic> args;
  final String? finalAnswer;

  const _Beat.call(this.tool, this.args) : finalAnswer = null;
  const _Beat.final_(this.finalAnswer)
      : tool = null,
        args = const {};
}

/// 假 LLM 服务器
class _FakeLlm {
  late HttpServer _server;
  final List<_Beat> beats;
  int calls = 0;

  /// 记录每次收到的请求体，用于断言协议细节
  final List<Map<String, dynamic>> requests = [];

  _FakeLlm(this.beats);

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      requests.add(jsonDecode(body) as Map<String, dynamic>);

      final beat = calls < beats.length ? beats[calls] : const _Beat.final_('结束');
      calls++;

      Map<String, dynamic> message;
      if (beat.tool != null) {
        message = {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_$calls',
              'type': 'function',
              'function': {
                'name': beat.tool,
                'arguments': jsonEncode(beat.args),
              },
            }
          ],
        };
      } else {
        message = {'role': 'assistant', 'content': beat.finalAnswer ?? ''};
      }

      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {'message': message, 'finish_reason': beat.tool == null ? 'stop' : 'tool_calls'}
          ]
        }));
      await req.response.close();
    });
    return 'http://127.0.0.1:${_server.port}/v1/chat/completions';
  }

  Future<void> stop() async => _server.close(force: true);
}

void main() {
  test('完整走通「调工具 → 回填 → 出最终回答」', () async {
    final fake = _FakeLlm([
      const _Beat.call('get_weather', {'city': '北京'}),
      const _Beat.final_('北京今天晴，25 度。'),
    ]);
    final url = await fake.start();
    addTearDown(fake.stop);

    var toolCalled = 0;
    final loop = AgentLoop(
      apiKey: 'fake',
      baseUrlOverride: url,
      tools: ToolRegistry([
        AgentTool(
          name: 'get_weather',
          description: '查天气',
          parameters: Schema.object(
            properties: {'city': Schema.string('城市')},
            required: ['city'],
          ),
          execute: (args) async {
            toolCalled++;
            return ToolResult.ok('${args['city']} 晴 25 度');
          },
        ),
      ]),
      config: const AgentConfig(systemPrompt: 'x', maxSteps: 5),
    );

    final result = await loop.run('北京天气');

    expect(toolCalled, 1, reason: '工具应该被真实调用一次');
    expect(result.failed, isFalse);
    expect(result.answer, contains('25'));
    // 两步：调工具 + 出结论
    expect(result.steps.length, 2);
    expect(result.steps[0].kind, 'tool');
    expect(result.steps[0].success, isTrue);
    expect(result.steps[1].kind, 'final');

    // 协议断言：第 2 次请求里必须带上 assistant(tool_calls) 和 role=tool 的回填
    final second = fake.requests[1];
    final messages = (second['messages'] as List).cast<Map<String, dynamic>>();
    final assistantMsg =
        messages.firstWhere((m) => m['role'] == 'assistant' && m.containsKey('tool_calls'));
    expect(assistantMsg['tool_calls'], isA<List>());
    final toolMsg = messages.firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['tool_call_id'], 'call_1',
        reason: 'tool 结果必须按 tool_call_id 回填，否则模型串不上');
    expect(toolMsg['content'], contains('25 度'));

    // 请求里带上了 tools 定义
    expect(second['tools'], isA<List>());
    expect(second['tool_choice'], 'auto');
  });

  test('模型连续调工具时 maxSteps 会拦住（不会无限循环）', () async {
    // 给 20 步剧本，但 maxSteps 只有 3
    final fake = _FakeLlm(
      List.generate(20, (_) => const _Beat.call('busy', {})),
    );
    final url = await fake.start();
    addTearDown(fake.stop);

    var calls = 0;
    final loop = AgentLoop(
      apiKey: 'fake',
      baseUrlOverride: url,
      tools: ToolRegistry([
        AgentTool(
          name: 'busy',
          description: '一直忙',
          parameters: Schema.object(properties: {}),
          execute: (args) async {
            calls++;
            return ToolResult.ok('还在忙');
          },
        ),
      ]),
      config: const AgentConfig(systemPrompt: 'x', maxSteps: 3),
    );

    final result = await loop.run('干点活');
    expect(result.hitStepLimit, isTrue, reason: '必须在 maxSteps 处停住');
    expect(result.failed, isTrue);
    expect(calls, 3, reason: '正好调满 3 步就停，不多调');
    expect(result.answer, contains('最大步数'));
  });

  test('工具抛异常不会中断循环，模型能拿到错误继续', () async {
    final fake = _FakeLlm([
      const _Beat.call('boom', {}),
      const _Beat.final_('工具失败了，我改用别的办法。'),
    ]);
    final url = await fake.start();
    addTearDown(fake.stop);

    final loop = AgentLoop(
      apiKey: 'fake',
      baseUrlOverride: url,
      tools: ToolRegistry([
        AgentTool(
          name: 'boom',
          description: '会炸',
          parameters: Schema.object(properties: {}),
          execute: (args) async => throw Exception('磁盘满了'),
        ),
      ]),
      config: const AgentConfig(systemPrompt: 'x', maxSteps: 5),
    );

    final result = await loop.run('试试');
    expect(result.failed, isFalse, reason: '工具失败不应判整个 run 失败');
    expect(result.steps[0].success, isFalse);
    expect(result.steps[0].summary, contains('磁盘满了'));
    // 回填给模型的内容里带错误信息
    final second = fake.requests[1];
    final messages = (second['messages'] as List).cast<Map<String, dynamic>>();
    final toolMsg = messages.firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['content'], contains('磁盘满了'));
  });

  test('模型调用了不存在的工具时给出明确错误', () async {
    final fake = _FakeLlm([
      const _Beat.call('不存在的工具', {}),
      const _Beat.final_('好的。'),
    ]);
    final url = await fake.start();
    addTearDown(fake.stop);

    final loop = AgentLoop(
      apiKey: 'fake',
      baseUrlOverride: url,
      tools: ToolRegistry([]),
      config: const AgentConfig(systemPrompt: 'x', maxSteps: 5),
    );

    final result = await loop.run('试试');
    expect(result.steps[0].success, isFalse);
    expect(result.steps[0].summary, contains('不存在'));
  });

  test('HTTP 401 会转成可读错误而不是崩溃', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      await req.drain<void>();
      req.response.statusCode = 401;
      await req.response.close();
    });

    final loop = AgentLoop(
      apiKey: 'bad',
      baseUrlOverride:
          'http://127.0.0.1:${server.port}/v1/chat/completions',
      tools: ToolRegistry([]),
      config: const AgentConfig(systemPrompt: 'x', maxSteps: 3),
    );

    final result = await loop.run('hi');
    expect(result.failed, isTrue);
    expect(result.answer, contains('API Key'));
  });
}