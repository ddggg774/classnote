// test/local_vector_test.dart
// 本地向量：embedding 归一化、余弦排序、阈值过滤。
//
// 它不是语义模型，测的是「字面相关能不能排前面」和「不相关别硬塞」，
// 别把同义改写的期望写进用例。

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/services/local_vector.dart';

void main() {
  test('embedding 归一化且确定性', () {
    final a = LocalEmbedder.embed('芋头是地下球茎');
    final b = LocalEmbedder.embed('芋头是地下球茎');
    expect(a, b);
    var norm = 0.0;
    for (final v in a) {
      norm += v * v;
    }
    expect(norm, closeTo(1.0, 1e-6));
  });

  test('相同文本余弦为 1，不相关明显更低', () {
    final a = LocalEmbedder.embed('芋头是典型的地下球茎');
    final same = LocalEmbedder.embed('芋头是典型的地下球茎');
    final other = LocalEmbedder.embed('时间复杂度是 O(n log n)');
    expect(LocalEmbedder.cosine(a, same), closeTo(1.0, 1e-6));
    expect(LocalEmbedder.cosine(a, other), lessThan(0.2));
  });

  test('检索把相关条目排前面', () {
    final index = EvidenceIndex.build(const [
      VectorDoc('芋头：地下变态茎中的球茎，具环状节和退化叶', source: '知识库'),
      VectorDoc('红掌：天南星科，花序外包被佛焰苞', source: '知识库'),
      VectorDoc('时间复杂度：快速排序平均 O(n log n)', source: '课堂笔记'),
    ]);
    final hits = index.search('芋头属于球茎还是块茎', k: 2);
    expect(hits, isNotEmpty);
    expect(hits.first.doc.text, contains('芋头'));
  });

  test('低于阈值不返回，空索引不炸', () {
    final index = EvidenceIndex.build(const [
      VectorDoc('红掌：天南星科，花序外包被佛焰苞'),
    ]);
    expect(index.search('薛定谔方程'), isEmpty);
    expect(EvidenceIndex.build(const []).search('任意'), isEmpty);
  });

  test('只共享单字、不共享二字组的文本不会被当依据', () {
    final index = EvidenceIndex.build(const [
      VectorDoc('红掌：天南星科，花序外包被佛焰苞', source: '知识库'),
    ]);
    expect(index.search('芋头属于球茎还是块茎'), isEmpty);
  });
}