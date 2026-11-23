// lib/services/transcript_corrector.dart
// 转写质量校准层：按 A/B/C 三档规则处理远场转写文本，输出四段式报告。
//
// 【三档规则（规格原文）】
//   A 高置信直接改：与术语表误听形式音近/形近/缩写漂移高度匹配，
//     或数字单位上下文唯一确定 → 直接替换，句末标 〔改：原→正〕
//   B 低置信只标注：疑似但无法从文本自身确定 → 保留原文，标
//     〔疑似：候选1 / 候选2，待确认〕；禁止为通顺而编造
//   C 远场缺失标注：句子不完整、明显缺词 → 不补全，标
//     〔此处可能缺失：前文在讲…，后文转向…，中间待确认〕
//
// 【为什么不做"润色式重写"】
// 纠错层和总结层职责必须分开。用户要的是还原老师实际讲的话，
// 不是一段读起来通顺的重新表达。所以提示词里把"禁止改写/禁止补全"
// 写成硬约束，并且要求每条修改都必须给出依据（音素/术语表/上下文）。
//
// 【质量过低时的处理】
// 如果整段是乱码、无法判断语义，先给"转写可用性评估"而不是硬纠错——
// 强行纠错只会产出一堆看起来像术语的幻觉。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/terminology.dart';
import 'pending_budget.dart';
import 'settings_service.dart';

class TranscriptCorrector {
  final SettingsService _settings = SettingsService();

  /// 单块字数。纠错要通读上下文，块太大容易超上下文，太小会丢跨段指代。
  static const int chunkChars = 6000;

  static const String _systemPrompt = '''
你是课堂录音转写的「术语纠错与质量校准层」。输入是一段因远距离拾音导致质量下降、
且含大量专业课术语的转写文本。你的任务不是重写，而是在**不编造信息**的前提下，
尽最大可能还原老师实际讲授的内容。

## 三档处理规则（严格按优先级执行）

### 规则 A：高置信度直接修正
满足以下任意一条，直接替换为正确术语，并在该句末尾标注 〔改：原→正〕：
1. 转写中的词与术语表某条的「常见误听形式」音素/拼音高度匹配
   （前后鼻音、平翘舌、声调相近均算匹配）；
2. 英文/缩写与术语表标准写法仅差大小写、连字符或空格
   （pass name → pathname，cloud code → Claude Code）；
3. 数字/单位明显转写错误且上下文唯一确定（"三天转" → "3000转"）。
   注意："120度"这类无法从上下文推翻的，保留原文并标注来源。

### 规则 B：低置信度只标注，不直接改
疑似术语错误但无法从转写文本本身确定正确形式时：
- **保留原文不动**，在词后标注 〔疑似：候选术语1 / 候选术语2，待确认〕；
- **严禁**为了"通顺"而编造一个术语替换进去；
- 同一疑似错误全文反复出现的，在 pending 数组里合并成一条并给 count。

### 规则 C：远场丢失内容的处理
句子逻辑不完整、明显缺词时，**不要补全**。用：
〔此处可能缺失：前文在讲……，后文转向……，中间内容待确认〕
保留缺口信息比强行补全更有价值。

## 待确认预算（硬性，优先级高于"拿不准就标"）
- 全文最多输出 5 条 pending，按下面的顺序挑最值得人回听的 5 条，其余**不要输出**，
  只把被砍掉的条数写进 suppressedCount。
- 排序依据（从高到低）：
  1. 命中了术语表中「高优先级」术语的疑似误听；
  2. 同一处疑似在文中反复出现（pending 里 count ≥ 2）；
  3. 候选唯一、且与原文只差一个音或一个字母；
  4. 其他。
- 以下情况**一律不标**：
  · 片段长度小于 2 个字符、纯标点、纯数字；
  · 原文本身通顺、又不是术语（改不改都不影响笔记正确性）；
  · 你已经能高置信修正的（放进规则 A 直接改，不要既改又标）。
- 标了就必须给 candidates（1–2 个），不要给空候选。

## 硬性约束
- 不改变老师原意的逻辑结构，不做润色式重写；
- 所有修改必须可追溯：要么匹配术语表，要么有音素/拼音依据，要么有上下文唯一性依据；
- **不确定 > 猜测**。标"待确认"永远优于填一个看似合理的错词；
- 如果输入质量过低（大量乱码、整句无法判断语义），先给 usability 评估，不要强行纠错。

## 输出 JSON（严格，不要任何多余文字）
{
  "annotatedText": "纠错后的全文，保留 A 档的 〔改：原→正〕 标注、B 档的 〔疑似：…〕 标注、C 档的 〔此处可能缺失：…〕 标注",
  "hits": [{"term":"命中的术语","corrected":true,"occurrences":2}],
  "missedTerms": ["术语表中完全未出现的术语"],
  "pending": [{"snippet":"原文片段","candidates":["候选1","候选2"],"count":1,"timestamp":"03:20"}],
  "micAdvice": ["针对本节实际暴露问题的拾音建议"],
  "usability": "仅当质量过低时填写评估，否则空字符串",
  "suppressedCount": 0
}

## 字段说明
- hits.corrected：true 表示"经你修正后才命中"，false 表示"原文就识别对了"
- missedTerms：术语表里有、但转写中完全找不到（可能被漏听或成了乱码）
- pending.timestamp：原文带时间戳时填，没有就省略该字段
- micAdvice：只列 1~3 条最针对性的，基于本次实际暴露的问题，不要写通用套话
- usability：只有质量过低（大量乱码/整句无法判断）时才填，否则必须是空字符串
''';

  /// 英语课校准提示词：只修听写错误，禁止翻译与改写。
  /// 输出结构与中文版完全一致，解析代码不用分叉。
  static const String _englishSystemPrompt = '''
你是「英语课」录音转写的校准层。输入是远场拾音的英语课堂转写，任务是**用最小改动**修正听写错误。

## 允许的修改（只有三类）
A. 明显拼写错误：recieve → receive
B. 专有名词大小写/连字符：darwin → Darwin，cellwall → cell wall
C. 同音/近音误听，且上下文能唯一确定：sell wall → cell wall
   改完在该句末尾标 〔改：原→正〕

## 待确认预算（硬性）
- 全文最多 5 条 pending，按「命中高优先术语 > 反复出现 > 候选唯一」排序后取前 5，其余不输出；
- 被砍掉的条数写进 suppressedCount；
- 纯标点/纯数字/长度 < 2、原文本来就正确、或你已能高置信修正的，一律不标。

## 严禁
- 把英文翻译成中文；不许新增原文没有的汉字（原文本身的中文解释保留）
- 改写句子结构、删减内容、润色语法、合并句子
- 把术语换成同义词
- 用中文同音字规则去"纠正"英文

## 拿不准
保留原文，在词后标 〔疑似：候选1 / 候选2，待确认〕，不要猜。
句子明显缺词时标 〔此处可能缺失：…〕，不要补全。

## 输出 JSON（严格，不要任何多余文字）
{
  "annotatedText": "校准后的全文，保留 〔改：原→正〕 / 〔疑似：…〕 / 〔此处可能缺失：…〕 标注",
  "hits": [{"term":"命中的术语","corrected":true,"occurrences":2}],
  "missedTerms": ["术语表里有但完全没出现的术语"],
  "pending": [{"snippet":"原文片段","candidates":["候选1","候选2"],"count":1}],
  "micAdvice": ["针对本节暴露的拾音建议"],
  "usability": "仅当质量过低时填写，否则空字符串",
  "suppressedCount": 0
}
''';

  /// 主入口：对整篇转写做校准。
  /// [text] 转写原文；[pack] 课前术语包（可为空，此时只按音素做保守修正）。
  Future<CalibrationReport> calibrate(
    String text, {
    TerminologyPack? pack,
    String language = 'zh',
  }) async {
    final systemPrompt =
        language == 'en' ? _englishSystemPrompt : _systemPrompt;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const CalibrationReport(annotatedText: '');
    }

    final apiKey = await _settings.getApiKey();
    if (apiKey.isEmpty) {
      throw Exception('请先在「设置」里填写 DeepSeek API Key');
    }

    final termBlock = pack == null || pack.terms.isEmpty
        ? '（本节课未提供术语表，请只修正非常明显的同音错误，拿不准一律标待确认）'
        : '## 本节课术语表\n${pack.termsAsPromptText}';
    final promptBlock = (pack?.initialPrompt ?? '').trim().isEmpty
        ? ''
        : '\n## 本节课 initial_prompt（术语提示）\n${pack!.initialPrompt}\n';

    // 短文本一次处理，同样要过一遍预算
    if (trimmed.length <= chunkChars) {
      final r = await _calibrateChunk(
          apiKey, trimmed, termBlock, promptBlock, systemPrompt);
      final highTerms = pack?.terms
              .where((t) => t.level == TermLevel.high)
              .map((t) => t.term)
              .toSet() ??
          const <String>{};
      final highMisheard = pack?.terms
              .where((t) => t.level == TermLevel.high)
              .expand((t) => t.misheardList)
              .toSet() ??
          const <String>{};
      final budget = PendingBudget.trim(
        r.pending,
        max: PendingBudget.defaultMax,
        highPriorityTerms: highTerms,
        highPriorityMisheard: highMisheard,
        modelSuppressed: r.suppressedCount,
      );
      return CalibrationReport(
        annotatedText: r.annotatedText,
        hits: r.hits,
        missedTerms: r.missedTerms,
        pending: budget.kept,
        micAdvice: r.micAdvice,
        usability: r.usability,
        suppressedCount: budget.suppressed,
        suppressedPending: budget.all.length > budget.kept.length
            ? budget.all.sublist(budget.kept.length)
            : const [],
        droppedCount: budget.dropped,
      );
    }

    final chunks = _split(trimmed);
    final annotated = <String>[];
    final allHits = <TermHit>[];
    final allPending = <PendingItem>[];
    final allMissed = <String>{};
    final allAdvice = <String>[];
    String? usability;
    var modelSuppressed = 0;

    for (final chunk in chunks) {
      final r = await _calibrateChunk(apiKey, chunk, termBlock, promptBlock, systemPrompt);
      annotated.add(r.annotatedText);
      allHits.addAll(r.hits);
      allPending.addAll(r.pending);
      allMissed.addAll(r.missedTerms);
      for (final a in r.micAdvice) {
        if (!allAdvice.contains(a)) allAdvice.add(a);
      }
      usability ??= r.usability;
      modelSuppressed += r.suppressedCount;
    }

    // 同一术语在多个块里命中时合并计数
    final mergedHits = _mergeHits(allHits);
    final mergedPending = _mergePending(allPending);

    // 预算收口：过滤噪音、合并同义、排序、截断到 5 条
    final highTerms = pack?.terms
            .where((t) => t.level == TermLevel.high)
            .map((t) => t.term)
            .toSet() ??
        const <String>{};
    final highMisheard = pack?.terms
            .where((t) => t.level == TermLevel.high)
            .expand((t) => t.misheardList)
            .toSet() ??
        const <String>{};
    final budget = PendingBudget.trim(
      mergedPending,
      max: PendingBudget.defaultMax,
      highPriorityTerms: highTerms,
      highPriorityMisheard: highMisheard,
      // 各块模型自报的截断数已累加，这里连同程序截断一起记
      modelSuppressed: modelSuppressed,
    );

    return CalibrationReport(
      annotatedText: annotated.join('\n'),
      hits: mergedHits,
      missedTerms: allMissed.toList(),
      pending: budget.kept,
      micAdvice: allAdvice.take(3).toList(),
      usability: usability,
      suppressedCount: budget.suppressed,
      suppressedPending: budget.all.length > budget.kept.length
          ? budget.all.sublist(budget.kept.length)
          : const [],
      droppedCount: budget.dropped,
    );
  }

  Future<CalibrationReport> _calibrateChunk(
    String apiKey,
    String chunk,
    String termBlock,
    String promptBlock,
    String systemPrompt,
  ) async {
    final userMessage = '$termBlock\n$promptBlock\n----- 待校准转写 -----\n$chunk';

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
                {'role': 'system', 'content': systemPrompt},
                {'role': 'user', 'content': userMessage},
              ],
              'response_format': {'type': 'json_object'},
              // 校准要保守，温度压低，避免"顺手润色"
              'temperature': 0.1,
              'max_tokens': 8000,
            }),
          )
          .timeout(const Duration(seconds: 180));
    } catch (_) {
      throw Exception('网络请求失败，校准未完成');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('DeepSeek API Key 无效，请到设置里检查');
    }
    if (response.statusCode == 402) {
      throw Exception('DeepSeek 账户余额不足');
    }
    if (response.statusCode != 200) {
      throw Exception('校准失败（状态码 ${response.statusCode}）');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final content = body['choices'][0]['message']['content'] as String;
      final d = jsonDecode(content) as Map<String, dynamic>;

      // 关键防线：模型没给正文时保留原文，绝不返回空。
      // 注意：pending / hits 仍然要解析——不能因为正文空就把待确认也吞掉。
      final annotated = (d['annotatedText'] as String?)?.trim() ?? '';

      final hits = ((d['hits'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => TermHit(
                term: (m['term'] ?? '').toString(),
                corrected: m['corrected'] == true,
                occurrences: (m['occurrences'] as num?)?.toInt() ?? 1,
              ))
          .where((h) => h.term.isNotEmpty)
          .toList();

      final pending = ((d['pending'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => PendingItem(
                snippet: (m['snippet'] ?? '').toString(),
                candidates: ((m['candidates'] as List?) ?? [])
                    .map((e) => e.toString())
                    .where((e) => e.trim().isNotEmpty)
                    .toList(),
                count: (m['count'] as num?)?.toInt() ?? 1,
                timestamp: (m['timestamp'] as String?)?.trim().isEmpty == true
                    ? null
                    : m['timestamp'] as String?,
              ))
          .where((p) => p.snippet.isNotEmpty)
          .toList();

      final missed = ((d['missedTerms'] as List?) ?? [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final advice = ((d['micAdvice'] as List?) ?? [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .take(3)
          .toList();

      final usability = (d['usability'] as String?)?.trim() ?? '';
      final suppressed = (d['suppressedCount'] as num?)?.toInt() ?? 0;

      if (annotated.isEmpty) {
        return CalibrationReport(
          annotatedText: chunk,
          hits: hits,
          missedTerms: missed,
          pending: pending,
          micAdvice: advice,
          usability: '模型未返回正文，已保留原文未改动',
          suppressedCount: suppressed < 0 ? 0 : suppressed,
        );
      }

      return CalibrationReport(
        annotatedText: annotated,
        hits: hits,
        missedTerms: missed,
        pending: pending,
        micAdvice: advice,
        usability: usability.isEmpty ? null : usability,
        suppressedCount: suppressed < 0 ? 0 : suppressed,
      );
    } catch (_) {
      throw Exception('校准结果解析失败，原文未改动');
    }
  }

  /// 同一术语在多个块里命中时合并
  List<TermHit> _mergeHits(List<TermHit> hits) {
    final map = <String, TermHit>{};
    for (final h in hits) {
      final existing = map[h.term];
      if (existing == null) {
        map[h.term] = h;
      } else {
        map[h.term] = TermHit(
          term: h.term,
          corrected: existing.corrected || h.corrected,
          occurrences: existing.occurrences + h.occurrences,
        );
      }
    }
    return map.values.toList();
  }

  /// 同一疑似错误跨块重复出现时合并计数
  List<PendingItem> _mergePending(List<PendingItem> pending) {
    final map = <String, PendingItem>{};
    for (final p in pending) {
      final key = p.snippet;
      final existing = map[key];
      if (existing == null) {
        map[key] = p;
      } else {
        map[key] = PendingItem(
          snippet: p.snippet,
          candidates: {...existing.candidates, ...p.candidates}.toList(),
          count: existing.count + p.count,
          timestamp: existing.timestamp ?? p.timestamp,
        );
      }
    }
    return map.values.toList();
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