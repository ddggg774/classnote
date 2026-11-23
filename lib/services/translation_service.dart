// lib/services/translation_service.dart
// 英语课逐句翻译：切句 → 逐句翻 → 校验 → 存成可对照的 pairs。
//
// 【为什么不直接整段翻译】
// 整段翻译模型一定会合并/拆分句子，对照就废了。这里要求一句一行，
// 拿到结果后**程序校验句数、并回查每句原文**，对不上就重试一次，
// 再对不上就降级成整段翻译并标「无法逐句对照」。
// 这是唯一能自动发现「模型擅自合并/编造」的办法，比在提示词里写"请忠实"可靠。
import 'dart:convert';

import 'ai_service.dart';
import 'sentence_splitter.dart';

/// 一句原文 + 一句译文
class TranslationPair {
  final int index;
  final String source;
  final String target;

  const TranslationPair({
    required this.index,
    required this.source,
    required this.target,
  });

  Map<String, dynamic> toJson() => {
        'i': index,
        'src': source,
        'dst': target,
      };

  factory TranslationPair.fromJson(Map<String, dynamic> json) {
    return TranslationPair(
      index: (json['i'] as num?)?.toInt() ?? 0,
      source: (json['src'] ?? '').toString(),
      target: (json['dst'] ?? '').toString(),
    );
  }
}

/// 一次翻译的完整结果，序列化后存进 notes.translation_json
class TranslationResult {
  final String sourceLang;
  final String targetLang;

  /// per-sentence（可逐句对照） / whole（整段降级，无法对照）
  final String mode;
  final List<TranslationPair> pairs;
  final DateTime createdAt;

  const TranslationResult({
    required this.sourceLang,
    required this.targetLang,
    required this.mode,
    required this.pairs,
    required this.createdAt,
  });

  bool get isPerSentence => mode == 'per-sentence';

  String encode() => jsonEncode({
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'mode': mode,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'pairs': pairs.map((p) => p.toJson()).toList(),
      });

  static TranslationResult? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map['pairs'] as List?) ?? const [];
      final pairs = list
          .whereType<Map<String, dynamic>>()
          .map(TranslationPair.fromJson)
          .toList();
      if (pairs.isEmpty) return null;
      final created = (map['createdAt'] as num?)?.toInt();
      return TranslationResult(
        sourceLang: (map['sourceLang'] ?? 'en').toString(),
        targetLang: (map['targetLang'] ?? 'zh').toString(),
        mode: (map['mode'] ?? 'per-sentence').toString(),
        pairs: pairs,
        createdAt: created == null
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : DateTime.fromMillisecondsSinceEpoch(created),
      );
    } catch (_) {
      return null;
    }
  }
}

class TranslationService {
  final AiService _ai;

  /// [ai] 仅测试用：注入一个假的模型客户端，避免真花钱。
  TranslationService({String? apiKeyOverride, AiService? ai})
      : _ai = ai ?? AiService(apiKeyOverride: apiKeyOverride);

  /// 单次送去翻译的最大字数：再长就分批（按句切），避免一次请求过大。
  static const int maxCharsPerRequest = 6000;

  static const String _systemPrompt = '''
你是课堂笔记的逐句翻译器。用户给你若干编号的英文句子，你逐条翻译成简体中文。

## 铁律
1. 只翻译，不许增、不许删、不许合并、不许拆分、不许解释、不许总结。
2. 输出条数必须与输入条数完全一致，i 从 1 开始连续编号。
3. `dst` 只放中文译文，不要重复原文，不要加引号或前后缀。
4. 专业术语第一次出现时译成「中文（English）」，例如：细胞壁（cell wall）。
5. 专有名词、书名、人名保留原文，不要音译成中文。
6. 听不清或无法理解的句子，`dst` 写「〔无法翻译〕」，不要猜。
7. 只输出 JSON，不要 Markdown 围栏、不要任何解释文字。

## 输出结构
{"pairs":[{"i":1,"src":"原句","dst":"译文"}]}
''';

  static const String _wholeSystemPrompt = '''
你是课堂笔记翻译器。把用户给的一整段英文转写成简体中文，保持原来的段落与顺序。
只翻译，不许增删、不许总结、不许解释。专业术语写「中文（English）」。
只输出译文本身。
''';

  /// 翻译整段文本。失败抛 Exception。
  Future<TranslationResult> translate({
    required String text,
    required String sourceLang,
    String targetLang = 'zh',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw Exception('没有可翻译的内容');
    }

    final sentences = SentenceSplitter.splitEnglish(trimmed);
    if (sentences.isEmpty) {
      throw Exception('没有切出可翻译的句子');
    }

    // 超长时按句分批，但对照表仍然是一整份
    final batches = _batch(sentences);
    final pairs = <TranslationPair>[];
    var index = 1;

    for (final batch in batches) {
      final batchPairs = await _translateBatch(batch, startIndex: index);
      if (batchPairs == null) {
        // 短文本保持旧行为（整段降级）；长文本不再把整篇塞进一次请求，
        // 否则必然超长被截断，译出来的东西还不报错。
        if (trimmed.length <= maxCharsPerRequest) {
          return _translateWhole(trimmed, sourceLang, targetLang);
        }
        final whole = await _translateWhole(
          batch.join('\n'),
          sourceLang,
          targetLang,
        );
        pairs.addAll(whole.pairs);
        index += batch.length;
        continue;
      }
      pairs.addAll(batchPairs);
      index += batch.length;
    }

    // 全量再校验一次：条数必须对得上，对不上就报错，不能拿残缺译文充数
    if (pairs.length != sentences.length) {
      if (trimmed.length <= maxCharsPerRequest) {
        return _translateWhole(trimmed, sourceLang, targetLang);
      }
      throw Exception('译文条数与原文不一致（${pairs.length}/${sentences.length}），请重试');
    }

    return TranslationResult(
      sourceLang: sourceLang,
      targetLang: targetLang,
      mode: 'per-sentence',
      pairs: pairs,
      createdAt: DateTime.now(),
    );
  }

  List<List<String>> _batch(List<String> sentences) {
    final out = <List<String>>[];
    var current = <String>[];
    var chars = 0;
    for (final s in sentences) {
      if (current.isNotEmpty && chars + s.length > maxCharsPerRequest) {
        out.add(current);
        current = <String>[];
        chars = 0;
      }
      current.add(s);
      chars += s.length;
    }
    if (current.isNotEmpty) out.add(current);
    return out;
  }

  /// 一次逐句翻译。返回 null 表示两次都没通过校验。
  Future<List<TranslationPair>?> _translateBatch(
    List<String> sentences, {
    required int startIndex,
  }) async {
    final user = StringBuffer();
    for (var i = 0; i < sentences.length; i++) {
      user.writeln('${startIndex + i}. ${sentences[i]}');
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      final raw = await _ai.complete(
        system: _systemPrompt,
        user: user.toString(),
        temperature: 0.1,
        maxTokens: 8000,
      );
      final parsed = _parsePairs(raw, sentences, startIndex);
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// 解析并校验：条数、编号、以及每句 src 能在输入句子里找到。
  List<TranslationPair>? _parsePairs(
    String raw,
    List<String> sentences,
    int startIndex,
  ) {
    final jsonText = _stripFence(raw);
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final list = decoded['pairs'];
    if (list is! List || list.length != sentences.length) return null;

    final out = <TranslationPair>[];
    for (var i = 0; i < sentences.length; i++) {
      final item = list[i];
      if (item is! Map) return null;
      final src = (item['src'] ?? '').toString();
      final dst = (item['dst'] ?? '').toString().trim();
      if (dst.isEmpty) return null;
      // 原文回查：模型擅自改写/合并 src 时，这里会拦住
      if (!_sameSentence(src, sentences[i])) return null;
      out.add(TranslationPair(
        index: startIndex + i,
        source: sentences[i],
        target: dst,
      ));
    }
    return out;
  }

  Future<TranslationResult> _translateWhole(
    String text,
    String sourceLang,
    String targetLang,
  ) async {
    final translated = await _ai.complete(
      system: _wholeSystemPrompt,
      user: text,
      temperature: 0.1,
      maxTokens: 8000,
    );
    final clean = _stripFence(translated).trim();
    if (clean.isEmpty) throw Exception('翻译结果为空');
    return TranslationResult(
      sourceLang: sourceLang,
      targetLang: targetLang,
      mode: 'whole',
      pairs: [
        TranslationPair(index: 1, source: text, target: clean),
      ],
      createdAt: DateTime.now(),
    );
  }

  static String _stripFence(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      final firstNewline = t.indexOf('\n');
      if (firstNewline >= 0) {
        t = t.substring(firstNewline + 1);
        final fence = t.lastIndexOf('```');
        if (fence >= 0) t = t.substring(0, fence);
      }
    }
    return t.trim();
  }

  /// 归一化后比较（去掉空白与标点、小写），避免模型在 src 里加空格就判失败
  static bool _sameSentence(String a, String b) {
    return _normalize(a) == _normalize(b);
  }

  static String _normalize(String s) {
    return s
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'''[.,!?;:'"“”‘’()\[\]{}<>-]'''), '')
        .toLowerCase();
  }
}