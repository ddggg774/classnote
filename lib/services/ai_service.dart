// lib/services/ai_service.dart
// AI 总结服务：把课堂原文发给 DeepSeek，让它返回结构化要点（JSON）。
// 这是"网络层"：唯一会联网的地方，失败时抛异常由页面处理。
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/note.dart';
import 'settings_service.dart';

class AiService {
  final SettingsService _settings = SettingsService();

  /// 调用 DeepSeek 对课堂原文做总结。
  /// 返回结构化思维导图数据；网络/解析失败时抛异常。
  Future<MindMapData> summarize(String transcript) async {
    // 防呆：原文太短没必要总结
    if (transcript.trim().length < 10) {
      throw Exception('内容太短，暂时无法总结');
    }

    // 从本地读取用户填写的 API Key；未配置则提示去设置
    final apiKey = await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw Exception('请先在「设置」里填写 DeepSeek API Key');
    }

    // system 提示词：规定 AI 只能输出指定 JSON 结构，方便直接渲染思维导图
    const systemPrompt =
        '你是一名擅长做课堂笔记的助教。请把学生提供的课堂转写文字总结成思维导图结构。'
        '严格只输出一个 JSON 对象，不要输出任何多余文字或 Markdown 标记，格式如下：\n'
        '{"root":"本课主题(不超过12字)","nodes":['
        '{"topic":"要点1(不超过15字)","children":["子点1","子点2"]},'
        '{"topic":"要点2","children":["子点1"]}]}\n'
        '要求：nodes 为 3~6 个核心要点，每个要点的 children 为 2~4 个简短子点，'
        '内容必须忠实于原文，不要编造原文没有的知识点。';

    late final http.Response response;
    try {
      response = await http.post(
        Uri.parse(AppConfig.deepSeekBaseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': AppConfig.deepSeekModel,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': transcript},
          ],
          'response_format': {'type': 'json_object'},
          'temperature': 0.3,
        }),
      ).timeout(const Duration(seconds: 60));
    } catch (e) {
      throw Exception('网络请求失败，请检查网络后重试：$e');
    }

    if (response.statusCode != 200) {
      // 常见 401：Key 错误；402：余额不足；429：请求过快
      throw Exception('总结失败（状态码 ${response.statusCode}）：${response.body}');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final content = body['choices'][0]['message']['content'] as String;
      final data = jsonDecode(content) as Map<String, dynamic>;
      return MindMapData.fromJson(data);
    } catch (e) {
      throw Exception('解析总结结果失败：$e');
    }
  }
}
