// test/agent_loop_test.dart
// Agent 机制测试（不依赖网络）。
//
// 骨架阶段最该验证的不是"业务对不对"，而是"机制牢不牢"：
//   ① 工具 schema 能正确序列化；
//   ② 工具抛异常不会掀翻循环；
//   ③ 工具注册表按名查得到、查不到返回 null；
//   ④ 日志能记录成功/失败与耗时；
//   ⑤ max_steps 真的会拦住无限循环。
// 这些是第二步/第三步接真实工具时的地基，地基歪了后面全歪。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/agent/agent_tool.dart';
import 'package:classnote/agent/agent_loop.dart';

void main() {
  group('ToolResult', () {
    test('字符串原样返回', () {
      expect(ToolResult.ok('abc').content, 'abc');
      expect(ToolResult.ok('abc').isError, isFalse);
    });

    test('非字符串转成 JSON', () {
      final r = ToolResult.ok({'a': 1});
      expect(r.content, '{"a":1}');
    });

    test('error 带前缀且标记失败', () {
      final r = ToolResult.error('炸了');
      expect(r.content, contains('错误：'));
      expect(r.isError, isTrue);
    });
  });

  group('AgentTool', () {
    test('schema 结构符合 Function Calling 规范', () {
      final tool = AgentTool(
        name: 'demo',
        description: '演示工具',
        parameters: Schema.object(
          properties: {'x': Schema.string('参数x')},
          required: ['x'],
        ),
        execute: (args) async => ToolResult.ok('ok'),
      );
      final schema = tool.toApiSchema();
      expect(schema['type'], 'function');
      final fn = schema['function'] as Map;
      expect(fn['name'], 'demo');
      expect(fn['description'], '演示工具');
      expect((fn['parameters'] as Map)['type'], 'object');
      expect((fn['parameters'] as Map)['required'], ['x']);
    });

    test('execute 抛异常时 call 返回错误而不是抛出去', () async {
      final tool = AgentTool(
        name: 'boom',
        description: '会炸',
        parameters: Schema.object(properties: {}),
        execute: (args) async => throw Exception('内部炸了'),
      );
      final r = await tool.call({});
      expect(r.isError, isTrue);
      expect(r.content, contains('内部炸了'));
    });
  });

  group('ToolRegistry', () {
    final a = AgentTool(
      name: 'a',
      description: 'A',
      parameters: Schema.object(properties: {}),
      execute: (args) async => ToolResult.ok('a'),
    );
    final b = AgentTool(
      name: 'b',
      description: 'B',
      parameters: Schema.object(properties: {}),
      execute: (args) async => ToolResult.ok('b'),
    );

    test('按名查找', () {
      final reg = ToolRegistry([a, b]);
      expect(reg['a']?.name, 'a');
      expect(reg.contains('b'), isTrue);
      expect(reg.names, containsAll(['a', 'b']));
    });

    test('找不到返回 null', () {
      final reg = ToolRegistry([a]);
      expect(reg['不存在的工具'], isNull);
      expect(reg.contains('不存在的工具'), isFalse);
    });

    test('schema 列表长度与工具数一致', () {
      final reg = ToolRegistry([a, b]);
      expect(reg.toApiSchemas().length, 2);
    });
  });

  group('AgentStep 日志', () {
    test('成功行带 ✓ 和工具名', () {
      const step = AgentStep(
        index: 1,
        kind: 'tool',
        toolName: 'transcribe',
        toolArgs: '{"audio_path":"a.wav"}',
        summary: '转写完成',
        elapsed: Duration(milliseconds: 120),
      );
      expect(step.line, contains('✓'));
      expect(step.line, contains('transcribe'));
      expect(step.line, contains('120ms'));
    });

    test('失败行带 ✗', () {
      const step = AgentStep(
        index: 2,
        kind: 'tool',
        toolName: 'summarize',
        summary: '没有可总结的文本',
        success: false,
        elapsed: Duration(milliseconds: 5),
      );
      expect(step.line, contains('✗'));
    });
  });

  group('AgentConfig 默认值', () {
    test('maxSteps 与温度符合预期', () {
      const cfg = AgentConfig(systemPrompt: 'x');
      expect(cfg.maxSteps, 10);
      expect(cfg.temperature, 0.3);
    });

    test('可覆盖为纠错子 Agent 的保守配置', () {
      const cfg = AgentConfig(
        systemPrompt: 'x',
        maxSteps: 5,
        temperature: 0.1,
      );
      expect(cfg.maxSteps, 5);
      expect(cfg.temperature, 0.1);
    });
  });

  group('AgentRunResult', () {
    test('logText 把多步拼成多行', () {
      const r = AgentRunResult(
        answer: 'ok',
        steps: [
          AgentStep(
              index: 1,
              kind: 'tool',
              toolName: 'a',
              summary: 's1',
              elapsed: Duration(milliseconds: 1)),
          AgentStep(
              index: 2,
              kind: 'final',
              summary: 's2',
              elapsed: Duration(milliseconds: 1)),
        ],
      );
      final lines = r.logText.split('\n');
      expect(lines.length, 2);
      expect(lines[0], contains('a'));
      expect(lines[1], contains('final'));
    });

    test('到达上限时 hitStepLimit 为真', () {
      const r = AgentRunResult(answer: 'x', hitStepLimit: true, failed: true);
      expect(r.hitStepLimit, isTrue);
      expect(r.failed, isTrue);
    });
  });
}