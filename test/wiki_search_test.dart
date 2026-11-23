// test/wiki_search_test.dart
// 维基检索：解析、失败降级、空输入。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/services/wiki_search_service.dart';

void main() {
  test('解析 MediaWiki 返回的页面摘要', () async {
    final svc = WikiSearchService(fetch: (uri) async {
      expect(uri.queryParameters['gsrsearch'], contains('芋头'));
      return jsonEncode({
        'query': {
          'pages': {
            '1': {'title': '芋头', 'extract': '芋头（学名：Colocasia esculenta），天南星科芋属。'},
            '2': {'title': '球茎', 'extract': '球茎是地下变态茎的一种。'},
            '3': {'title': '空条目', 'extract': ''},
          }
        }
      });
    });
    final hits = await svc.search('芋头 球茎');
    expect(hits.length, 2);
    expect(hits.first.title, '芋头');
    expect(hits.first.url, contains('zh.wikipedia.org/wiki/'));
    expect(hits.any((h) => h.title == '空条目'), isFalse);
  });

  test('网络失败返回空列表，不抛异常', () async {
    final svc = WikiSearchService(
        fetch: (uri) async => throw Exception('timeout'));
    expect(await svc.search('芋头'), isEmpty);
  });

  test('空查询不发请求', () async {
    var called = false;
    final svc = WikiSearchService(fetch: (uri) async {
      called = true;
      return '{}';
    });
    expect(await svc.search('   '), isEmpty);
    expect(called, isFalse);
  });

  test('坏 JSON 返回空列表', () async {
    final svc = WikiSearchService(fetch: (uri) async => 'not json');
    expect(await svc.search('芋头'), isEmpty);
  });

  test('摘要超长会截断', () async {
    final long = '芋' * 600;
    final svc = WikiSearchService(fetch: (uri) async => jsonEncode({
          'query': {
            'pages': {
              '1': {'title': '芋头', 'extract': long}
            }
          }
        }));
    final hits = await svc.search('芋头');
    expect(hits.single.extract.length, lessThan(410));
    expect(hits.single.extract.endsWith('…'), isTrue);
  });
}
