// lib/services/pending_budget.dart
// 待确认项的「预算」：过滤噪声、合并同义、排序、截断。
//
// 【为什么需要这一层】
// 纠错模型原来的规则是「拿不准就标待确认」。一节课下来几十条，
// 用户点三条就烦了，剩下的全略过——等于没纠错，还赔了时间。
//
// 这里做的事不是「让模型少说」，而是把有限的人工注意力花在最值钱的几条上：
//   ① 噪音（纯标点/数字/单字）直接不列
//   ② 同一个错误的多种写法合并成一条
//   ③ 按「命中高优先术语 > 反复出现 > 候选唯一」排序
//   ④ 只留前 N 条，其余计入 suppressed（仍可展开看，不丢信息）
//
// 纯函数，不碰数据库、不碰网络，方便测试锁住行为。
import '../models/terminology.dart';

class PendingTrimResult {
  /// 排序并截断后的保留项（界面默认展示）
  final List<PendingItem> kept;

  /// 过滤 + 合并 + 排序后的全部项（供「展开其余」只读查看）
  final List<PendingItem> all;

  /// 被压掉的条数（含模型自报被截断的条数）
  final int suppressed;

  const PendingTrimResult({
    required this.kept,
    required this.all,
    required this.suppressed,
  });

  bool get hasSuppressed => suppressed > 0;
}

class PendingBudget {
  const PendingBudget._();

  /// 默认预算：一节课最多 5 条待确认
  static const int defaultMax = 5;

  /// 把一个待确认列表收敛到 [max] 条以内。
  ///
  /// [highPriorityTerms] 是高优先级术语（已归一化或原文均可），
  /// 命中它们的疑似误听排在前面。
  /// [modelSuppressed] 是模型自报「因预算被截断」的条数，直接累加进结果。
  static PendingTrimResult trim(
    List<PendingItem> items, {
    int max = defaultMax,
    Set<String> highPriorityTerms = const {},
    Set<String> highPriorityMisheard = const {},
    int modelSuppressed = 0,
  }) {
    final high = highPriorityTerms
        .map(normalize)
        .where((t) => t.isNotEmpty)
        .toSet();
    final misheard = highPriorityMisheard
        .map(normalize)
        .where((t) => t.isNotEmpty)
        .toSet();

    // ① 过滤噪音
    final filtered = <PendingItem>[];
    for (final p in items) {
      final norm = normalize(p.snippet);
      if (norm.isEmpty) continue;
      if (norm.length < 2) continue;
      if (RegExp(r'^[0-9]+$').hasMatch(norm)) continue;
      // 无候选的单次项不丢弃：它可能是「缺词」类提示，
      // 只是排序时排最后（score 0），预算不够时才被压进 suppressed。
      filtered.add(p);
    }

    // ② 按归一化文本合并（同义不同写）
    final merged = <String, PendingItem>{};
    for (final p in filtered) {
      final key = normalize(p.snippet);
      final existing = merged[key];
      if (existing == null) {
        merged[key] = p;
      } else {
        merged[key] = PendingItem(
          snippet: existing.snippet,
          candidates: _union(existing.candidates, p.candidates),
          count: existing.count + p.count,
          timestamp: existing.timestamp ?? p.timestamp,
          positions: _unionInts(existing.positions, p.positions),
        );
      }
    }

    // ③ 包含关系合并：只差一两个字时是同一个错误的两种写法
    var list = merged.values.toList();
    var changed = true;
    while (changed) {
      changed = false;
      outer:
      for (var i = 0; i < list.length; i++) {
        for (var j = i + 1; j < list.length; j++) {
          final a = normalize(list[i].snippet);
          final b = normalize(list[j].snippet);
          if (a.isEmpty || b.isEmpty) continue;
          final longer = a.length >= b.length ? list[i] : list[j];
          final shorter = a.length >= b.length ? list[j] : list[i];
          final ln = a.length >= b.length ? a : b;
          final sn = a.length >= b.length ? b : a;
          if (ln.contains(sn) && ln.length - sn.length <= 2 && sn.length >= 3) {
            final combined = PendingItem(
              snippet: longer.snippet,
              candidates: _union(longer.candidates, shorter.candidates),
              count: longer.count + shorter.count,
              timestamp: longer.timestamp ?? shorter.timestamp,
              positions: _unionInts(longer.positions, shorter.positions),
            );
            list
              ..removeAt(j)
              ..removeAt(i)
              ..insert(i, combined);
            changed = true;
            break outer;
          }
        }
      }
    }

    // ④ 排序：命中高优术语 > 反复出现 > 候选唯一 > 其他；同分按出现位置
    final order = <String, int>{
      for (var i = 0; i < list.length; i++) _identity(list[i]): i,
    };
    int score(PendingItem p) {
      final norm = normalize(p.snippet);
      var s = 0;
      // 关键是「候选/误听形式命中了高优术语」，不是原文里已经写着正确写法。
      // 原文已经是正确写法的那条，本来就是误报，不该排前面。
      final candidateHitsTerm = p.candidates
          .map(normalize)
          .any((c) => c.isNotEmpty && high.contains(c));
      if (candidateHitsTerm || misheard.contains(norm)) s += 3;
      if (p.count >= 2) s += 2;
      if (p.candidates.length == 1) s += 1;
      return s;
    }

    list.sort((x, y) {
      final byScore = score(y).compareTo(score(x));
      if (byScore != 0) return byScore;
      final px = x.positions.isEmpty ? 1 << 30 : x.positions.first;
      final py = y.positions.isEmpty ? 1 << 30 : y.positions.first;
      if (px != py) return px.compareTo(py);
      // 稳定兜底：分数与位置都一样时保持输入顺序
      return (order[_identity(x)] ?? 0).compareTo(order[_identity(y)] ?? 0);
    });

    // ⑤ 截断
    final limit = max < 0 ? 0 : max;
    final kept = list.length <= limit ? List<PendingItem>.from(list) : list.sublist(0, limit);
    final suppressed =
        (list.length - kept.length) + (modelSuppressed < 0 ? 0 : modelSuppressed);

    return PendingTrimResult(kept: kept, all: list, suppressed: suppressed);
  }

  static String _identity(PendingItem p) =>
      '${p.snippet}|${p.candidates.join('/')}|${p.count}';

  /// 归一化：小写、去空白、去标点，用于比较「是不是同一个错误」
  static String normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(
          RegExp(r'''[.,!?;:'"“”‘’()\[\]{}<>、，。；：！？…—\-·]'''),
          '',
        );
  }

  static List<String> _union(List<String> a, List<String> b) {
    final out = <String>[...a];
    for (final x in b) {
      if (!out.contains(x)) out.add(x);
    }
    return out;
  }

  static List<int> _unionInts(List<int> a, List<int> b) {
    final out = <int>{...a, ...b}.toList()..sort();
    return out;
  }
}