// lib/services/toc_structurer.dart
// 目录结构化：正则搞不定时，让模型把用户粘贴的文字重排成 JSON。
//
// 【它只做重排，不做记忆】
// 模型没有这本教材的目录，让它「补全」等于编造章节号。所以提示词里写死
// 「一个字都不许改、不许补」，返回后还要过 TocParser.fromModelJson 的行级校验：
// 每个 no/title 去掉标点空白后必须能在用户原文里找到，找不到整条丢弃。
//
// 这一层只是「正则的兜底」，不是主路径。用户主动点按钮才会花钱。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'settings_service.dart';
import 'toc_parser.dart';

class TocStructurer {
  final String? apiKeyOverride;

  TocStructurer({this.apiKeyOverride});

  /// 目录文本超过这个长度就截断：整本目录再长也够用了，
  /// 而超长输入既费钱又容易让模型开始「总结」。
  static const int maxInputChars = 4000;

  static const String _systemPrompt = '''
你是教材目录的排版助手。用户给你一段目录文字，你只做一件事：
把它的层次重排成 JSON。

## 铁律（违反即视为错误输出）
1. 绝对不许新增章节：no 与 title 必须逐字来自用户输入，
   一个字都不许改、不许补、不许把两行合并成一行。
2. 原文里没有出现的章节号，绝对不许写出来。
3. 「（一）」「1)」这类第三级条目不要提升为章或节——本 App 只有章/节两层，
   遇到就忽略。
4. 认不出来就少输出，不要猜。宁可返回空 chapters，也不要编。
5. 只输出 JSON，不要解释文字、不要 Markdown 围栏。

## 输出结构
{"chapters":[{"no":"第五章","title":"被子植物",
  "sections":[{"no":"第一节","title":"木兰科"}]}]}

no 为空时用空字符串（例如「附录」「参考文献」这类无编号节点）。
''';

  /// 返回校验通过的结构；模型编造的内容会被丢弃，返回 null 表示完全不可用。
  /// 失败抛 Exception（没 Key / 网络失败 / 状态码异常）。
  Future<TocData?> structure({required String rawText}) async {
    final text = rawText.trim();
    if (text.isEmpty) return null;

    final apiKey = apiKeyOverride ?? await SettingsService().getApiKey();
    if (apiKey.isEmpty) {
      throw Exception('请先在「设置」里填写 DeepSeek API Key');
    }

    final input = text.length > maxInputChars
        ? text.substring(0, maxInputChars)
        : text;

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
                {'role': 'user', 'content': input},
              ],
              'response_format': {'type': 'json_object'},
              'temperature': 0,
              'max_tokens': 4000,
            }),
          )
          .timeout(const Duration(seconds: 90));
    } catch (_) {
      throw Exception('网络请求失败，目录未整理');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('DeepSeek API Key 无效，请到设置里检查');
    }
    if (response.statusCode == 402) {
      throw Exception('DeepSeek 账户余额不足');
    }
    if (response.statusCode != 200) {
      throw Exception('目录整理失败（状态码 ${response.statusCode}）');
    }

    String content;
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      content = body['choices'][0]['message']['content'] as String;
    } catch (_) {
      throw Exception('模型返回格式异常，改用正则结果');
    }

    // 行级校验：编造的章节在这里被挡掉，不会进数据库
    return TocParser.fromModelJson(content, text);
  }
}