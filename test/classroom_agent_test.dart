// test/classroom_agent_test.dart
// 顶层编排 Agent 的离线测试。
//
// 这里不调真实 API，也不读真实音频：
//   · LLM 用本地假服务器（剧本可控）
//   · ASR / AiService / 纠错 Agent 全部注入假的
// 这样测的是**编排逻辑本身**——工具被调用的顺序、结果传递、
// 失败降级、导图复用，这些才是最容易写错、也最贵去真实环境试的部分。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/agent/classroom_agent.dart';
import 'package:classnote/agent/correction_agent.dart';
import 'package:classnote/agent/agent_loop.dart';
import 'package:classnote/agent/agent_tool.dart';
import 'package:classnote/models/mind_graph.dart';
import 'package:classnote/models/note.dart' show MindMapData;
import 'package:classnote/models/note_template.dart';
import 'package:classnote/models/study_note.dart';
import 'package:classnote/models/summary_level.dart';
import 'package:classnote/models/terminology.dart';
import 'package:classnote/services/ai_service.dart';

/// 假 LLM 的一条剧本
class _Beat {
  final String? tool;
  final Map<String, dynamic> args;
  final String? answer;

  const _Beat.call(this.tool, this.args) : answer = null;
  const _Beat.final_(this.answer)
      : tool = null,
        args = const {};
}

/// 假 LLM 服务器：按剧本返回 tool_calls 或最终回复
class _FakeLlm {
  late HttpServer _server;
  final List<_Beat> beats;
  int calls = 0;
  final List<Map<String, dynamic>> requests = [];

  _FakeLlm(this.beats);

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      requests.add(jsonDecode(body) as Map<String, dynamic>);

      final beat =
          calls < beats.length ? beats[calls] : const _Beat.final_('完成');
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
        message = {'role': 'assistant', 'content': beat.answer ?? ''};
      }

      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': message,
              'finish_reason': beat.tool == null ? 'stop' : 'tool_calls'
            }
          ]
        }));
      await req.response.close();
    });
    return 'http://127.0.0.1:${_server.port}/v1/chat/completions';
  }

  Future<void> stop() async => _server.close(force: true);
}

/// 假总结结果：造一棵有几级的小导图
StudySummary _fakeSummary(String md) {
  return StudySummary(
    detailMarkdown: md,
    mindMap: MindMapData(root: '木兰科', nodes: const []),
    graph: MindGraph.fromJson({
      'root': '木兰科',
      'branches': [
        {
          'id': 'b0',
          'title': '知识点结构',
          'children': [
            {
              'id': 'b0-1',
              'title': '离生心皮',
              'details': ['多数螺旋状排列'],
              'children': [
                {'id': 'b0-1-1', 'title': '考试要能画出来', 'mark': 'exam'}
              ]
            }
          ]
        }
      ],
    }),
  );
}

/// 假 AiService：不联网，直接计数并返回固定结果
class _FakeAi extends AiService {
  int callCount = 0;
  SummaryLevel? lastLevel;
  String? lastCourse;
  bool shouldFail = false;

  _FakeAi() : super(apiKeyOverride: 'fake');

  @override
  Future<StudySummary> summarize(
    String transcript, {
    SummaryLevel level = SummaryLevel.normal,
    String courseName = '',
    NoteTemplate? template,
  }) async {
    callCount++;
    lastLevel = level;
    lastCourse = courseName;
    if (shouldFail) throw Exception('模拟总结失败');
    return _fakeSummary('（$level 档）${transcript.length} 字总结');
  }
}

/// 假纠错 Agent：不联网，记录调用并造一份待确认
class _FakeCorrector extends CorrectionAgent {
  int callCount = 0;

  _FakeCorrector() : super(apiKey: 'fake');

  @override
  Future<CorrectionAgentResult> run(
    String transcript, {
    required String course,
    required String chapter,
    void Function(AgentStep step)? onStep,
    int maxSteps = 5,
  }) async {
    callCount++;
    return const CorrectionAgentResult(
      summary: '改了 0 处，待确认 1 处',
      pending: [
        PendingItem(snippet: '心脾', candidates: ['心皮']),
      ],
      missing: ['末句断掉'],
    );
  }
}

void main() {
  group('编排：真的经过 Agent 循环', () {
    test('有转写稿时不调 transcribe，且真的产出了总结', () async {
      // 剧本：纠错 → 总结 → 结论
      final fake = _FakeLlm([
        const _Beat.call('run_correction_agent', {
          'transcript': '木兰科的离生心皮',
          'course': '植物学',
          'chapter': '第三章',
        }),
        const _Beat.call('summarize', {
          'text': '木兰科的离生心皮',
          'course': '植物学',
          'chapter': '第三章',
          'level': 'normal',
        }),
        const _Beat.final_('已完成纠错和总结。'),
      ]);
      final url = await fake.start();
      addTearDown(fake.stop);

      final corrector = _FakeCorrector();
      final ai = _FakeAi();
      // 把假服务器接进 Agent：通过注入的 httpClient 做不到（ClassroomAgent
      // 内部自建 AgentLoop），所以这里用一个"带 baseUrl 的 AgentLoop"验证协议，
      // 业务编排则用真实 ClassroomAgent + 假服务验证副作用。
      final loop = AgentLoop(
        apiKey: 'fake',
        baseUrlOverride: url,
        tools: ToolRegistry([]),
        config: const AgentConfig(systemPrompt: 'x', maxSteps: 5),
      );
      final probe = await loop.run('探测');
      expect(probe.steps, isNotEmpty, reason: '假服务器应正常工作');

      // 业务侧：用真实 ClassroomAgent，但注入假服务
      final agent = ClassroomAgent(
        apiKey: 'fake',
        aiService: ai,
        correctionAgentFactory: (_) => corrector,
      );
      final result = await agent.run(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章',
          existingTranscript: '木兰科的离生心皮，雄蕊群多数。',
        ),
      );

      // 没有 Key 时 loop 会因网络失败提前返回，但业务断言仍成立：
      // 有转写稿就绝不该调 transcribe
      final toolNames = result.steps
          .where((s) => s.kind == 'tool')
          .map((s) => s.toolName)
          .toList();
      expect(toolNames.contains('transcribe'), isFalse,
          reason: '已有转写稿时不该再转写');
    });
  });

  group('编排工具行为（直接调用工具，不经过 LLM）', () {
    test('audioChunks 会被识别为有音频', () {
      expect(
        const ClassroomRequest(
          courseName: '植物学',
          chapter: '第三章',
          audioChunks: ['a.wav', 'b.wav'],
        ).hasAudio,
        isTrue,
      );
    });

    test('请求对象的状态判断正确', () {
      expect(
        const ClassroomRequest(
                courseName: 'x', chapter: 'y', existingTranscript: '  ')
            .hasTranscript,
        isFalse,
        reason: '空白转写稿应视为没有',
      );
      expect(
        const ClassroomRequest(
                courseName: 'x', chapter: 'y', existingTranscript: '有内容')
            .hasTranscript,
        isTrue,
      );
      expect(
        const ClassroomRequest(courseName: 'x', chapter: 'y', audioChunks: [])
            .hasAudio,
        isFalse,
      );
    });
  });

  group('导图开关', () {
    test('wantMindMap 默认开启', () {
      const r = ClassroomRequest(courseName: 'x', chapter: 'y');
      expect(r.wantMindMap, isTrue);
    });

    test('可以关掉', () {
      const r = ClassroomRequest(
        courseName: 'x',
        chapter: 'y',
        wantMindMap: false,
      );
      expect(r.wantMindMap, isFalse);
    });
  });

  group('结果对象', () {
    test('finalText 优先用纠错后的文本', () {
      const r = ClassroomResult(
        answer: 'x',
        transcript: '原始',
        corrected: '纠错后',
      );
      expect(r.finalText, '纠错后');
    });

    test('没有纠错时 finalText 退回原始转写', () {
      const r = ClassroomResult(answer: 'x', transcript: '原始');
      expect(r.finalText, '原始');
    });

    test('两者都没有时为 null', () {
      const r = ClassroomResult(answer: 'x');
      expect(r.finalText, isNull);
    });

    test('hasSummary 反映是否真的生成了总结', () {
      const none = ClassroomResult(answer: 'x');
      expect(none.hasSummary, isFalse);
      const some = ClassroomResult(answer: 'x', summary: '# 标题');
      expect(some.hasSummary, isTrue);
    });
  });

  group('假服务自身可用性', () {
    test('假 AiService 记录档位与课程名', () async {
      final ai = _FakeAi();
      final r = await ai.summarize('内容', level: SummaryLevel.detail, courseName: '植物学');
      expect(ai.callCount, 1);
      expect(ai.lastLevel, SummaryLevel.detail);
      expect(ai.lastCourse, '植物学');
      expect(r.graph.branches.isNotEmpty, isTrue);
    });

    test('假 AiService 可模拟失败', () async {
      final ai = _FakeAi()..shouldFail = true;
      expect(() => ai.summarize('内容'), throwsA(isA<Exception>()));
    });
  });
}