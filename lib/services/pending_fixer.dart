// lib/services/pending_fixer.dart
// 待确认项的「一键替换」。
//
// 【为什么单独抽出来】
// 替换看着简单，实际有三个坑：
//   ① 同一片段在文中出现多次，全替还是只替一处？用户得能选
//   ② 替换后字符长度变了，**其余待确认项的位置全部失效**
//      —— 不重算的话，用户点第二条会跳到错的地方
//   ③ 替换目标本身就是待确认内容，不能拿它当"确定正确"
//
// 这三条都在纯函数里处理，才能用测试锁住。
// 不许在界面里就地拼字符串，那样必然漏掉第 ② 条。
import '../models/terminology.dart';

/// 一次替换的结果
class FixResult {
  /// 替换后的新正文
  final String text;

  /// 实际替换了几处
  final int replaced;

  /// 替换后重新定位过的待确认项（位置已同步）
  final List<PendingItem> remainingPending;

  const FixResult({
    required this.text,
    required this.replaced,
    required this.remainingPending,
  });

  bool get changed => replaced > 0;
}

class PendingFixer {
  const PendingFixer._();

  /// 用 [replacement] 替换 [item] 在 [text] 中的出现。
  ///
  /// [all] 为 true 时替换全部出现位置，否则只替换第一处。
  /// [item] 会从返回的待确认列表里移除——它已经被人工确认过了。
  /// 其余待确认项的位置会在新文本上重新计算，避免整体错位。
  static FixResult apply(
    String text,
    PendingItem item,
    String replacement, {
    bool all = false,
  }) {
    final snippet = item.snippet.trim();
    if (snippet.isEmpty || replacement.trim().isEmpty || text.isEmpty) {
      return FixResult(text: text, replaced: 0, remainingPending: const []);
    }
    // 候选和原文一样：这不是一次修改，不能算「替换成功」并把清单删掉
    if (replacement.trim() == snippet) {
      return FixResult(
        text: text,
        replaced: 0,
        remainingPending: _relocate(text, item, keep: true),
      );
    }

    // 新文本用 StringBuffer 拼，避免多次 substring 产生大量中间串
    final buffer = StringBuffer();
    var cursor = 0;
    var replaced = 0;

    while (true) {
      final idx = text.indexOf(snippet, cursor);
      if (idx < 0) break;

      buffer.write(text.substring(cursor, idx));
      buffer.write(replacement);
      replaced++;
      cursor = idx + snippet.length;

      // 只替一处就停；否则继续找下一处
      if (!all) break;
      if (cursor >= text.length) break;
    }
    buffer.write(text.substring(cursor));

    if (replaced == 0) {
      // 一处都没替上，说明原文和片段对不上（可能已被别处改过）。
      // 原样返回，不编造"替换成功"。
      return FixResult(
        text: text,
        replaced: 0,
        remainingPending: _relocate(text, item, keep: true),
      );
    }

    final newText = buffer.toString();
    // 关键：位置全部重算。不重算的话后面的待确认项会跳到错地方。
    return FixResult(
      text: newText,
      replaced: replaced,
      remainingPending: _relocate(newText, item, keep: false),
    );
  }

  /// 在新文本上重新定位所有待确认项（可移除指定的一条）
  ///
  /// [keep] 为 false 表示 target 已被替换掉，要从列表里剔除；
  /// 为 true 表示这次没替成（找不到片段），target 原样保留。
  static List<PendingItem> _relocate(
    String newText,
    PendingItem target, {
    required bool keep,
  }) {
    // 调用方通常只传当前这一条；保留与否之外的项目由界面层用
    // relocateAll 统一处理。这里只负责"这一条怎么办"。
    return keep ? [_locateOne(newText, target)] : const [];
  }

  /// 批量版本：给一组待确认项在新文本上重算位置。
  ///
  /// 界面上替换掉一条后，其余几条必须走这个方法重算——
  /// 文字长度变了，老位置全部失效，不重算就会跳到错的地方。
  static List<PendingItem> relocateAll(
    String newText,
    List<PendingItem> items,
  ) {
    if (items.isEmpty) return const [];
    return items.map((p) => _locateOne(newText, p)).toList();
  }

  static PendingItem _locateOne(String text, PendingItem item) {
    final snippet = item.snippet.trim();
    if (snippet.isEmpty) return item.withPositions(const []);
    final found = <int>[];
    var from = 0;
    while (true) {
      final idx = text.indexOf(snippet, from);
      if (idx < 0) break;
      found.add(idx);
      from = idx + snippet.length;
      if (from >= text.length) break;
    }
    return item.withPositions(found);
  }
}