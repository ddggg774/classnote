// lib/services/ai_service.dart
// AI 总结服务：把课堂原文发给 DeepSeek，让它返回结构化要点（JSON）。
// 这是"网络层"：唯一会联网的地方，失败时抛 AiException 由页面展示。
//
// 【长文本处理】
// 两小时的课堂转写有 2–4 万字，一次性塞进 deepseek-chat 会超上下文（400），
// 即使没超，模型也容易只抓开头结尾。所以这里按字数分块：
//   短文本（<= chunkChars）→ 一次调用，行为与旧版完全一致；
//   长文本 → 每块先提要点，再把要点合并成同一套 JSON schema，页面无需改动。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/note.dart';
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

  static const String _systemPrompt =
      '你是一名擅长做课堂笔记的助教。请把学生提供的课堂转写文字总结成思维导图结构。'
      '严格只输出一个 JSON 对象，不要输出任何多余文字或 Markdown 标记，格式如下：\n'
      '{"root":"本课主题(不超过12字)","nodes":['
      '{"topic":"要点1(不超过15字)","children":["子点1","子点2"]},'
      '{"topic":"要点2","children":["子点1"]}]}\n'
      '要求：nodes 为 3~6 个核心要点，每个要点的 children 为 2~4 个简短子点，'
      '内容必须忠实于原文，不要编造原文没有的知识点。';

  static const String _mergePrompt =
      '你会收到一份课堂笔记的若干「分块要点」，来自同一节课的前后不同片段。'
      '请把它们合并成一份完整的思维导图结构，去掉重复、按讲课顺序排列、保留重要细节。'
      '严格只输出一个 JSON 对象，不要输出任何多余文字或 Markdown 标记，格式如下：\n'
      '{"root":"本课主题(不超过12字)","nodes":['
      '{"topic":"要点","children":["子点1","子点2"]}]}\n'
      '要求：nodes 为 4~8 个核心要点，每个要点的 children 为 2~4 个简短子点。';

  /// 调用 DeepSeek 对课堂原文做总结。
  /// 返回结构化思维导图数据；网络/解析失败时抛 [AiException]。
  Future<MindMapData> summarize(String transcript) async {
    final text = transcript.trim();
    if (text.length < 10) {
      throw AiException('内容太短，暂时无法总结', retryable: false);
    }

    final apiKey = await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw AiException('请先在「设置」里填写 DeepSeek API Key', needSettings: true,
          retryable: false);
    }

    if (text.length <= chunkChars) {
      final raw = await _chat(apiKey, _systemPrompt, text);
      return _parseMindMap(raw);
    }

    // 长文本：分块提要点 → 合并
    final chunks = _splitText(text);
    final partials = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final part = await _chat(
        apiKey,
        _systemPrompt,
        '这是本次课堂转写的第 ${i + 1}/${chunks.length} 部分，'
            '请只针对这一部分提炼要点：\n\n${chunks[i]}',
      );
      partials.add(part);
    }

    final merged = await _chat(
      apiKey,
      _mergePrompt,
      partials.map((p) => '【分块要点】\n$p').join('\n\n'),
    );
    final result = _parseMindMap(merged);
    if (result.nodes.isEmpty) {
      // 合并步骤失败时，退回用第一块的结果，至少不是空导图
      return _parseMindMap(partials.first);
    }
    return result;
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
              'response_format': {'type': 'json_object'},
              'temperature': 0.3,
              'max_tokens': 1200,
            }),
          )
          .timeout(const Duration(seconds: 90));
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
    if (response.statusCode != 200) {
      // 不再把整段原始 JSON 塞进提示（旧版会弹出一整屏乱码）
      throw AiException('总结失败（状态码 ${response.statusCode}），请稍后重试');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final content = body['choices'][0]['message']['content'] as String;
      return content;
    } catch (_) {
      throw AiException('返回内容解析失败，请重试');
    }
  }

  /// 解析模型输出。模型偶尔会套 ```json 围栏，先剥掉再解析。
  MindMapData _parseMindMap(String raw) {
    var content = raw.trim();
    if (content.startsWith('```')) {
      final firstNewline = content.indexOf('\n');
      if (firstNewline != -1) content = content.substring(firstNewline + 1);
      if (content.endsWith('```')) {
        content = content.substring(0, content.length - 3);
      }
      content = content.trim();
    }
    try {
      return MindMapData.fromJson(jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      throw AiException('AI 返回的格式不对，请再点一次「重新总结」', retryable: true);
    }
  }
}
