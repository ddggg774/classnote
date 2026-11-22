// test/sentence_splitter_test.dart
// 英语切句的纯逻辑测试。
//
// 对照表能不能用，全看这里：缩写被当成句末、引号里的句号提前断开，
// 都会让「原文一行、译文一行」错位。所以边界情况必须逐个钉住。

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/services/sentence_splitter.dart';

void main() {
  group('基本切分', () {
    test('两个句子', () {
      final out = SentenceSplitter.splitEnglish(
        'Plants have cell walls. Leaves capture light.',
      );
      expect(out, ['Plants have cell walls.', 'Leaves capture light.']);
    });

    test('问号与感叹号也是句末', () {
      final out = SentenceSplitter.splitEnglish(
        'Why do leaves fall? Because of abscission!',
      );
      expect(out.length, 2);
      expect(out[0], 'Why do leaves fall?');
      expect(out[1], 'Because of abscission!');
    });

    test('换行是硬边界', () {
      final out = SentenceSplitter.splitEnglish('First line\nSecond line');
      expect(out, ['First line', 'Second line']);
    });

    test('空输入与纯空白', () {
      expect(SentenceSplitter.splitEnglish(''), isEmpty);
      expect(SentenceSplitter.splitEnglish('   \n\t '), isEmpty);
    });
  });

  group('缩写不是句末', () {
    test('Mr. / Dr. / Prof.', () {
      final out = SentenceSplitter.splitEnglish(
        'Mr. Smith met Dr. Lee at the lab. They talked for an hour.',
      );
      expect(out.length, 2);
      expect(out[0], 'Mr. Smith met Dr. Lee at the lab.');
    });

    test('e.g. / i.e. / etc.', () {
      final out = SentenceSplitter.splitEnglish(
        'Use common tools, e.g. a knife and a ruler. Do not use etc. in formal writing.',
      );
      expect(out.length, 2);
      expect(out[0], contains('e.g.'));
    });

    test('图号 Fig.', () {
      final out = SentenceSplitter.splitEnglish(
        'See Fig. 3 for details. The result is clear.',
      );
      expect(out.length, 2);
      expect(out[0], 'See Fig. 3 for details.');
    });

    test('人名首字母 J. K. Rowling', () {
      final out = SentenceSplitter.splitEnglish(
        'The book by J. K. Rowling is popular. Everyone knows it.',
      );
      expect(out.length, 2);
      expect(out[0], contains('J. K. Rowling'));
    });

    test('小数与版本号不被切开', () {
      final out = SentenceSplitter.splitEnglish(
        'The value is 3.14 and the version is v1.2. That is all.',
      );
      expect(out.length, 2);
      expect(out[0], contains('3.14'));
    });
  });

  group('引号与省略号', () {
    test('引号里的句号不提前断句', () {
      final out = SentenceSplitter.splitEnglish(
        'He said "It is fine." Then he left.',
      );
      expect(out.length, 2);
      expect(out[0], 'He said "It is fine."');
      expect(out[1], 'Then he left.');
    });

    test('省略号在句中不断句', () {
      final out = SentenceSplitter.splitEnglish(
        'Well... maybe we should wait. The rain will stop.',
      );
      expect(out.length, 2);
    });

    test('缩写后紧跟引号也不误判', () {
      final out = SentenceSplitter.splitEnglish(
        'She asked Dr. Li "Is it ready?" and waited.',
      );
      expect(out.length, 1);
    });
  });
}