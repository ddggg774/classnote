// lib/services/sentence_splitter.dart
// 英语切句：把一段英文转写切成句子，供逐句翻译与对照使用。
//
// 【为什么必须单独一个纯函数】
// 整段翻译一定会合并句子，对照就废了。切句是所有"逐句"体验的地基，
// 藏在提示词里等于没法测、没法复现。这里只做规则，不碰网络。
//
// 需要照顾的边界（都写在测试里）：
//   · Mr. / Dr. / e.g. / i.e. / etc. / Fig. 这类缩写不是句末
//   · 单个大写字母（人名缩写 J. K. Rowling）不是句末
//   · 引号内的句号（He said "Hi." Then...）要在引号后再断
//   · "..." 省略号不当作句末（除非在文本末尾）
//   · 换行是硬边界
class SentenceSplitter {
  /// 常见缩写（小写、不含点）。
  static const Set<String> _abbreviations = {
    'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc',
    'eg', 'ie', 'cf', 'viz', 'al', 'fig', 'figs', 'no', 'nos', 'vol',
    'vols', 'pp', 'p', 'inc', 'ltd', 'co', 'dept', 'univ', 'approx',
    'ca', 'ed', 'eds', 'ch', 'sec', 'eq', 'ref', 'refs',
  };

  /// 切成句子。空输入返回空列表；每个元素都已 trim。
  static List<String> splitEnglish(String text) {
    final out = <String>[];
    final buffer = StringBuffer();
    final s = text;

    void flush() {
      final t = buffer.toString().trim();
      if (t.isNotEmpty) out.add(t);
      buffer.clear();
    }

    for (var i = 0; i < s.length; i++) {
      final ch = s[i];

      if (ch == '\n') {
        flush();
        continue;
      }

      buffer.write(ch);

      // 结束符：.!?
      if (ch == '.' || ch == '!' || ch == '?') {
        // 把连续的 ! ? . 一起吃掉（"?!"、"..."）
        var j = i + 1;
        while (j < s.length && '!?.'.contains(s[j])) {
          buffer.write(s[j]);
          j++;
        }
        final nextIndex = j;
        final atEnd = nextIndex >= s.length;
        final nextIsSpace = !atEnd && _isSpace(s[nextIndex]);

        // 只有后面跟着空白或到末尾，才可能是句子边界
        if (!atEnd && !nextIsSpace) {
          i = j - 1;
          continue;
        }

        final accumulated = buffer.toString().trimRight();

        // 省略号：文本中间不当作句末（"Well... maybe"）
        if (ch == '.' && accumulated.endsWith('...') && !atEnd) {
          i = j - 1;
          continue;
        }

        // 缩写与首字母缩略：不是句末
        if (ch == '.' && _isAbbreviationEnd(accumulated)) {
          i = j - 1;
          continue;
        }

        // 引号/括号还没闭合时，等闭合后再断
        if (!atEnd && _startsWithClosing(s, nextIndex)) {
          i = j - 1;
          continue;
        }

        flush();
        i = j - 1;
        continue;
      }

      // 引号或右括号紧跟结束符，并且后面是空白：在这里断
      if ((ch == '"' || ch == '”' || ch == ')' || ch == '）') &&
          (i + 1 >= s.length || _isSpace(s[i + 1]))) {
        final t = buffer.toString().trim();
        final withoutClose = t.substring(0, t.length - 1).trimRight();
        final endsSentence = withoutClose.endsWith('.') ||
            withoutClose.endsWith('!') ||
            withoutClose.endsWith('?');
        if (endsSentence) {
          // 引号后接小写（"...？" and waited）说明句子还没完；
          // 接大写/结束才是新句子开始
          final next = _nextNonSpace(s, i + 1);
          final startsNew =
              next.isEmpty || RegExp(r'[A-Z"“（(]').hasMatch(next);
          if (startsNew) flush();
        }
      }
    }

    flush();
    return out;
  }

  static bool _isSpace(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';

  static bool _startsWithClosing(String s, int index) {
    if (index >= s.length) return false;
    final ch = s[index];
    return ch == '"' || ch == '”' || ch == ')' || ch == '）';
  }

  /// 跳过空白看下一个字符；没有则返回空串
  static String _nextNonSpace(String s, int index) {
    for (var i = index; i < s.length; i++) {
      if (!_isSpace(s[i])) return s[i];
    }
    return '';
  }

  /// 这一段（以点结尾）是不是缩写 / 首字母 / 数字小数点
  static bool _isAbbreviationEnd(String accumulated) {
    if (!accumulated.endsWith('.')) return false;

    final beforeDot = accumulated.substring(0, accumulated.length - 1);

    // 取最后一个「词」（可能包含内部的点，如 U.S）
    final match = RegExp(r'([A-Za-z.]+)$').firstMatch(beforeDot);
    if (match == null) return false;
    final word = match.group(1)!;
    final lower = word.toLowerCase().replaceAll('.', '');

    if (_abbreviations.contains(lower)) return true;

    // 首字母缩写：U.S / J.K / e.g
    final parts = word.split('.').where((p) => p.isNotEmpty).toList();
    if (parts.length > 1 &&
        parts.every((p) => p.length == 1 && RegExp(r'[A-Za-z]').hasMatch(p))) {
      return true;
    }
    // 单个大写字母：J. K. Rowling
    if (word.length == 1 && RegExp(r'[A-Z]').hasMatch(word)) return true;

    return false;
  }
}