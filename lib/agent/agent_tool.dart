// lib/agent/agent_tool.dart
// Agent 工具定义层。
//
// 【为什么单独抽一层】
// Function Calling 的「工具」是三件事绑在一起：
//   ① 给模型看的 JSON Schema（它决定模型什么时候调、传什么参数）
//   ② Dart 侧真实执行的函数
//   ③ 执行结果的回填格式（必须是字符串，模型只认文本）
// 把这三样包进一个 AgentTool，Agent 循环就只依赖统一的 call() 接口，
// 以后加工具不用改循环代码。
//
// 【为什么不用 openai 官方 SDK】
// DeepSeek 的 Function Calling 与 OpenAI 协议兼容，本质上就是
// POST /chat/completions 带 tools 字段、读 tool_calls。用已有的 http 包
// 直接发请求，比引入一个 SDK 更可控——出问题时栈是干净的，也没有版本兼容风险。
// 这符合"所有逻辑落在代码里、只靠我们自己维护"的约束。
import 'dart:convert';

/// 工具执行结果。永远返回字符串：模型只吃得下文本。
class ToolResult {
  final String content;

  /// 是否算失败。失败不会中断 Agent，模型会看到错误信息并决定下一步。
  final bool isError;

  const ToolResult(this.content, {this.isError = false});

  factory ToolResult.ok(Object? value) =>
      ToolResult(value is String ? value : jsonEncode(value));

  factory ToolResult.error(String message) =>
      ToolResult('错误：$message', isError: true);
}

/// 一个可被模型调用的工具
class AgentTool {
  /// 函数名，必须符合 [a-zA-Z0-9_-]{1,64}，模型按这个名字调用
  final String name;

  /// 给模型看的说明：说清"什么时候该用我"，比说清"我做什么"更重要
  final String description;

  /// JSON Schema 的参数定义
  final Map<String, dynamic> parameters;

  /// 实际执行体。参数是模型传来的 JSON，返回 ToolResult。
  final Future<ToolResult> Function(Map<String, dynamic> args) execute;

  const AgentTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
  });

  /// 转成 API 需要的 tools 数组元素
  Map<String, dynamic> toApiSchema() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };

  /// 安全执行：任何异常都转成 ToolResult.error，
  /// 绝不让一个工具的异常把整个 Agent 循环掀翻。
  Future<ToolResult> call(Map<String, dynamic> args) async {
    try {
      return await execute(args);
    } catch (e) {
      return ToolResult.error(e.toString().replaceFirst('Exception: ', ''));
    }
  }
}

/// 工具集合
class ToolRegistry {
  final Map<String, AgentTool> _tools;

  ToolRegistry(List<AgentTool> tools)
      : _tools = {for (final t in tools) t.name: t};

  List<Map<String, dynamic>> toApiSchemas() =>
      _tools.values.map((t) => t.toApiSchema()).toList();

  AgentTool? operator [](String name) => _tools[name];

  bool contains(String name) => _tools.containsKey(name);

  List<String> get names => _tools.keys.toList();
}

/// 常用的 JSON Schema 片段，避免每个工具重复写
class Schema {
  const Schema._();

  static Map<String, dynamic> object({
    required Map<String, dynamic> properties,
    List<String> required = const [],
  }) =>
      {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
      };

  static Map<String, dynamic> string(String description) =>
      {'type': 'string', 'description': description};

  static Map<String, dynamic> integer(String description) =>
      {'type': 'integer', 'description': description};

  static Map<String, dynamic> boolean(String description) =>
      {'type': 'boolean', 'description': description};

  static Map<String, dynamic> stringArray(String description) => {
        'type': 'array',
        'items': {'type': 'string'},
        'description': description,
      };
}