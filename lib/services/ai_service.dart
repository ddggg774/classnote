// lib/services/ai_service.dart
// AI 总结服务：把课堂原文整理成「详细可复习笔记」+「思维导图结构」。
// 这是"网络层"：唯一会联网的地方，失败时抛 AiException 由页面展示。
//
// 【为什么重写过一次】
// 旧版提示词自己把输出掐死了：nodes 3~6 个要点、children 2~4 条且每条不超过 15 字。
// 用户反馈"太简略"，根因就在这里——不是模型能力不够，是要求就是这么写的。
// 现在的目标是「详细版长度约为转写原文的 20%–40%，以完整可复习为先」，
// 并且有硬约束：不编造、缺失处必须标注「转写缺失 / 待确认」。
//
// 【长文本处理】
// 两小时的课堂转写有 2–4 万字，一次性塞进 deepseek-chat 会超上下文（400）。
// 所以按字数分块，每块整理成「中间笔记」，再合并成一份最终九段式 Markdown。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/note.dart';
import '../models/study_note.dart';
import 'settings_service.dart';

/// AI 调用失败：区分「用户该去改设置」和「重试就行」，页面据此给不同引导。
class AiException implements Exception {
  final String message;
  final bool needSettings; // true = Key 缺失/无效，应引导去设置页
  final bool retryable;

  AiException(this.message, {this.needSettings = false, this.retryable = true});

  @override
  String toString() => message;
}

class AiService {
  final SettingsService _settings = SettingsService();

  /// 单次请求能安全送进去的字数。deepseek-chat 上下文 64K token，
  /// 中文约 1 字 ≈ 1 token，留出 system 提示与输出空间后取 8000 字比较稳。
  static const int chunkChars = 8000;

  /// 拆块时的重叠字数：避免要点恰好被切断在半句上
  static const int overlapChars = 200;

  /// 详细笔记的输出上限。20%~40% 的篇幅比原来的几百字长得多，
  /// max_tokens 给足（12000），否则长课堂会被硬截断成半截文档。
  static const int _maxTokens = 12000;

  // ───────────────────────── 提示词 ─────────────────────────

  /// 九段式详细笔记的主提示词。
  /// 关键设计：
  /// 1) 先定死章节顺序与标题，保证每次输出都是同一套结构，方便复习和二次编辑；
  /// 2) 明确列出「不许编造 / 缺失必须标注」，这是验收标准里最硬的一条；
  /// 3) 明确要求说明逻辑关系、而不是堆关键词；
  /// 4) 末尾要求附一段 JSON 供思维导图用，一次调用产出两份东西。
  static const String _detailSystemPrompt = '''
你是一名严谨的大学课堂笔记整理专家。你的任务是把课堂录音转写稿，整理成一份**详细、可直接用来复习**的结构化笔记。

## 最高优先级铁律（违反即不合格）
1. **绝对不能编造**。原文没说的定义、公式、数字、人名、结论，一律不许补。
2. 转写听不清、句子断裂、公式或数字可疑、人名/术语拿不准的地方，**必须**标注 `〔待确认〕` 或 `〔转写缺失〕` 并写清哪里可疑。
3. 公式、术语、代码、英文缩写**保留原样**，不要翻译、不要改写大小写。
4. 如果某一节原文里确实没有对应内容，写「本节未提及」，**不要**为了凑结构而虚构。
5. 输出只允许是 Markdown 正文，不要加任何解释性开场白。

## 整理要求
- 去掉口语重复、语气词（"啊/呢/那个/就是说"）和明显的转写错误；用书面语重述，但**不改变原意**。
- 不要只列关键词。每个知识点要说明**逻辑关系**：是什么 → 为什么 → 怎么用 → 适用条件。
- 能判断信息来源时，用小标签区分：`〔讲授〕`、`〔板书/PPT〕`、`〔师生问答〕`、`〔作业布置〕`。
- 详细程度：**约为原文长度的 20%~40%**，以"完整可复习"为先，宁详勿略。
- 原文里出现的时间点（如果转写稿带时间戳）请尽量保留；没有时间戳就引用原文片段代替，用「」括起来。

## 输出结构（严格按此顺序与标题）
# 课程信息
- 课程名 / 本节主题 / 学习目标 / 与前后知识的关联

# 知识点结构
按层级组织（## 一级知识点、### 二级），每个知识点包含：
- 概念定义
- 公式/定理（如有，保留原式）
- 推导步骤（如有）
- 适用条件
- 老师强调点
- 逻辑关系说明（前后知识点怎么连起来的）

# 例题与解题步骤
每道例题用以下字段，**步骤缺失必须标注**：
- 题干：
- 解题思路：
- 关键步骤：（逐条，缺步骤时写 `〔转写缺失〕`）
- 答案：（不确定写 `〔待确认〕`）
- 易错点：

# 老师强调与考试作业提示
- 重点 / 难点 / 易错点
- 考试范围
- 作业要求 / 提交方式 / 截止时间（没提到就写"未提及"）

# 课堂互动问答
逐条列：学生问 → 老师答 → 结论

# 术语/公式/英文缩写表
用 Markdown 表格：| 术语 | 原文中的位置或片段 | 简要解释 |

# 学习任务表
用 Markdown 表格：| 任务 | 类型(作业/预习/复习) | 截止时间 | 提交方式 |
没有的内容一律写"未提及"。

# 疑问与待确认清单
逐条列出所有不确定的地方，格式：- 位置/原文片段：不确定的原因 → `待确认`

# 时间戳回溯
关键知识点、例题、作业考试提示的时间点或原文片段索引。

## 额外要求
在 Markdown 正文的**最末尾**，附一个 JSON 代码块供思维导图使用（同样不许编造）：
```json
{"root":"本课主题(不超过12字)","nodes":[{"topic":"要点(不超过15字)","children":["子点"]}]}
```
nodes 数量按课堂长度自适应：短课 4~6 个，长课覆盖全部主要章节。
''';

  /// 超长课堂的「分块整理」提示词：只整理结构，不做最终排版
  static const String _chunkSystemPrompt = '''
你是一名严谨的大学课堂笔记整理专家。现在只给你一节课转写稿的**其中一段**，
请把这一段整理成结构化的中间笔记，供后续合并使用。

铁律：
1. 绝对不许编造原文没有的内容。
2. 转写不清、公式/数字/人名/术语可疑的地方，标注 `〔待确认〕`，并写出可疑的原文片段。
3. 公式、术语、代码、英文缩写保留原样。
4. 注意记录这段里出现的：概念定义、公式定理、推导步骤、适用条件、老师强调点、
   例题（题干/思路/步骤/答案/易错点）、考试与作业要求（含截止时间与提交方式）、
   师生问答、以及所有可疑点。
5. 输出 Markdown，不要开场白。信息不足的类别直接省略，不要写空标题。
''';

  /// 合并多段中间笔记为最终九段式文档
  static const String _mergeSystemPrompt = '''
你会收到同一节课若干片段的中间笔记（按讲课顺序）。
请把它们合并整理成一份**详细、可直接复习**的九段式课堂笔记。

铁律：
1. 绝对不能编造任何片段里没有的内容。
2. 任何片段里标了 `〔待确认〕` 的内容，在最终文档里必须保留该标注并汇总进
   「# 疑问与待确认清单」。
3. 公式、术语、代码、英文缩写保留原样。
4. 章节顺序与标题严格照下面执行，没有内容的节写「本节未提及」，不要删节。
5. 详细程度：合并后长度约为原始转写稿的 20%~40%。

## 输出结构（严格按此顺序）
# 课程信息
# 知识点结构
# 例题与解题步骤
# 老师强调与考试作业提示
# 课堂互动问答
# 术语/公式/英文缩写表
# 学习任务表
# 疑问与待确认清单
# 时间戳回溯

各节的字段要求：
- 课程信息：课程名 / 本节主题 / 学习目标 / 与前后知识的关联
- 知识点结构：按 ## / ### 层级，每点含概念定义、公式/定理、推导步骤、适用条件、老师强调点、逻辑关系
- 例题与解题步骤：题干、思路、关键步骤、答案、易错点；步骤缺失写 `〔转写缺失〕`
- 老师强调与考试作业提示：重点、难点、易错点、考试范围、作业要求、提交方式、截止时间
- 课堂互动问答：学生问 → 老师答 → 结论
- 术语表：| 术语 | 位置或片段 | 简要解释 |
- 学习任务表：| 任务 | 类型 | 截止时间 | 提交方式 |，没有写"未提及"
- 疑问清单：- 位置/原文片段：原因 → `待确认`
- 时间戳回溯：关键内容的时间点或原文片段索引

最后附 JSON 代码块供思维导图：
```json
{"root":"本课主题","nodes":[{"topic":"要点","children":["子点"]}]}
```
''';

  // ───────────────────────── 对外入口 ─────────────────────────

  /// 生成详细课堂笔记。
  /// 返回 [StudySummary]（Markdown + 思维导图结构）；网络/解析失败抛 [AiException]。
  Future<StudySummary> summarize(String transcript) async {
    final text = transcript.trim();
    if (text.length < 10) {
      throw AiException('内容太短，暂时无法总结', retryable: false);
    }

    final apiKey = await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw AiException('请先在「设置」里填写 DeepSeek API Key',
          needSettings: true, retryable: false);
    }

    // 短课堂：一次调用搞定
    if (text.length <= chunkChars) {
      final raw = await _chat(apiKey, _detailSystemPrompt, text);
      return _parseSummary(raw, chunked: false);
    }

    // 长课堂：分块整理 → 合并
    final chunks = _splitText(text);
    final partials = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final part = await _chat(
        apiKey,
        _chunkSystemPrompt,
        '这是同一节课转写稿的第 ${i + 1}/${chunks.length} 段：\n\n${chunks[i]}',
      );
      partials.add(part);
    }

    final merged = await _chat(
      apiKey,
      _mergeSystemPrompt,
      partials
          .asMap()
          .entries
          .map((e) => '【第 ${e.key + 1} 段中间笔记】\n${e.value}')
          .join('\n\n'),
    );
    return _parseSummary(merged, chunked: true);
  }

  // ───────────────────────── 内部实现 ─────────────────────────

  /// 从模型输出里拆出「Markdown 正文」和「JSON 代码块」。
  /// 解析不出 JSON 时退化为：只用 Markdown，导图用空壳（页面会提示重新生成）。
  StudySummary _parseSummary(String raw, {required bool chunked}) {
    var content = raw.trim();

    // 剥掉最外层 ```markdown 围栏（模型有时会把整篇包起来）。
    // 注意：剥开头的围栏后，末尾那个围栏往往是 json 块的闭合符，
    // 不能一起剥，否则 json 块会失去边界。所以只剥开头，末尾交给
    // _extractTrailingJsonBlock 处理完再清。
    if (content.startsWith('```markdown')) {
      content = content.substring('```markdown'.length).trimLeft();
    } else if (content.startsWith('```md')) {
      content = content.substring('```md'.length).trimLeft();
    }

    // 从末尾找 json 代码块
    MindMapData? mindMap;
    final jsonBlock = _extractTrailingJsonBlock(content);
    if (jsonBlock != null) {
      try {
        final decoded = jsonDecode(jsonBlock.json);
        if (decoded is Map<String, dynamic>) {
          mindMap = MindMapData.fromJson(decoded);
          content = jsonBlock.remainder;
        }
      } catch (_) {
        // JSON 坏了不影响正文，导图留空
      }
    }

    // json 块处理完后再清掉可能残留在末尾的孤立围栏
    content = content.trim();
    while (content.endsWith('```')) {
      content = content.substring(0, content.length - 3).trimRight();
    }

    // 退一步：整篇就是纯 JSON（旧版行为）
    if (mindMap == null && content.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(content.trim());
        if (decoded is Map<String, dynamic>) {
          mindMap = MindMapData.fromJson(decoded);
          return StudySummary(
            detailMarkdown: '',
            mindMap: mindMap,
            chunked: chunked,
          );
        }
      } catch (_) {}
    }

    mindMap ??= MindMapData(root: '本课总结', nodes: const []);

    if (content.trim().isEmpty) {
      throw AiException('AI 没有返回笔记正文，请再点一次「重新总结」');
    }

    return StudySummary(
      detailMarkdown: content.trim(),
      mindMap: mindMap,
      chunked: chunked,
    );
  }

  /// 匹配末尾的 ```json ... ``` 块，返回 (json 内容, 去掉该块后的正文)。
  ///
  /// 要处理的几种真实情况：
  ///  ① 正常闭合：```json {...} ```
  ///  ② 外层被 ```markdown 包住，剥外层时把 json 块的闭合 ``` 也吃掉了；
  ///  ③ 模型忘了写闭合围栏，直接以 ```json 开头到文末。
  ({String json, String remainder})? _extractTrailingJsonBlock(String text) {
    final startFence = text.lastIndexOf('```json');
    if (startFence < 0) return null;
    final jsonStart = startFence + '```json'.length;

    // 在 json 块之后找闭合围栏；没有就当它一直延伸到文末
    final endFence = text.indexOf('```', jsonStart);
    final jsonEnd = endFence < 0 ? text.length : endFence;
    final json = text.substring(jsonStart, jsonEnd).trim();
    if (!json.startsWith('{')) return null;

    final before = text.substring(0, startFence);
    final after = endFence < 0 ? '' : text.substring(endFence + 3);
    final remainder = ('$before\n$after').trim();
    return (json: json, remainder: remainder);
  }

  /// 按段落边界切块，块间留少量重叠，避免要点被切碎
  List<String> _splitText(String text) {
    final chunks = <String>[];
    if (text.isEmpty) return chunks;
    var start = 0;
    while (start < text.length) {
      var end = start + chunkChars;
      if (end >= text.length) {
        chunks.add(text.substring(start));
        break;
      }
      // 尽量在换行/句号处断开，找不到就硬切
      final slice = text.substring(start, end);
      final breakAt = _lastBreak(slice);
      if (breakAt > chunkChars * 0.6) {
        end = start + breakAt + 1;
      }
      if (end <= start) end = start + chunkChars; // 防御：绝不出现空块
      chunks.add(text.substring(start, end));
      final next = end - overlapChars;
      start = next <= start ? end : next;
    }
    return chunks;
  }

  /// 仅用于单元测试：暴露分块逻辑，避免测试依赖私有成员
  @visibleForTesting
  List<String> debugSplitText(String text) => _splitText(text);

  /// 仅用于单元测试：暴露解析逻辑
  @visibleForTesting
  StudySummary debugParseSummary(String raw) =>
      _parseSummary(raw, chunked: false);

  int _lastBreak(String slice) {
    final candidates = [
      slice.lastIndexOf('\n'),
      slice.lastIndexOf('。'),
      slice.lastIndexOf('！'),
      slice.lastIndexOf('？'),
    ];
    return candidates.reduce((a, b) => a > b ? a : b);
  }

  Future<String> _chat(String apiKey, String system, String user) async {
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
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
              ],
              // 详细笔记是长 Markdown，不适合强制 json_object 模式
              'temperature': 0.3,
              'max_tokens': _maxTokens,
            }),
          )
          // 长文生成明显比旧版慢，超时从 90 秒放宽到 180 秒
          .timeout(const Duration(seconds: 180));
    } catch (e) {
      throw AiException('网络请求失败，请检查网络后重试');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AiException('DeepSeek API Key 无效，请到设置里检查',
          needSettings: true, retryable: false);
    }
    if (response.statusCode == 402) {
      throw AiException('DeepSeek 账户余额不足，请充值后再试',
          needSettings: true, retryable: false);
    }
    if (response.statusCode == 429) {
      throw AiException('请求太频繁，请等十几秒再点一次');
    }
    if (response.statusCode == 400) {
      throw AiException('内容过长，服务器拒绝了本次请求，请分段后再试',
          retryable: false);
    }
    if (response.statusCode != 200) {
      // 不把整段原始 JSON 塞进提示（旧版会弹出一整屏乱码）
      throw AiException('总结失败（状态码 ${response.statusCode}），请稍后重试');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final choice = body['choices'][0] as Map<String, dynamic>;
      final content = choice['message']['content'] as String;
      final finish = choice['finish_reason'] as String?;
      if (finish == 'length') {
        // 被截断了：告诉用户，而不是悄悄给半篇
        throw AiException('笔记太长被截断了，请再点一次或把原文分两次总结');
      }
      if (content.trim().isEmpty) {
        throw AiException('AI 返回了空内容，请重试');
      }
      return content;
    } catch (e) {
      if (e is AiException) rethrow;
      throw AiException('返回内容解析失败，请重试');
    }
  }
}