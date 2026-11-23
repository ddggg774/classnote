// lib/services/terminology_service.dart
// 课前准备：根据课程信息生成术语表、initial_prompt、拾音风险提示。
//
// 【为什么这一步值得单独做】
// ASR 的错误不是随机的，而是"优先把词听成更常见的同音词/近似词"。
// 提前把本节课的核心术语和它们的典型误听形式摆出来，后续纠错才有依据，
// 而不是让模型凭语感猜——那样很容易编出原文没有的术语（这是明令禁止的）。
//
// 【关于 initial_prompt】
// 用户规格里说"如果转写工具支持 initial_prompt，直接注入"。
// 但 classnote 用的硅基流动 /audio/transcriptions **只接受 file 和 model 两个字段**，
// 没有 initial_prompt 参数（已核对官方文档）。所以这里的处理是：
//   ① 照常生成 initial_prompt，展示出来供用户复制到支持该参数的工具（本地 Whisper 等）；
//   ② 同时把它拼进纠错提示词——那是它在本 App 里真正发挥作用的地方。
// 不假装"已经注入了"，避免给出错误的期待。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/terminology.dart';
import 'settings_service.dart';

class TerminologyService {
  final SettingsService _settings = SettingsService();

  /// 直接注入的 API Key。传了就优先用它，跳过 SharedPreferences。
  /// 用途：命令行/测试环境没有 App 的 SharedPreferences，但术语生成是
  /// 纠错子 Agent 的必要前置，不能因为读不到 Key 就整体降级。
  final String? apiKeyOverride;

  TerminologyService({this.apiKeyOverride});

  static const String _systemPrompt = '''
你是课堂录音转写的术语准备助手。根据用户给出的课程信息，产出一份用于
「纠错与质量校准」的术语清单。你的输出会被程序直接解析，所以必须严格是 JSON。

## 术语分级规则
- high：本节课核心概念、公式名、定理名、人名（最多 15 条）
- mid：一般专业词汇
- low：英文缩写、代码名、工具名

## 数量
总条数 15~25 条：high ≤15、mid ≤15、low ≤10。
只收**本节课真的会出现的术语**（贴着章节主题），不要收整本书的目录词或泛泛的专业大类，
术语表越大，纠错时误报越多。

## 每条术语必须给出「常见误听形式」
这是最关键的部分。想一想语音识别在远距离拾音时最容易把这个词听成什么：
- 音近：前后鼻音（"分析/分西"）、平翘舌（"导数/刀数"）、声调相近（"极限/记线"）
- 形近：字形相近的字
- 缩写漂移：英文缩写被听成别的字母组合，或大小写/连字符/空格变化
  （pathname → pass name，Claude Code → cloud code）
多个候选用 / 分隔。没有任何合理误听形式时留空字符串。

## 输出 JSON 结构
{
  "terms": [
    {"term": "标准术语写法", "misheard": "误听1/误听2", "level": "high"}
  ],
  "initialPrompt": "本节课涉及：术语1、术语2、术语3……",
  "riskHints": ["风险1", "风险2", "风险3"]
}

## initialPrompt 要求
- 只放 high 优先级术语，压成一段连贯短句，不超过 50 个词 / 80 token
- 格式：本节课涉及：A、B、C……
- 必须能直接被 Whisper 类工具当作 initial_prompt 使用

## riskHints 要求
- 3~5 条，列出「距离远时最容易听错/听不到」的术语类型
- 要具体到本节课，不要写空话
- 例如："本节多次出现英文缩写 ε-δ，远场下 ε 易被整体吞掉"

## 铁律
- 只列**这门课真实会出现的**术语，不要为了凑数编造
- 不确定的术语宁可不出现在列表里
- 只输出 JSON，不要任何解释文字或 Markdown 围栏
''';

  static const String _englishRules = '''
## 英语课额外要求（覆盖上面的中文规则）
- term 必须写英文原文（如 cell wall），不要写中文术语
- 每条术语必须额外给 definition 字段：中文释义，不超过 20 字
- misheard 用英文的形近/音近形式（如 sell wall / cell walls），不要套拼音规则
- initialPrompt 里用英文术语连成短句
- 输出结构仍为 {"terms":[{"term":"...","definition":"...","misheard":"...","level":"high"}],"initialPrompt":"...","riskHints":[...]}
''';

  /// 生成术语包。失败抛 Exception。
  ///
  /// [language] 为 `en` 时按英语课规则生成：术语英文原文 + 中文释义。
  Future<TerminologyPack> prepare({
    required String courseName,
    String topic = '',
    String material = '',
    String knownTerms = '',
    String language = 'zh',
  }) async {
    final apiKey = apiKeyOverride ?? await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw Exception('请先在「设置」里填写 DeepSeek API Key');
    }

    final userMessage = StringBuffer()
      ..writeln('课程名：$courseName')
      ..writeln('课堂语言：${language == 'en' ? '英语' : '中文'}')
      ..writeln('章节主题：$topic')
      ..writeln('教材/PPT 标题：$material');
    if (knownTerms.trim().isNotEmpty) {
      userMessage.writeln('已知专有名词（请务必包含这些）：$knownTerms');
    }

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
                {'role': 'system', 'content': language == 'en' ? '$_systemPrompt\n$_englishRules' : _systemPrompt},
                {'role': 'user', 'content': userMessage.toString()},
              ],
              'response_format': {'type': 'json_object'},
              'temperature': 0.3,
              'max_tokens': 4000,
            }),
          )
          .timeout(const Duration(seconds: 90));
    } catch (_) {
      throw Exception('网络请求失败，术语表未生成');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('DeepSeek API Key 无效，请到设置里检查');
    }
    if (response.statusCode == 402) {
      throw Exception('DeepSeek 账户余额不足');
    }
    if (response.statusCode != 200) {
      throw Exception('术语表生成失败（状态码 ${response.statusCode}）');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final content = body['choices'][0]['message']['content'] as String;
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      var pack = TerminologyPack.fromJson(decoded).copyWith(
        courseName: courseName,
        topic: topic,
        material: material,
      );
      pack = _normalize(pack);
      if (pack.terms.isEmpty) {
        throw Exception('模型没有返回术语，请换一组课程信息重试');
      }
      return pack;
    } catch (e) {
      if (e is Exception && e.toString().contains('模型没有返回术语')) rethrow;
      throw Exception('术语表解析失败，请重试');
    }
  }

  /// 兜底规整：保证 high ≤ 15、总数 30–50、initial_prompt 不超长。
  /// 模型不一定守规矩，与其信它不如在这里收口。
  TerminologyPack _normalize(TerminologyPack pack) {
    final high = <Term>[];
    final mid = <Term>[];
    final low = <Term>[];
    for (final t in pack.terms) {
      switch (t.level) {
        case TermLevel.high:
          if (high.length < 15) high.add(t);
        case TermLevel.mid:
          mid.add(t);
        case TermLevel.low:
          low.add(t);
      }
    }
    // 总数封顶 50：优先保 high，再 mid，最后 low
    final merged = <Term>[...high, ...mid, ...low].take(50).toList();

    // initial_prompt 兜底：模型给了就用，没给就用 high 术语拼
    var prompt = pack.initialPrompt.trim();
    if (prompt.isEmpty && high.isNotEmpty) {
      prompt = '本节课涉及：${high.map((t) => t.term).join('、')}。';
    }
    if (prompt.length > 200) {
      // 80 token 大致对应中文 100 字上下，这里按字符截断并补句号
      prompt = '${prompt.substring(0, 100)}。';
    }

    return TerminologyPack(
      courseName: pack.courseName,
      topic: pack.topic,
      material: pack.material,
      terms: merged,
      initialPrompt: prompt,
      riskHints: pack.riskHints.take(5).toList(),
      createdAt: DateTime.now(),
    );
  }
}

extension on TerminologyPack {
  TerminologyPack copyWith({
    String? courseName,
    String? topic,
    String? material,
  }) {
    return TerminologyPack(
      courseName: courseName ?? this.courseName,
      topic: topic ?? this.topic,
      material: material ?? this.material,
      terms: terms,
      initialPrompt: initialPrompt,
      riskHints: riskHints,
      createdAt: createdAt,
    );
  }
}