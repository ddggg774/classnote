// lib/services/transcript_corrector.dart
// 转写后处理：用 DeepSeek 修正 ASR 听岔的字词。
//
// 【为什么需要这一步】
// 硅基流动的 /audio/transcriptions 接口只接受 file 和 model 两个字段，
// 没有 hotwords / prompt —— 想靠"热词"提升识别准确率在这条链路上做不到。
// 所以准确率只能从两处补：
//   ① 换模型（SenseVoiceSmall / TeleSpeechASR，在设置页切）；
//   ② 转录完之后用 LLM 按用户的术语表做一次纠错（本文件）。
//
// 【为什么放在"停止录音之后"而不是每段都纠】
// 每段纠错会把首字延迟再拉长、调用次数乘以段数；而纠错本质上需要上下文，
// 整篇一起看效果更好。所以这里做成「一次整篇纠错」，由用户主动点或停止后自动执行。
//
// 【硬约束】
// 只允许改错别字、同音词、标点、分段。不允许改写句子、不允许补充原文没有的信息。
// 这是为了让"纠错"和"总结"在职责上分开，避免用户以为原文被 AI 动了手脚。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'settings_service.dart';

/// 一处纠错记录，用于界面展示"改了什么"
class CorrectionChange {
  final String before;
  final String after;

  const CorrectionChange({required this.before, required this.after});
}

/// 纠错结果
class CorrectionResult {
  /// 修正后的全文（纠错失败时等于原文）
  final String corrected;

  /// 具体改动清单（可能为空：说明模型认为原文没问题）
  final List<CorrectionChange> changes;

  /// 术语表里用到/确认正确的术语数量（用于提示）
  final int glossaryHits;

  const CorrectionResult({
    required this.corrected,
    this.changes = const [],
    this.glossaryHits = 0,
  });

  /// 是否真的改动了内容。
  /// 只看 changes：corrected 非空是"有结果"，不等于"有改动"。
  bool get changed => changes.isNotEmpty;
}

class TranscriptCorrector {
  final SettingsService _settings = SettingsService();

  /// 超过这个字数就分块纠错，避免超上下文
  static const int chunkChars = 6000;

  static const String _systemPrompt = '''
你是一名中文课堂录音转写的校对员。用户会给你一段语音识别出来的文字，
请只修正**明显的识别错误**，把它变成准确可读的文字。

## 允许修改
1. 同音字/近音字听错（如"极限"听成"记线"、"导数"听成"倒树"）。
2. 专业术语、人名、英文缩写的错误写法（按用户提供的术语表优先）。
3. 标点符号、断句、明显的口语重复（"就是就是"）。

## 严禁
1. 不许改写句子结构、不许润色、不许补充原文没有的内容。
2. 不许把口语变成书面语，不许删掉老师说的原话。
3. 拿不准的地方**保持原样**，不要猜。
4. 数字、公式、单位如果看起来可疑但无法确定，保持原样。

## 输出格式（严格 JSON，不要任何多余文字）
{"corrected":"修正后的全文","changes":[{"before":"原文片段","after":"修正后片段"}]}

changes 只列真正改动的地方，每条控制在 20 字以内。没有改动就给空数组。
''';

  /// 纠错主入口。
  /// [text] 原文；[glossary] 术语表（换行分隔）。
  /// 失败时抛 [AiExceptionLike]，由调用方决定是否提示。
  Future<CorrectionResult> correct(String text, {String glossary = ''}) async {
    final trimmed = text.trim();
    if (trimmed.length < 10) {
      return CorrectionResult(corrected: text);
    }

    final apiKey = await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw Exception('请先在「设置」里填写 DeepSeek API Key');
    }

    final terms = glossary
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // 短文本一次搞定
    if (trimmed.length <= chunkChars) {
      return _correctChunk(apiKey, trimmed, terms);
    }

    // 长文本分块：每块独立纠错，然后按原顺序拼回
    final chunks = _split(trimmed);
    final correctedParts = <String>[];
    final allChanges = <CorrectionChange>[];
    for (final chunk in chunks) {
      final r = await _correctChunk(apiKey, chunk, terms);
      correctedParts.add(r.corrected);
      allChanges.addAll(r.changes);
    }
    return CorrectionResult(
      corrected: correctedParts.join('\n'),
      changes: allChanges,
      glossaryHits: terms.length,
    );
  }

  Future<CorrectionResult> _correctChunk(
    String apiKey,
    String chunk,
    List<String> terms,
  ) async {
    final glossaryBlock = terms.isEmpty
        ? '（用户未提供术语表，请只修正非常明显的同音错误）'
        : '以下是本节课的正确术语，请优先按这些写法纠正：\n${terms.map((t) => '- $t').join('\n')}';

    final userMessage = '$glossaryBlock\n\n----- 待校对原文 -----\n$chunk';

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
                {'role': 'system', 'content': _systemPrompt},
                {'role': 'user', 'content': userMessage},
              ],
              'response_format': {'type': 'json_object'},
              // 纠错要保守，温度压低
              'temperature': 0.1,
              'max_tokens': 8000,
            }),
          )
          .timeout(const Duration(seconds: 120));
    } catch (_) {
      throw Exception('网络请求失败，纠错未完成');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('DeepSeek API Key 无效，请到设置里检查');
    }
    if (response.statusCode == 402) {
      throw Exception('DeepSeek 账户余额不足');
    }
    if (response.statusCode != 200) {
      throw Exception('纠错失败（状态码 ${response.statusCode}）');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final content = body['choices'][0]['message']['content'] as String;
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final corrected = (decoded['corrected'] as String?)?.trim() ?? '';
      if (corrected.isEmpty) {
        // 模型没给正文时保留原文，宁可不改也不丢内容
        return CorrectionResult(corrected: chunk, glossaryHits: terms.length);
      }
      final rawChanges = (decoded['changes'] as List?) ?? [];
      final changes = rawChanges
          .whereType<Map<String, dynamic>>()
          .map((m) => CorrectionChange(
                before: (m['before'] ?? '').toString(),
                after: (m['after'] ?? '').toString(),
              ))
          .where((c) => c.before.isNotEmpty || c.after.isNotEmpty)
          .toList();
      return CorrectionResult(
        corrected: corrected,
        changes: changes,
        glossaryHits: terms.length,
      );
    } catch (_) {
      throw Exception('纠错结果解析失败，原文未改动');
    }
  }

  /// 按行切块，尽量在换行处断开
  List<String> _split(String text) {
    final chunks = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = start + chunkChars;
      if (end >= text.length) {
        chunks.add(text.substring(start));
        break;
      }
      final slice = text.substring(start, end);
      final nl = slice.lastIndexOf('\n');
      if (nl > chunkChars * 0.5) {
        end = start + nl + 1;
      }
      chunks.add(text.substring(start, end));
      start = end;
    }
    return chunks;
  }

  /// 仅用于测试
  List<String> debugSplit(String text) => _split(text);
}