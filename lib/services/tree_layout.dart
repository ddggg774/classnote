// lib/services/tree_layout.dart
// 思维导图的层次布局：把 MindGraph 算成每个节点的 (x, y, 宽, 高)。
//
// 【为什么单独抽成纯函数】
// 布局一旦画在画布上就没法单测了。抽出来之后可以断言
// 「子节点在父节点右侧」「父节点垂直居中于子节点」「同层不重叠」
// 这类几何性质——画布出问题时有 90% 的可能是布局算错了。
//
// 【为什么用简化版 Reingold-Tilford】
// 完整版要处理轮廓合并、祖先偏移修正等一堆边界，代码量翻几倍。
// 我们只有 11 个一级分支、几十个节点，用「叶子按行排、父节点居中于子节点」
// 这个简化算法就能得到干净的结果，而且行为可预测、好调试。
//
// 【横向还是纵向】
// 横向展开（深度向右、同层向下）：一级分支竖着排一列，子节点向右生长。
// 这样 11 个分支在竖屏上一眼能数清，符合"先看全局"的诉求。
import 'dart:math' as math;

import '../models/mind_graph.dart';

/// 一个已布局的节点
class LayoutNode {
  /// 对应 MindGraphNode.id
  final String id;
  final String title;

  /// 节点正文（可能为空）
  final List<String> details;

  /// 视觉标记
  final NodeMark mark;

  /// 与父节点的关系
  final String? relation;

  /// 中心点坐标
  final double x;
  final double y;

  final double width;
  final double height;

  /// 层级：0 = 根，1 = 一级分支，2+ = 更深
  final int depth;

  /// 父节点下标（-1 表示根）
  final int parentIndex;

  /// 子节点下标
  final List<int> childIndices;

  const LayoutNode({
    required this.id,
    required this.title,
    this.details = const [],
    this.mark = NodeMark.none,
    this.relation,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.depth,
    required this.parentIndex,
    this.childIndices = const [],
  });

  double get left => x - width / 2;
  double get top => y - height / 2;
  double get right => x + width / 2;
  double get bottom => y + height / 2;

  /// 是否命中某个画布坐标（用于点击/拖拽）
  bool hitTest(double px, double py) =>
      px >= left && px <= right && py >= top && py <= bottom;

  LayoutNode copyWith({double? x, double? y}) => LayoutNode(
        id: id,
        title: title,
        details: details,
        mark: mark,
        relation: relation,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width,
        height: height,
        depth: depth,
        parentIndex: parentIndex,
        childIndices: childIndices,
      );
}

/// 布局结果
class TreeLayout {
  final List<LayoutNode> nodes;

  /// 内容包围盒（用于初始缩放适配屏幕）
  final double minX, minY, maxX, maxY;

  const TreeLayout({
    required this.nodes,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  static const TreeLayout empty = TreeLayout(
    nodes: [],
    minX: 0,
    minY: 0,
    maxX: 0,
    maxY: 0,
  );

  double get width => maxX - minX;
  double get height => maxY - minY;

  bool get isEmpty => nodes.isEmpty;

  int get maxDepth =>
      nodes.isEmpty ? 0 : nodes.map((n) => n.depth).reduce(math.max);
}

/// 布局参数。调这些就能改疏密，不用动算法。
class LayoutConfig {
  /// 节点宽度（固定，保证一行文字不会太挤）
  final double nodeWidth;

  /// 同层垂直间距（节点底部到下一个节点顶部）
  final double rowGap;

  /// 层间水平间距（父节点右边到子节点左边）
  final double columnGap;

  /// 节点内边距（用于估算高度）
  final double padding;

  /// 标题行高
  final double titleLineHeight;

  /// 正文行高
  final double detailLineHeight;

  /// 正文每行最多显示多少条（超出折叠，画布上不展示全部）
  final int maxDetailLines;

  const LayoutConfig({
    this.nodeWidth = 190,
    this.rowGap = 14,
    this.columnGap = 56,
    this.padding = 10,
    this.titleLineHeight = 18,
    this.detailLineHeight = 15,
    this.maxDetailLines = 3,
  });

  static const LayoutConfig standard = LayoutConfig();
}

class TreeLayoutEngine {
  const TreeLayoutEngine._();

  /// 计算布局。
  ///
  /// [collapsed] 里是折叠节点 id：折叠的节点不展开子节点，
  /// 这样用户可以在大图上折掉不关心的分支。
  static TreeLayout layout(
    MindGraph graph, {
    LayoutConfig config = LayoutConfig.standard,
    Set<String> collapsed = const {},
  }) {
    if (graph.branches.isEmpty) return TreeLayout.empty;

    final nodes = <LayoutNode>[];
    // 每个节点先占位，等所有节点加完再回填 childIndices
    final pendingChildren = <int, List<int>>{};

    // 全局游标：下一个叶子节点的中心 y
    var cursorY = 0.0;

    // 返回节点中心 y
    double addNode(
      MindGraphNode node,
      int depth,
      int parentIndex,
      double x,
    ) {
      final index = nodes.length;
      final w = config.nodeWidth;

      // 先占位，children 稍后回填
      nodes.add(LayoutNode(
        id: node.id,
        title: node.title,
        details: node.details,
        mark: node.mark,
        relation: node.relation,
        x: x,
        y: 0,
        width: w,
        height: 40,
        depth: depth,
        parentIndex: parentIndex,
      ));

      final isCollapsed = collapsed.contains(node.id);
      final kids = isCollapsed ? const <MindGraphNode>[] : node.children;

      double y;
      if (kids.isEmpty) {
        // 叶子：占一个行位
        final h = _nodeHeight(node, config, leaf: true);
        y = cursorY + h / 2;
        cursorY += h + config.rowGap;
      } else {
        // 内部节点：先排子节点，再居中于第一个和最后一个子节点之间
        final childYs = <double>[];
        final childIdx = <int>[];
        // x 是父节点中心。父右边缘 = x + w/2，
        // 子节点中心 = 父右边缘 + 间距 + 子半宽 = x + w/2 + gap + w/2 = x + w + gap。
        // 漏掉子半宽会让父子节点重叠 —— 这是踩过的坑。
        final childX = x + config.nodeWidth + config.columnGap;
        for (final child in kids) {
          final before = nodes.length;
          final cy = addNode(child, depth + 1, index, childX);
          childYs.add(cy);
          childIdx.add(before);
        }
        pendingChildren[index] = childIdx;
        y = (childYs.first + childYs.last) / 2;
      }

      nodes[index] = nodes[index].copyWith(x: x, y: y);

      return y;
    }

    // 根节点：MindGraph 存的是 root 字符串 + branches，
    // 布局需要一个真正的根节点才能统一处理，所以这里造一个虚拟根。
    final rootNode = MindGraphNode(
      id: '__root__',
      title: graph.root.trim().isEmpty ? '本课思维导图' : graph.root,
      children: graph.branches,
    );
    addNode(rootNode, 0, -1, 0);

    // 回填 childIndices
    for (var i = 0; i < nodes.length; i++) {
      final kids = pendingChildren[i];
      final node = nodes[i];
      final h = _nodeHeight(
        MindGraphNode(
          id: node.id,
          title: node.title,
          details: node.details,
          mark: node.mark,
          relation: node.relation,
        ),
        config,
        leaf: kids == null || kids.isEmpty,
      );
      nodes[i] = LayoutNode(
        id: node.id,
        title: node.title,
        details: node.details,
        mark: node.mark,
        relation: node.relation,
        x: node.x,
        y: node.y,
        width: node.width,
        height: h,
        depth: node.depth,
        parentIndex: node.parentIndex,
        childIndices: kids ?? const [],
      );
    }

    // 整体平移到左上角从 (0,0) 开始，方便画布适配
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final n in nodes) {
      if (n.left < minX) minX = n.left;
      if (n.top < minY) minY = n.top;
      if (n.right > maxX) maxX = n.right;
      if (n.bottom > maxY) maxY = n.bottom;
    }

    final shifted = nodes.map((n) {
      return LayoutNode(
        id: n.id,
        title: n.title,
        details: n.details,
        mark: n.mark,
        relation: n.relation,
        x: n.x - minX,
        y: n.y - minY,
        width: n.width,
        height: n.height,
        depth: n.depth,
        parentIndex: n.parentIndex,
        childIndices: n.childIndices,
      );
    }).toList();

    return TreeLayout(
      nodes: shifted,
      minX: 0,
      minY: 0,
      maxX: maxX - minX,
      maxY: maxY - minY,
    );
  }

  /// 估算节点高度。这里不做真正的文本排版（那要 TextPainter），
  /// 只用「字符数 / 每行字符数」粗估行数，够用于布局。
  /// 画布渲染时再按实际高度微调，误差在几像素内不影响观感。
  static double _nodeHeight(
    MindGraphNode node,
    LayoutConfig config, {
    required bool leaf,
  }) {
    // 190 宽的节点，13px 字号大约能放 13 个汉字
    const charsPerLine = 13;
    var lines = _estimateLines(node.title, charsPerLine);

    if (leaf && node.details.isNotEmpty) {
      final shown = node.details.take(config.maxDetailLines);
      for (final d in shown) {
        lines += _estimateLines(d, charsPerLine);
      }
    }

    final textHeight =
        lines * config.titleLineHeight + config.padding * 2;
    return math.max(40, textHeight);
  }

  static int _estimateLines(String text, int charsPerLine) {
    if (text.isEmpty) return 1;
    // 中文字符按 1 计，ASCII 按 0.55 计，粗略估算
    var width = 0.0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      width += RegExp(r'[\x00-\x7F]').hasMatch(ch) ? 0.55 : 1.0;
    }
    return math.max(1, (width / charsPerLine).ceil());
  }

 /// 命中测试：返回被点中的最深层节点（后画的在上层，取最后一个命中）
  static LayoutNode? hitTest(TreeLayout layout, double x, double y) {
    for (var i = layout.nodes.length - 1; i >= 0; i--) {
      if (layout.nodes[i].hitTest(x, y)) return layout.nodes[i];
    }
    return null;
  }
}