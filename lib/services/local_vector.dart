// lib/services/local_vector.dart
// 本地向量检索：不依赖网络、不依赖第三方 embedding 服务。
//
// 为什么是本地字符向量而不是语义模型：
//   · App 的数据隐私承诺是「正文不出本机」，把笔记送去外部 embedding 服务就破了这条；
//   · 教材正文目前只有目录，没有足够语料训/调一个语义模型；
//   · 质检要的是「找到最相关的几句原文当依据」，字符 n-gram 在这个规模下够用。
//
// 局限（必须承认）：它抓的是字面重叠，同义改写（「块茎」vs「地下茎」）抓不到。
// 以后要接 bge-m3 之类，只需替换 LocalEmbedder.embed 的实现，索引与检索不用动。

import 'dart:math' as math;

/// 一条可被检索的文本（知识库词条 / 笔记句子 / 教材段落）
class VectorDoc {
  final String text;
  final String source;
  final String course;

  const VectorDoc(this.text, {this.source = '知识库', this.course = ''});
}

class LocalEmbedder {
  const LocalEmbedder._();

  static const int dim = 512;

  /// 字符 n-gram 哈希到固定维度，再做 L2 归一化。
  /// 归一化后余弦相似度 = 点积，检索时省一次开方。
  static List<double> embed(String text) {
    final vec = List<double>.filled(dim, 0);
    final clean = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'''[.,!?;:'"“”‘’()\[\]{}<>、，。；：！？…—\-·]'''), '');
    if (clean.isEmpty) return vec;

    void add(String gram, double weight) {
      // 有符号哈希：不同 gram 撞进同一维时正负相消，
      // 避免无关文本因碰撞累积出虚假相似度
      final h = _hash(gram);
      final idx = h % dim;
      final sign = ((h >> 16) & 1) == 1 ? -1.0 : 1.0;
      vec[idx] += weight * sign;
    }

    for (var i = 0; i < clean.length; i++) {
      add(clean[i], 0.2);
      if (i + 1 < clean.length) add(clean.substring(i, i + 2), 0.6);
      if (i + 2 < clean.length) add(clean.substring(i, i + 3), 1.0);
    }

    var norm = 0.0;
    for (final v in vec) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm == 0) return vec;
    return [for (final v in vec) v / norm];
  }

  static double cosine(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  /// FNV-1a 32 位，足够把 n-gram 均匀撒到 512 维
  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}

/// 内存索引。语料规模按「一门课几十条词条 + 几百句笔记」设计，
/// 全量线性扫描足够快（几百次点积），不值得引入 HNSW。
class EvidenceIndex {
  final List<VectorDoc> docs;
  final List<List<double>> vectors;

  const EvidenceIndex._(this.docs, this.vectors);

  bool get isEmpty => docs.isEmpty;

  factory EvidenceIndex.build(List<VectorDoc> docs) {
    final vectors = [for (final d in docs) LocalEmbedder.embed(d.text)];
    return EvidenceIndex._(docs, vectors);
  }

  /// 返回最相关的 [k] 条，低于 [minScore] 的不返回。
  List<({VectorDoc doc, double score})> search(
    String query, {
    int k = 3,
    double minScore = 0.03,
  }) {
    if (docs.isEmpty || query.trim().isEmpty) return const [];
    final q = LocalEmbedder.embed(query);
    final scored = <({VectorDoc doc, double score})>[];
    for (var i = 0; i < docs.length; i++) {
      final s = LocalEmbedder.cosine(q, vectors[i]);
      // 低阈值 + 二字组守卫：碰撞出来的虚假相似度不再靠阈值兜，
      // 而是要求两边确实共享至少一个二字组
      if (s >= minScore && _sharesBigram(query, docs[i].text)) {
        scored.add((doc: docs[i], score: s));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(k).toList();
  }
}

bool _sharesBigram(String query, String doc) {
  final a = query.replaceAll(RegExp(r'\s+'), '');
  final b = doc.replaceAll(RegExp(r'\s+'), '');
  if (a.isEmpty || b.isEmpty) return false;
  if (a.length < 2) return b.contains(a);
  final grams = <String>{};
  for (var i = 0; i + 2 <= b.length; i++) {
    grams.add(b.substring(i, i + 2));
  }
  for (var i = 0; i + 2 <= a.length; i++) {
    if (grams.contains(a.substring(i, i + 2))) return true;
  }
  return false;
}
