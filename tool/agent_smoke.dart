// 冒烟测试：用真实 DeepSeek API 跑一遍 Agent 循环，验证 tool_calls 协议对接正确。
import 'dart:io';
import 'package:classnote/agent/agent_loop.dart';
import 'package:classnote/agent/agent_tool.dart';

Future<void> main() async {
  final key = Platform.environment['DS_KEY'] ?? '';
  if (key.isEmpty) {
    print('SKIP: 无 DS_KEY');
    exit(0);
  }
  var called = 0;
  final tools = ToolRegistry([
    AgentTool(
      name: 'get_weather',
      description: '查询指定城市的天气。',
      parameters: Schema.object(
        properties: {'city': Schema.string('城市名')},
        required: ['city'],
      ),
      execute: (args) async {
        called++;
        return ToolResult.ok('${args['city']} 今天晴，25度');
      },
    ),
  ]);
  final result = await AgentLoop(
    apiKey: key,
    tools: tools,
    config: const AgentConfig(systemPrompt: '你是助手。需要天气时必须调用工具。', maxSteps: 5),
  ).run('北京今天天气怎么样？');
  print('=== 工具被调用次数: $called');
  print('=== 日志 ===');
  print(result.logText);
  print('=== 回答 ===');
  print(result.answer);
}
