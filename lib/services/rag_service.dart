// lib/services/rag_service.dart
// 跨笔记问答：把检索到的片段拼成上下文，让模型只根据这些片段回答。
//
// 【为什么必须强制标出处】
// 跨笔记归纳最容易出的问题不是"答不出"，而是"把两节课的内容混着说成老师讲过的"。
// 一旦答案带着 [笔记标题] 出处，用户能点回去核对，编造就藏不住。
// 提示词里把这条写成硬性要求，而不是"建议"。
//
// 【为什么找不到了要说找不到】
// 检索为空或片段无关时，模型倾向于用常识脑补。这个场景下"不知道"才是正确答案。
// 所以明确要求：片段里没有的信息，直接说「笔记里没提到」，不许拿一般知识补。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'search_index.dart';

/// RAG 结果
class RagAnswer {
  final String text;

  /// 实际喂给模型的片段条数
  final int contextCount;

  /// 是否因为检索为空而走了「找不到」路径（没调模型）
  final bool noContext;

  const RagAnswer({
    required this.text,
    required this.contextCount,
    this.noContext = false,
  });
}

class RagService {
  /// 单次问答最多塞多少条片段进上下文。
  /// 太多会稀释重点、也更容易让模型把不同笔记混起来说。
  static const int maxContextHits = 6;

  /// 每条片段最多截取多少字（原文可能很长，全塞进去会爆上下文）
  static const int maxSnippetChars = 1200;

  RagService();

  static const String systemPrompt = '''
你是课堂笔记的检索助手。用户会问一个关于他这学期课程的问题，
你会收到从他自己笔记里检索出来的若干片段。

## 铁律（违反即不合格）
1. **只能根据给你的片段回答**。片段里没有的内容，一律不许补，
   包括你自认为正确的学科常识——用户要的是"他笔记里怎么记的"，
   不是你的一般知识。
2. **每条结论后面必须标出处**，格式：[笔记标题]
   例：木兰科是原始被子植物 [植物学第三讲]
3. **如果片段里找不到答案**，直接回答「笔记里没提到这个问题」，
   并说明检索到了哪些相关内容。**不要**换个角度硬答。
4. 片段之间如果说法冲突（比如两节课记的定义不一样），
   **两个都说，并各自标出处**，不要替用户裁定哪个对。
5. 不要写"根据我的分析"这类套话，直接给结论。

## 输出格式
- 先用一两句话直接回答问题
- 需要展开时用短列表，每条带出处
- 如果引用原文，用「」括起来
- 控制在 300 字以内，除非用户明确要求详细
''';

  /// 回答一个问题。
  ///
  /// [hits] 是检索结果；[transcriptLoader] 用来按 noteId 取原文，
  /// 这样 RagService 不直接依赖数据库，方便测试。
  Future<RagAnswer> answer({
    required String question,
    required List<SearchHit> hits,
    required Future<String> Function(String noteId) transcriptLoader,
    required String apiKey,
    String? baseUrlOverride,
    http.Client? httpClient,
  }) async {
    // 检索为空：直接告诉用户找不到，不调模型（省钱且不编造）
    if (hits.isEmpty) {
      return const RagAnswer(
        text: '笔记里没提到这个问题。\n\n可以换个说法再搜，或者先录一节相关的课。',
        contextCount: 0,
        noContext: true,
      );
    }

    // 取 top-N 片段的原文，拼成上下文
    final picked = hits.take(maxContextHits).toList();
    final ctx = StringBuffer();
    for (var i = 0; i < picked.length; i++) {
      final hit = picked[i];
      final full = await transcriptLoader(hit.noteId);
      final body = _excerpt(full, question, hit.position);
      if (body.trim().isEmpty) continue;
      ctx
        ..writeln('【片段 ${i + 1}】')
        ..writeln('笔记标题：${hit.title}')
        ..writeln('课程：${hit.course}')
        ..writeln('原文摘录：')
        ..writeln(body)
        ..writeln();
    }

    if (ctx.isEmpty) {
      return const RagAnswer(
        text: '笔记里没提到这个问题。',
        contextCount: 0,
        noContext: true,
      );
    }

    final userContent = '问题：$question\n\n'
        '以下是从用户笔记里检索到的片段：\n\n$ctx';

    final text = await _chat(
      apiKey: apiKey,
      system: systemPrompt,
      user: userContent,
      baseUrlOverride: baseUrlOverride,
      httpClient: httpClient,
    );

    return RagAnswer(text: text, contextCount: picked.length);
  }

  /// 从原文里取一段够用的摘录。
  /// 有命中位置就以它为中心截取，否则取开头。
  static String _excerpt(String full, String question, int position) {
    if (full.isEmpty) return '';
    if (full.length <= maxSnippetChars) return full;

    final center = position >= 0 ? position : 0;
    const half = maxSnippetChars ~/ 2;
    final start = (center - half).clamp(0, full.length - maxSnippetChars);
    final end = (start + maxSnippetChars).clamp(0, full.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < full.length ? '…' : '';
    return '$prefix${full.substring(start, end)}$suffix';
  }

  Future<String> _chat({
    required String apiKey,
    required String system,
    required String user,
    String? baseUrlOverride,
    http.Client? httpClient,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      final request = http.Request(
        'POST',
        Uri.parse(baseUrlOverride ?? AppConfig.deepSeekBaseUrl),
      )
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = jsonEncode({
          'model': AppConfig.deepSeekModel,
          'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
          // 检索问答要稳，不要发挥
          'temperature': 0.2,
          'max_tokens': 1500,
        });

      final streamed =
          await client.send(request).timeout(const Duration(seconds: 120));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception('API Key 无效');
      }
      if (response.statusCode == 402) {
        throw Exception('账户余额不足');
      }
      if (response.statusCode != 200) {
        throw Exception('请求失败（${response.statusCode}）');
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw Exception('模型没有返回内容');
      }
      final message = (choices.first as Map)['message'] as Map?;
      final content = (message?['content'] as String?)?.trim() ?? '';
      if (content.isEmpty) {
        throw Exception('模型返回了空回答');
      }
      return content;
    } finally {
      if (httpClient == null) client.close();
    }
  }
}