// test/search_index_test.dart
// 检索的纯逻辑测试（不需要数据库、不调 API）。
//
// 这里盯的是三处最容易错的地方：
//   ① 中文 bigram 切得对不对——切错了召回率直接崩
//   ② 单字查询的兜底路径——切不出 bigram 时不能返回空
//   ③ 高亮定位——错一位用户就跳到错的地方
// 索引读写与 SQL 查询放 search_index_db_test.dart（需要 sqflite）。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/services/search_index.dart';

void main() {
  group('中文 bigram 切词', () {
    test('三字词切成两个 bigram', () {
      final terms = SearchIndex.tokenize('木兰科');
      expect(terms, containsAll(['木兰', '兰科']));
      expect(terms.length, 2);
    });

    test('四字术语切成三个 bigram', () {
      final terms = SearchIndex.tokenize('离生心皮');
      expect(terms, containsAll(['离生', '生心', '心皮']));
    });

    test('「离生心皮」与「离心皮」共享 bigram（这是 bigram 的价值）', () {
      final a = SearchIndex.tokenize('离生心皮').toSet();
      final b = SearchIndex.tokenize('离心皮').toSet();
      expect(a.intersection(b), contains('心皮'),
          reason: '共享 bigram 才能让误听变体被召回');
    });

    test('单字保留 unigram，否则「叶」查不到', () {
      expect(SearchIndex.tokenize('叶'), contains('叶'));
    });

    test('句子里的多个词组都被切到', () {
      final terms = SearchIndex.tokenize('木兰科的心皮');
      expect(terms, containsAll(['木兰', '兰科', '心皮']));
    });

    test('标点与空白被丢弃', () {
      final terms = SearchIndex.tokenize('木兰科，心皮。');
      expect(terms.every((t) => !t.contains('，') && !t.contains('。')), isTrue);
    });

    test('空串返回空列表', () {
      expect(SearchIndex.tokenize(''), isEmpty);
      expect(SearchIndex.tokenize('   '), isEmpty);
    });

    test('纯符号返回空列表', () {
      expect(SearchIndex.tokenize('，。！？'), isEmpty);
    });
  });

  group('英文与数字切词', () {
    test('整词小写', () {
      expect(SearchIndex.tokenize('Magnolia'), contains('magnolia'));
    });

    test('长词额外生成前缀，便于部分匹配', () {
      final terms = SearchIndex.tokenize('pathname');
      expect(terms, contains('pathname'));
      expect(terms, contains('pat'));
      expect(terms, contains('path'));
    });

    test('短词不加前缀（避免噪音）', () {
      final terms = SearchIndex.tokenize('ab');
      expect(terms, contains('ab'));
      expect(terms.length, 1);
    });

    test('数字被索引', () {
      expect(SearchIndex.tokenize('420'), contains('420'));
    });

    test('中西混排各自切', () {
      final terms = SearchIndex.tokenize('木兰科 Magnolia');
      expect(terms, containsAll(['木兰', '兰科', 'magnolia']));
    });
  });

  group('查询串切词', () {
    test('与文档切词规则一致', () {
      expect(SearchIndex.tokenizeQuery('木兰科'),
          SearchIndex.tokenize('木兰科'));
    });

    test('空查询返回空', () {
      expect(SearchIndex.tokenizeQuery(''), isEmpty);
      expect(SearchIndex.tokenizeQuery('  '), isEmpty);
    });

    test('单字查询能切出内容（走兜底路径的判断依据）', () {
      expect(SearchIndex.tokenizeQuery('叶'), isNotEmpty);
    });
  });

  group('字段权重', () {
    test('标题 > 总结 > 原文', () {
      expect(IndexField.weightOf(IndexField.title), 3);
      expect(IndexField.weightOf(IndexField.summary), 2);
      expect(IndexField.weightOf(IndexField.transcript), 1);
    });

    test('未知字段按原文权重处理，不抛异常', () {
      expect(IndexField.weightOf('nonsense'), 1);
    });
  });

  group('高亮定位', () {
    const text = '今天我们讲被子植物的木兰科。木兰科它是原始被子植物的代表类群。'
        '大家看这个 Magnolia denudata，就是白玉兰。';

    test('能定位到词并截取上下文', () {
      final r = SearchIndex.locate(text, '木兰科');
      expect(r.position, greaterThanOrEqualTo(0));
      expect(r.snippet.contains('木兰科'), isTrue);
    });

    test('定位到的位置真的指向那个词', () {
      final r = SearchIndex.locate(text, '白玉兰');
      expect(r.position, greaterThan(0));
      expect(text.substring(r.position, r.position + 3), '白玉兰');
    });

    test('找不到时 position 为 -1，但仍给开头摘要', () {
      final r = SearchIndex.locate(text, '量子力学');
      expect(r.position, -1);
      expect(r.snippet, isNotEmpty);
    });

    test('前后都有省略号（截取的是中间段）', () {
      final r = SearchIndex.locate(text, '木兰科', contextChars: 5);
      expect(r.snippet.startsWith('…'), isTrue);
      expect(r.snippet.endsWith('…'), isTrue);
    });

    test('命中在开头时不加前省略号', () {
      final r = SearchIndex.locate('木兰科是重点', '木兰科', contextChars: 10);
      expect(r.snippet.startsWith('…'), isFalse);
    });

    test('命中在结尾时不加后省略号', () {
      final r = SearchIndex.locate('重点是木兰科', '木兰科', contextChars: 10);
      expect(r.snippet.endsWith('…'), isFalse);
    });

    test('多词查询优先用最长的那段', () {
      // 用一段真的同时含「的」和「心皮」的文本，
      // 否则测的是"找不到最长词就退回短词"的降级行为，不是优先级本身
      const t = '这个的离生心皮的排列方式要记住。';
      final r = SearchIndex.locate(t, '的 心皮', contextChars: 3);
      expect(r.position, greaterThanOrEqualTo(0));
      expect(t.substring(r.position, r.position + 2), '心皮',
          reason: '应优先定位较长的关键词「心皮」而不是「的」');
    });

    test('最长词确实不存在时才退回次长词', () {
      // text 里没有「心皮」，只有「的」
      final r = SearchIndex.locate(text, '的 心皮', contextChars: 3);
      expect(r.position, greaterThanOrEqualTo(0));
      expect(text.substring(r.position, r.position + 1), '的');
    });

    test('空原文返回空片段不崩', () {
      final r = SearchIndex.locate('', '木兰科');
      expect(r.position, -1);
      expect(r.snippet, isEmpty);
    });

    test('空查询返回原文开头', () {
      final r = SearchIndex.locate(text, '');
      expect(r.position, -1);
      expect(r.snippet, isNotEmpty);
    });

    test('超长原文不崩（截取而非全量返回）', () {
      // 用变量拼而非字符串相加，既避开 lint 也更清楚
      final before = '前缀' * 500;
      final after = '后缀' * 500;
      final long = '$before木兰科$after';
      final r = SearchIndex.locate(long, '木兰科');
      expect(r.position, greaterThan(0));
      expect(r.snippet.length, lessThan(long.length));
    });
  });

  group('常量约束', () {
    test('单条笔记索引上限存在且合理', () {
      expect(SearchIndex.maxTermsPerField, greaterThan(1000));
      expect(SearchIndex.maxTermsPerField, lessThanOrEqualTo(10000));
    });

    test('short query 阈值是 2', () {
      expect(SearchIndex.minBigramQueryLength, 2);
    });
  });
}