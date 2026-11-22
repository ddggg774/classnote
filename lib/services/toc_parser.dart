// lib/services/toc_parser.dart
// 教材目录解析：把用户粘贴的一段目录文本变成 章 → 节 两级结构。
//
// 【最重要的一条：绝不许编造】
// 章节号编错会一路污染术语表、纠错和总结，而且用户很难发现。
// 所以这里的纪律是：
//   ① 先走正则，正则认得的行才进结构；
//   ② 认不得的行如实丢掉，并计数返回，界面上要显示「丢弃了 N 行」；
//   ③ 模型兜底也只许重排用户给的文字——每一行都必须能在原文里找到，
//      找不到就丢（见 fromModelJson 的行级回溯校验）。
//
// 这是纯 Dart、不依赖 Flutter，方便单测。
import 'dart:convert';

/// 一节（解析结果，尚未落库）
class TocSection {
  final String no;
  final String title;

  const TocSection({this.no = '', required this.title});

  String get displayName {
    final n = no.trim();
    return n.isEmpty ? title : '$n $title'.trim();
  }

  Map<String, dynamic> toJson() => {'no': no, 'title': title};
}

/// 一章（解析结果，尚未落库）
class TocChapter {
  final String no;
  final String title;
  final List<TocSection> sections;

  const TocChapter({this.no = '', required this.title, this.sections = const []});

  String get displayName {
    final n = no.trim();
    return n.isEmpty ? title : '$n $title'.trim();
  }

  Map<String, dynamic> toJson() => {
        'no': no,
        'title': title,
        'sections': sections.map((s) => s.toJson()).toList(),
      };
}

/// 一份目录
class TocData {
  final List<TocChapter> chapters;

  /// 没能进结构的原文行，给界面提示用（不许悄悄吞掉）
  final List<String> droppedLines;

  const TocData({this.chapters = const [], this.droppedLines = const []});

  bool get isEmpty => chapters.isEmpty;

  int get chapterCount => chapters.length;

  int get sectionCount =>
      chapters.fold(0, (sum, c) => sum + c.sections.length);

  static const TocData empty = TocData();
}

class TocParser {
  // ───────────────────── 正则 ─────────────────────

  /// 第X章 被子植物
  static final RegExp _reChapterCn =
      RegExp(r'^第\s*([一二三四五六七八九十百零〇\d]{1,4})\s*章');

  /// 第X节 木兰科
  static final RegExp _reSectionCn =
      RegExp(r'^第\s*([一二三四五六七八九十百零〇\d]{1,4})\s*节');

  /// 5.2 / 5.2.1（点号分级的节号；必须至少两级，避免把「5. 被子植物」当成节）
  static final RegExp _reSectionNum = RegExp(r'^(\d{1,2}(?:\.\d{1,2}){1,2})(?![\.\d])');

  /// 5 被子植物 / 5. 被子植物 / 5、被子植物（章级阿拉伯编号）
  static final RegExp _reChapterNum = RegExp(r'^(\d{1,2})(?:[.、．])?\s+(\S.*)$');

  /// 一、被子植物
  static final RegExp _reCnOrdinal = RegExp(r'^([一二三四五六七八九十百零〇]{1,4})[、.．]\s*(.*)$');

  /// （一）木兰科 —— 第三级，本版只有章/节两层，这类行会如实丢弃
  static final RegExp _reCnParen = RegExp(r'^[（(]([一二三四五六七八九十百零〇]{1,4})[)）]');

  /// 附录 / 参考文献 / 前言 等无编号节点
  static final RegExp _reAppendix = RegExp(r'^(附录|参考文献|索\s*引|后\s*记|前\s*言|绪\s*论|引\s*言)');

  /// 目录自身的标题行，跳过不计数
  static final RegExp _reTocHeading = RegExp(r'^(目\s*录|contents?)$', caseSensitive: false);

  /// 纯页码行：「12」「第 12 页」「- 12 -」
  static final RegExp _rePageNumber = RegExp(r'^(第?\s*\d{1,4}\s*页?|[-—–\s]*\d{1,4}[-—–\s]*)$');

  /// 标题尾部的省略号 + 页码：「被子植物 …… 12」「被子植物    12」
  static final RegExp _reTrailingPage = RegExp(r'(?:[.·…]{2,}|\s{2,})\s*\d{1,4}\s*$');

  /// 行首的分隔符，去掉后再取标题
  static final RegExp _reLeadingSeparators = RegExp(r'^[\s:：.、,，·…\-—–]+');

  // ───────────────────── 解析 ─────────────────────

  /// 只用规则解析。模型不参与，所以这一份结果里不可能出现原文没有的字。
  static TocData parse(String raw) {
    final chapters = <TocChapter>[];
    final dropped = <String>[];

    // 正在拼装的一章（sections 可继续追加）
    var currentNo = '';
    var currentTitle = '';
    var currentSections = <TocSection>[];
    var hasCurrent = false;

    void flush() {
      if (!hasCurrent) return;
      chapters.add(TocChapter(
        no: currentNo,
        title: currentTitle,
        sections: List.unmodifiable(currentSections),
      ));
      hasCurrent = false;
      currentSections = <TocSection>[];
    }

    // 上一条是章还是节，决定「无编号缩进行」往哪拼
    var lastIsSection = false;

    final lines = raw.split(RegExp(r'\r?\n'));
    for (final rawLine in lines) {
      final line = _tidy(rawLine);
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (_reTocHeading.hasMatch(trimmed)) continue;
      if (_rePageNumber.hasMatch(trimmed)) continue;

      // ① 第X章
      if (_reChapterCn.hasMatch(trimmed)) {
        flush();
        final rest = _afterPrefix(trimmed, _reChapterCn);
        currentNo = _head(trimmed, _reChapterCn);
        currentTitle = rest;
        hasCurrent = true;
        lastIsSection = false;
        continue;
      }

      // ② 附录 / 参考文献 这类无编号节点，当章处理
      if (_reAppendix.hasMatch(trimmed)) {
        flush();
        currentNo = '';
        currentTitle = trimmed;
        hasCurrent = true;
        lastIsSection = false;
        continue;
      }

      // ③ 第X节
      if (_reSectionCn.hasMatch(trimmed)) {
        final sec = TocSection(
          no: _head(trimmed, _reSectionCn),
          title: _afterPrefix(trimmed, _reSectionCn),
        );
        if (!hasCurrent) {
          dropped.add(trimmed);
          continue;
        }
        currentSections.add(sec);
        lastIsSection = true;
        continue;
      }

      // ④ 5.2 / 5.2.1
      final mSectionNum = _reSectionNum.firstMatch(trimmed);
      if (mSectionNum != null) {
        final no = mSectionNum.group(1)!;
        final title = trimmed
            .substring(mSectionNum.end)
            .replaceFirst(_reLeadingSeparators, '')
            .trim();
        if (!hasCurrent || title.isEmpty) {
          dropped.add(trimmed);
          continue;
        }
        currentSections.add(TocSection(no: no, title: title));
        lastIsSection = true;
        continue;
      }

      // ⑤ 一、xxx —— 没有章时当章，有章时当节
      final mOrdinal = _reCnOrdinal.firstMatch(trimmed);
      if (mOrdinal != null) {
        final no = '${mOrdinal.group(1)}、';
        final title = mOrdinal.group(2)!.trim();
        if (title.isEmpty) {
          dropped.add(trimmed);
          continue;
        }
        if (!hasCurrent) {
          currentNo = no;
          currentTitle = title;
          hasCurrent = true;
          lastIsSection = false;
        } else if (currentNo.endsWith('、') &&
            currentSections.isEmpty &&
            _cnToInt(no.substring(0, no.length - 1)) ==
                _chapterNumberValue(currentNo) + 1) {
          // 上一章也是「一、」这种编号且还没有节，编号又正好 +1：
          // 说明这是并列的顶层条目（一、二、三、），不是章内的节
          flush();
          currentNo = no;
          currentTitle = title;
          hasCurrent = true;
          lastIsSection = false;
        } else {
          currentSections.add(TocSection(no: no, title: title));
          lastIsSection = true;
        }
        continue;
      }

      // ⑥ （一）xxx —— 第三级，两层结构装不下，如实丢弃
      if (_reCnParen.hasMatch(trimmed)) {
        dropped.add(trimmed);
        continue;
      }

      // ⑦ 5 被子植物 / 5. 被子植物
      final mChapterNum = _reChapterNum.firstMatch(trimmed);
      if (mChapterNum != null) {
        final num = int.tryParse(mChapterNum.group(1)!) ?? 0;
        final title = mChapterNum.group(2)!.trim();
        final lastNum = hasCurrent ? _chapterNumberValue(currentNo) : 0;
        // 编号递增 → 新章；否则更像章内条目 → 当节
        if (!hasCurrent || (num > lastNum && num - lastNum <= 3)) {
          flush();
          currentNo = mChapterNum.group(1)!;
          currentTitle = title;
          hasCurrent = true;
          lastIsSection = false;
        } else if (title.isNotEmpty) {
          currentSections.add(TocSection(no: '${mChapterNum.group(1)}.', title: title));
          lastIsSection = true;
        } else {
          dropped.add(trimmed);
        }
        continue;
      }

      // ⑧ 无编号的缩进行：认为是上一条标题的续行（长标题换行）
      final indent = rawLine.length - rawLine.trimLeft().length;
      if (indent > 0 && hasCurrent) {
        if (lastIsSection && currentSections.isNotEmpty) {
          final last = currentSections.removeLast();
          currentSections.add(
            TocSection(no: last.no, title: '${last.title} $trimmed'),
          );
        } else {
          currentTitle = '${currentTitle.trim()} $trimmed'.trim();
        }
        continue;
      }

      // ⑨ 实在认不得
      dropped.add(trimmed);
    }
    flush();

    return TocData(
      chapters: List.unmodifiable(chapters),
      droppedLines: List.unmodifiable(dropped),
    );
  }

  // ───────────────────── 模型兜底的行级校验 ─────────────────────

  /// 模型返回的结构化 JSON → TocData。
  ///
  /// 校验规则：每个 no / title 去掉空白与标点后，必须能在用户原始输入里找到。
  /// 找不到的章整章丢弃、找不到的节单节丢弃，并全部记进 droppedLines。
  /// 这比在提示词里写「不要编造」可靠——它是可执行的判断，不是道德劝告。
  ///
  /// JSON 解析失败返回 null，调用方应退回 [parse] 的正则结果。
  static TocData? fromModelJson(String jsonText, String rawInput) {
    final decoded = _tryDecodeChapters(jsonText);
    if (decoded == null) return null;

    final rawNorm = _normalizeForMatch(rawInput);
    final chapters = <TocChapter>[];
    final dropped = <String>[];

    for (final c in decoded) {
      final no = (c['no'] ?? '').toString().trim();
      final title = (c['title'] ?? '').toString().trim();
      if (title.isEmpty && no.isEmpty) continue;
      if (!_traceable(no, rawNorm) || !_traceable(title, rawNorm)) {
        dropped.add([no, title].where((s) => s.isNotEmpty).join(' '));
        continue;
      }

      final sections = <TocSection>[];
      final rawSections = c['sections'];
      if (rawSections is List) {
        for (final s in rawSections) {
          if (s is! Map) continue;
          final sNo = (s['no'] ?? '').toString().trim();
          final sTitle = (s['title'] ?? '').toString().trim();
          if (sTitle.isEmpty && sNo.isEmpty) continue;
          if (!_traceable(sNo, rawNorm) || !_traceable(sTitle, rawNorm)) {
            dropped.add([sNo, sTitle].where((x) => x.isNotEmpty).join(' '));
            continue;
          }
          sections.add(TocSection(no: sNo, title: sTitle));
        }
      }
      chapters.add(TocChapter(
        no: no,
        title: title.isEmpty ? no : title,
        sections: List.unmodifiable(sections),
      ));
    }

    if (chapters.isEmpty) return null;
    return TocData(
      chapters: List.unmodifiable(chapters),
      droppedLines: List.unmodifiable(dropped),
    );
  }

  /// 宽容解析模型返回的 JSON：可能是 {"chapters":[...]}，也可能直接是数组
  static List<Map>? _tryDecodeChapters(String jsonText) {
    final text = _stripCodeFence(jsonText.trim());
    if (text.isEmpty) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    dynamic chapters;
    if (decoded is Map) {
      chapters = decoded['chapters'];
    } else if (decoded is List) {
      chapters = decoded;
    }
    if (chapters is! List) return null;
    return chapters.whereType<Map>().toList();
  }

  static String _stripCodeFence(String s) {
    if (!s.startsWith('```')) return s;
    final firstNewline = s.indexOf('\n');
    if (firstNewline < 0) return s;
    var body = s.substring(firstNewline + 1);
    final fence = body.lastIndexOf('```');
    if (fence >= 0) body = body.substring(0, fence);
    return body.trim();
  }

  // ───────────────────── 工具 ─────────────────────

  /// 去掉行首缩进以外的空白、行尾页码、尾部标点
  static String _tidy(String rawLine) {
    var line = rawLine.replaceAll('\u3000', ' ');
    line = line.replaceAll(_reTrailingPage, '');
    return line.trimRight();
  }

  static String _head(String s, RegExp re) {
    final m = re.firstMatch(s);
    if (m == null) return '';
    final end = m.end;
    // 去掉「第 五 章」里的空格，编号里不该有空白
    return s.substring(0, end).replaceAll(RegExp(r'\s+'), '').trim();
  }

  static String _afterPrefix(String s, RegExp re) {
    final m = re.firstMatch(s);
    if (m == null) return s;
    return s.substring(m.end).replaceFirst(_reLeadingSeparators, '').trim();
  }

  /// 从章号推算数字，用于判断「编号变大就是新章」
  static int _chapterNumberValue(String no) {
    final m = RegExp(r'\d+').firstMatch(no);
    if (m != null) return int.tryParse(m.group(0)!) ?? 0;
    final cn = RegExp(r'[一二三四五六七八九十百零〇]+').firstMatch(no);
    if (cn == null) return 0;
    return _cnToInt(cn.group(0)!);
  }

  static int _cnToInt(String s) {
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    var total = 0;
    var section = 0;
    var number = 0;
    for (final ch in s.split('')) {
      if (ch == '百') {
        total += (number == 0 ? 1 : number) * 100;
        number = 0;
      } else if (ch == '十') {
        section += (number == 0 ? 1 : number) * 10;
        number = 0;
      } else {
        final d = digits[ch];
        if (d != null) number = d;
      }
    }
    return total + section + number;
  }

  /// 归一化：全角转半角、去掉所有空白与标点，用于「必须能在原文里找到」的判断
  static String _normalizeForMatch(String s) {
    final buf = StringBuffer();
    for (final rune in s.runes) {
      var c = rune;
      if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
      if (c == 0x3000) continue;
      if (c <= 0x20) continue;
      final ch = String.fromCharCode(c);
      if (_punctuation.contains(ch)) continue;
      buf.write(ch);
    }
    return buf.toString().toLowerCase();
  }

  static const String _punctuation =
      '，。、；：！？（）【】《》「」‘’“”·…—–-_,.;:!?()[]{}<>/\\|"\'`~@#\$%^&*+= ';

  static bool _traceable(String field, String rawNorm) {
    final n = _normalizeForMatch(field);
    if (n.isEmpty) return true;
    return rawNorm.contains(n);
  }
}