// test/pending_budget_test.dart
// 待确认预算：过滤、合并、排序、截断。
//
// 这层是「几十条待确认」问题的收口点，行为必须钉死：
//   · 噪音不能占预算
//   · 同一个错误的两种写法必须合并
//   · 重要的（命中术语/反复出现）排在前面
//   · 截断后要能报出「压掉了多少条」，不能悄悄丢

import 'package:flutter_test/flutter_test.dart';

import 'package:classnote/models/terminology.dart';
import 'package:classnote/services/pending_budget.dart';

PendingItem item(
  String snippet, {
  List<String> candidates = const [],
  int count = 1,
  List<int> positions = const [],
}) =>
    PendingItem(
      snippet: snippet,
      candidates: candidates,
      count: count,
      positions: positions,
    );

void main() {
  group('过滤噪音', () {
    test('单字、纯数字、纯标点 → 不在预算里；无候选项保留', () {
      final r = PendingBudget.trim([
        item('叶', candidates: ['叶']),
        item('120', candidates: ['120']),
        item('。，', candidates: ['，']),
        item('心皮'), // 无候选，但可能是「缺词」提示，保留
        item('木兰科', candidates: ['木兰棵']),
      ]);
      expect(r.all.length, 2);
      expect(r.all.map((e) => e.snippet), containsAll(['心皮', '木兰科']));
    });

    test('无候选但反复出现（count≥2）要保留', () {
      final r = PendingBudget.trim([
        item('心皮', count: 3),
      ]);
      expect(r.all.length, 1);
      expect(r.all.single.count, 3);
    });
  });

  group('合并同义', () {
    test('去空白/标点后相同的合并成一条，候选与次数相加', () {
      final r = PendingBudget.trim([
        item('心 脾', candidates: ['心皮'], positions: [3]),
        item('心脾。', candidates: ['心皮', '心皮（？）'], count: 2, positions: [9]),
      ]);
      expect(r.all.length, 1);
      final merged = r.all.single;
      expect(merged.candidates, containsAll(['心皮', '心皮（？）']));
      expect(merged.count, 3);
      expect(merged.positions, [3, 9]);
    });

    test('包含关系且只差一两个字时合并，保留更长的那条', () {
      final r = PendingBudget.trim([
        item('洛必达', candidates: ['洛必达法则']),
        item('洛必达法', candidates: ['洛必达法则']),
      ]);
      expect(r.all.length, 1);
      expect(r.all.single.snippet, '洛必达法');
    });

    test('长度差超过 2 的包含关系不合并（语境不同）', () {
      final r = PendingBudget.trim([
        item('心皮', candidates: ['心皮']),
        item('离生心皮', candidates: ['离生心皮']),
      ]);
      expect(r.all.length, 2);
    });
  });

  group('排序', () {
    test('候选命中高优术语排最前，其次反复出现，再次候选唯一', () {
      final r = PendingBudget.trim(
        [
          item('常见词', candidates: ['a', 'b']),
          item('木兰棵', candidates: ['木兰科']),
          item('反复错', candidates: ['对'], count: 3),
          item('普通', candidates: ['普通2']),
        ],
        highPriorityTerms: {'木兰科'},
      );
      expect(r.all.map((e) => e.snippet).toList(),
          ['木兰棵', '反复错', '普通', '常见词']);
    });

    test('原文已经是正确写法、候选又不是高优术语的，不享受加分', () {
      // 回归：之前是拿 snippet 去 contains(术语)，会把误报排到第一
      final r = PendingBudget.trim(
        [
          item('木兰科', candidates: ['木兰颗']),
          item('反复错', candidates: ['对'], count: 3),
        ],
        highPriorityTerms: {'木兰科'},
      );
      expect(r.all.first.snippet, '反复错');
    });

    test('误听形式命中高优术语的也加分', () {
      final r = PendingBudget.trim(
        [
          item('心脾', candidates: ['心皮']),
          item('普通错', candidates: ['普通对'], count: 2),
        ],
        highPriorityTerms: {'心皮'},
        highPriorityMisheard: {'心脾'},
      );
      expect(r.all.first.snippet, '心脾');
    });

    test('同分时按出现位置排序', () {
      final r = PendingBudget.trim([
        item('后出现', candidates: ['x'], positions: [50]),
        item('先出现', candidates: ['y'], positions: [5]),
      ]);
      expect(r.all.first.snippet, '先出现');
    });
  });

  group('截断与计数', () {
    test('超过预算只留 5 条，其余计入 suppressed', () {
      final items = List.generate(
        8,
        (i) => item('错误$i', candidates: ['正确$i'], positions: [i]),
      );
      final r = PendingBudget.trim(items);
      expect(r.kept.length, 5);
      expect(r.all.length, 8);
      expect(r.suppressed, 3);
      expect(r.hasSuppressed, isTrue);
    });

    test('模型自报的截断数会累加进来', () {
      final r = PendingBudget.trim(
        [item('错误1', candidates: ['正确1'])],
        modelSuppressed: 4,
      );
      expect(r.kept.length, 1);
      expect(r.suppressed, 4);
    });

    test('不超过预算时 suppressed 为 0', () {
      final r = PendingBudget.trim(
        [item('错误1', candidates: ['正确1'])],
      );
      expect(r.suppressed, 0);
      expect(r.hasSuppressed, isFalse);
    });

    test('空列表不炸', () {
      final r = PendingBudget.trim(const []);
      expect(r.kept, isEmpty);
      expect(r.all, isEmpty);
      expect(r.suppressed, 0);
    });
  });

  test('normalize 去空白与标点、统一小写', () {
    expect(PendingBudget.normalize('Cell  Wall。'), 'cellwall');
  });
}