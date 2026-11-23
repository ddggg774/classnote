// lib/services/wiki_search_service.dart
// 质检用的「先搜后判」检索：中文维基百科（MediaWiki API）。
//
// 为什么是维基：有官方 API、返回可引用的正文片段、不需要 Key。
// 隐私：检索只发送「待查的术语/短句」，不发送整篇笔记；是否启用由设置开关控制，
// 免责声明 v1.1 已写明这一点。
//
// 网络现实：中国大陆多数网络直连 zh.wikipedia.org 会超时。这里不重试、不绕过，
// 超时/失败一律返回空列表，质检自动退化为「无外部依据」并在 summary 注明。
import 'dart:convert';

import 'package:http/http.dart' as http;

class WikiSnippet {
  final String title;
  final String extract;
  final String url;

  const WikiSnippet({
    required this.title,
    required this.extract,
    required this.url,
  });
}

class WikiSearchService {
  /// 测试注入：给定 Uri 返回响应体
  final Future<String> Function(Uri uri)? fetch;

  final Duration timeout;

  WikiSearchService({this.fetch, this.timeout = const Duration(seconds: 10)});

  static const String _endpoint = 'https://zh.wikipedia.org/w/api.php';

  /// 查询串长度上限：整句太长会稀释检索结果，截到 60 字
  static const int maxQueryChars = 60;

  Future<List<WikiSnippet>> search(String query, {int limit = 2}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final clipped =
        q.length > maxQueryChars ? q.substring(0, maxQueryChars) : q;

    final uri = Uri.parse(_endpoint).replace(queryParameters: {
      'action': 'query',
      'generator': 'search',
      'gsrsearch': clipped,
      'gsrlimit': '$limit',
      'prop': 'extracts',
      'exintro': '1',
      'explaintext': '1',
      'exlimit': 'max',
      'format': 'json',
      'utf8': '1',
      'origin': '*',
    });

    late final String body;
    try {
      body = await (fetch != null
          ? fetch!(uri)
          : http.get(uri).then((r) => r.body).timeout(timeout));
    } catch (_) {
      return const [];
    }

    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return const [];
      final pages = decoded['query']?['pages'];
      if (pages is! Map) return const [];

      final out = <WikiSnippet>[];
      for (final p in pages.values) {
        if (p is! Map) continue;
        final title = (p['title'] ?? '').toString().trim();
        final extract = (p['extract'] ?? '').toString().trim();
        if (title.isEmpty || extract.isEmpty) continue;
        out.add(WikiSnippet(
          title: title,
          extract: extract.length > 400
              ? '${extract.substring(0, 400)}…'
              : extract,
          url: 'https://zh.wikipedia.org/wiki/'
              '${Uri.encodeComponent(title)}',
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}