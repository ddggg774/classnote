// test/tree_layout_test.dart
// 层次布局的几何性质测试。
//
// 布局是纯函数，能断言的都是几何关系：
//   · 子节点在父节点右侧（深度向右生长）
//   · 父节点垂直居中于首尾子节点之间
//   · 同层节点不重叠（行距生效）
//   · 包围盒覆盖所有节点
//   · 折叠的节点不展开子节点
// 画布上"节点叠在一起""连线穿节点"这类问题，根因基本都在这里。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/mind_graph.dart';
import 'package:classnote/services/tree_layout.dart';

MindGraph _graph({int branchCount = 3, int childrenPerBranch = 2}) {
  return MindGraph(
    root: '木兰科',
    branches: [
      for (var i = 0; i < branchCount; i++)
        MindGraphNode(
          id: 'b$i',
          title: '分支$i',
          details: const ['说明一', '说明二'],
          children: [
            for (var j = 0; j < childrenPerBranch; j++)
              MindGraphNode(
                id: 'b$i-$j',
                title: '子节点$i-$j',
                details: const ['细节'],
                children: [
                  MindGraphNode(id: 'b$i-$j-0', title: '孙节点$i-$j-0'),
                ],
              ),
          ],
        ),
    ],
  );
}

void main() {
  group('基本结构', () {
    test('空图画出来是空布局', () {
      final layout = TreeLayoutEngine.layout(
        const MindGraph(root: '空', branches: []),
      );
      expect(layout.isEmpty, isTrue);
      expect(layout.nodes, isEmpty);
      expect(TreeLayout.empty.isEmpty, isTrue);
    });

    test('节点数 = 根 + 所有后代', () {
      final layout = TreeLayoutEngine.layout(
        _graph(branchCount: 3, childrenPerBranch: 2),
      );
      // 1 根 + 3 分支 + 3*2 子 + 3*2 孙 = 16
      expect(layout.nodes.length, 16);
    });

    test('根节点 depth=0 且 parentIndex=-1', () {
      final layout = TreeLayoutEngine.layout(_graph());
      final root = layout.nodes.first;
      expect(root.depth, 0);
      expect(root.parentIndex, -1);
      expect(root.title, '木兰科');
    });

    test('maxDepth 反映真实最深层级', () {
      final layout = TreeLayoutEngine.layout(
        _graph(branchCount: 1, childrenPerBranch: 1),
      );
      // 根(0) → 分支(1) → 子(2) → 孙(3)
      expect(layout.maxDepth, 3);
    });

    test('childIndices 指向真的子节点', () {
      final layout = TreeLayoutEngine.layout(
        _graph(branchCount: 2, childrenPerBranch: 2),
      );
      for (final n in layout.nodes) {
        for (final ci in n.childIndices) {
          expect(layout.nodes[ci].parentIndex, layout.nodes.indexOf(n));
        }
      }
    });
  });

  group('几何性质', () {
    test('子节点在父节点右侧（不重叠）', () {
      final layout = TreeLayoutEngine.layout(_graph());
      for (final n in layout.nodes) {
        for (final ci in n.childIndices) {
          final child = layout.nodes[ci];
          expect(child.left, greaterThanOrEqualTo(n.right),
              reason: '子节点 ${child.title} 应该完全在父节点 ${n.title} 右侧');
        }
      }
    });

    test('深度越大 x 越大', () {
      final layout = TreeLayoutEngine.layout(_graph());
      final byDepth = <int, List<double>>{};
      for (final n in layout.nodes) {
        byDepth.putIfAbsent(n.depth, () => []).add(n.x);
      }
      final depths = byDepth.keys.toList()..sort();
      for (var i = 1; i < depths.length; i++) {
        final prevMax = byDepth[depths[i - 1]]!.reduce((a, b) => a > b ? a : b);
        final curMin = byDepth[depths[i]]!.reduce((a, b) => a < b ? a : b);
        expect(curMin, greaterThan(prevMax),
            reason: '第 ${depths[i]} 层应该比第 ${depths[i - 1]} 层更靠右');
      }
    });

    test('父节点垂直居中于首尾子节点之间', () {
      final layout = TreeLayoutEngine.layout(_graph());
      for (final n in layout.nodes.where((n) => n.childIndices.length >= 2)) {
        final first = layout.nodes[n.childIndices.first];
        final last = layout.nodes[n.childIndices.last];
        final expected = (first.y + last.y) / 2;
        expect(n.y, closeTo(expected, 0.01),
            reason: '${n.title} 应该垂直居中于子节点');
      }
    });

    test('单子节点的父节点与子节点同一 y', () {
      final layout = TreeLayoutEngine.layout(
        _graph(branchCount: 2, childrenPerBranch: 1),
      );
      for (final n in layout.nodes.where((n) => n.childIndices.length == 1)) {
        final child = layout.nodes[n.childIndices.first];
        expect(n.y, closeTo(child.y, 0.01));
      }
    });

    test('同层节点不重叠（垂直方向）', () {
      final layout = TreeLayoutEngine.layout(_graph());
      final byDepth = <int, List<LayoutNode>>{};
      for (final n in layout.nodes) {
        byDepth.putIfAbsent(n.depth, () => []).add(n);
      }
      for (final entry in byDepth.entries) {
        final list = [...entry.value]..sort((a, b) => a.y.compareTo(b.y));
        for (var i = 1; i < list.length; i++) {
          expect(list[i].top, greaterThanOrEqualTo(list[i - 1].bottom),
              reason: '第 ${entry.key} 层的节点重叠了');
        }
      }
    });

    test('包围盒覆盖所有节点', () {
      final layout = TreeLayoutEngine.layout(_graph());
      for (final n in layout.nodes) {
        expect(n.left, greaterThanOrEqualTo(layout.minX - 0.01));
        expect(n.top, greaterThanOrEqualTo(layout.minY - 0.01));
        expect(n.right, lessThanOrEqualTo(layout.maxX + 0.01));
        expect(n.bottom, lessThanOrEqualTo(layout.maxY + 0.01));
      }
    });

    test('包围盒从原点开始（已平移）', () {
      final layout = TreeLayoutEngine.layout(_graph());
      expect(layout.minX, 0);
      expect(layout.minY, 0);
      expect(layout.width, greaterThan(0));
      expect(layout.height, greaterThan(0));
    });

    test('节点尺寸不超过配置宽度', () {
      final layout = TreeLayoutEngine.layout(_graph());
      for (final n in layout.nodes) {
        expect(n.width, LayoutConfig.standard.nodeWidth);
        expect(n.height, greaterThanOrEqualTo(40));
      }
    });
  });

  group('折叠', () {
    test('折叠的分支不展开子节点', () {
      final full = TreeLayoutEngine.layout(_graph());
      final collapsedLayout = TreeLayoutEngine.layout(
        _graph(),
        collapsed: {'b0'},
      );
      expect(collapsedLayout.nodes.length, lessThan(full.nodes.length));
      // 折叠节点的 childIndices 应为空
      final b0 = collapsedLayout.nodes.firstWhere((n) => n.id == 'b0');
      expect(b0.childIndices, isEmpty);
    });

    test('折叠后其他分支不受影响', () {
      final layout = TreeLayoutEngine.layout(_graph(), collapsed: {'b0'});
      expect(layout.nodes.any((n) => n.id == 'b1'), isTrue);
      expect(layout.nodes.any((n) => n.id == 'b0-0'), isFalse);
      expect(layout.nodes.any((n) => n.id == 'b1-0'), isTrue);
    });

    test('折叠根节点只剩一个节点', () {
      final layout =
          TreeLayoutEngine.layout(_graph(), collapsed: {'__root__'});
      expect(layout.nodes.length, 1);
      expect(layout.nodes.first.depth, 0);
    });
  });

  group('命中测试', () {
    test('点中节点返回该节点', () {
      final layout = TreeLayoutEngine.layout(_graph());
      final target = layout.nodes[3];
      final hit = TreeLayoutEngine.hitTest(layout, target.x, target.y);
      expect(hit?.id, target.id);
    });

    test('点在空白处返回 null', () {
      final layout = TreeLayoutEngine.layout(_graph());
      final hit = TreeLayoutEngine.hitTest(layout, -9999, -9999);
      expect(hit, isNull);
    });

    test('点在节点外边框之内仍算命中', () {
      final layout = TreeLayoutEngine.layout(_graph());
      final n = layout.nodes.first;
      expect(TreeLayoutEngine.hitTest(layout, n.left + 1, n.top + 1)?.id, n.id);
      expect(
          TreeLayoutEngine.hitTest(layout, n.right - 1, n.bottom - 1)?.id, n.id);
    });

    test('空布局命中测试不崩', () {
      expect(
        TreeLayoutEngine.hitTest(TreeLayout.empty, 0, 0),
        isNull,
      );
    });
  });

  group('配置可调', () {
    test('加大间距后整体尺寸变大', () {
      final tight = TreeLayoutEngine.layout(_graph());
      final loose = TreeLayoutEngine.layout(
        _graph(),
        config: const LayoutConfig(rowGap: 60, columnGap: 120),
      );
      expect(loose.height, greaterThan(tight.height));
      expect(loose.width, greaterThan(tight.width));
    });

    test('节点变窄后文本换行更多、整体更高', () {
      final wide = TreeLayoutEngine.layout(
        _graph(),
        config: const LayoutConfig(nodeWidth: 240),
      );
      final narrow = TreeLayoutEngine.layout(
        _graph(),
        config: const LayoutConfig(nodeWidth: 110),
      );
      // 窄节点按字数估行数会更多，高度应该更大或至少不更小
      expect(narrow.height, greaterThanOrEqualTo(wide.height * 0.9));
    });

    test('maxDetailLines=0 时节点更矮', () {
      final withDetails = TreeLayoutEngine.layout(_graph());
      final noDetails = TreeLayoutEngine.layout(
        _graph(),
        config: const LayoutConfig(maxDetailLines: 0),
      );
      expect(noDetails.height, lessThanOrEqualTo(withDetails.height));
    });
  });

  group('真实规模的图（11 分支 40+ 节点）', () {
    /// 造一棵接近真实产出的图：11 个一级分支，每个 3 个子节点，部分带孙节点
    MindGraph realish() => MindGraph(
          root: '植物学 木兰科',
          branches: [
            for (var i = 0; i < 11; i++)
              MindGraphNode(
                id: 'b$i',
                title: MindGraph.requiredBranches[i % 11],
                details: const ['要点一', '要点二'],
                children: [
                  for (var j = 0; j < 3; j++)
                    MindGraphNode(
                      id: 'b$i-$j',
                      title: '节点$i-$j',
                      details: const ['说明'],
                      children: j == 0
                          ? [MindGraphNode(id: 'b$i-$j-0', title: '细节')]
                          : const [],
                    ),
                ],
              ),
          ],
        );

    test('节点数符合预期', () {
      final layout = TreeLayoutEngine.layout(realish());
      // 1 + 11 + 11*3 + 11 = 56
      expect(layout.nodes.length, 56);
      expect(layout.maxDepth, 3);
    });

    test('规模变大后依然满足不重叠与右侧约束', () {
      final layout = TreeLayoutEngine.layout(realish());
      final byDepth = <int, List<LayoutNode>>{};
      for (final n in layout.nodes) {
        byDepth.putIfAbsent(n.depth, () => []).add(n);
      }
      for (final entry in byDepth.entries) {
        final list = [...entry.value]..sort((a, b) => a.y.compareTo(b.y));
        for (var i = 1; i < list.length; i++) {
          expect(list[i].top, greaterThanOrEqualTo(list[i - 1].bottom));
        }
      }
      for (final n in layout.nodes) {
        for (final ci in n.childIndices) {
          expect(layout.nodes[ci].left, greaterThanOrEqualTo(n.right));
        }
      }
    });

    test('整体尺寸合理（不会大到无法观看）', () {
      final layout = TreeLayoutEngine.layout(realish());
      // 纵向 56 个节点量级，横向 4 层
      expect(layout.height, greaterThan(500));
      expect(layout.height, lessThan(4000));
      expect(layout.width, greaterThan(400));
      expect(layout.width, lessThan(2000));
    });
  });
}