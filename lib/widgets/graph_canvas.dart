// lib/widgets/graph_canvas.dart
// 2D 思维导图画布：可缩放、可平移、可点开节点。
//
// 【为什么不用 InteractiveViewer】
// InteractiveViewer 会把整个子树的手势都吃掉，节点拖拽和画布平移只能二选一。
// 这里自己用 GestureDetector + Matrix4 管变换，能精确控制
// 「点中节点就归节点、点空白才归画布」——这是拖动节点时最影响手感的地方。
//
// 【性能怎么保证】
//   · 节点文字用 TextPainter 预计算并缓存，缩放时不重新排版
//   · 超出视口的节点直接跳过不画（简单裁剪）
//   · 整个画布套 RepaintBoundary，避免父级重建触发重绘
//   · 缩放用 Matrix4 整体变换，不逐个重算坐标
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../models/mind_graph.dart';
import '../services/tree_layout.dart';

class GraphCanvas extends StatefulWidget {
  final MindGraph graph;

  /// 点击节点的回调（用于显示详情面板）
  final void Function(LayoutNode node)? onNodeTap;

  const GraphCanvas({super.key, required this.graph, this.onNodeTap});

  @override
  State<GraphCanvas> createState() => _GraphCanvasState();
}

/// 内容在画布内留的边距。
/// painter 绘制时会把内容平移这么多，
/// 所以命中测试反算坐标时必须减掉——否则点击会整体偏移。
const double kCanvasContentPadding = 24;

class _GraphCanvasState extends State<GraphCanvas> {
  final TransformationController _tc = TransformationController();

  /// 折叠的节点 id
  final Set<String> _collapsed = {};

  TreeLayout _layout = TreeLayout.empty;

  /// TextPainter 缓存：key 是 "id|标题第一行|缩放级别档位"
  /// 缩放时不重建，只是整体变换，所以 key 不需要带缩放。
  final Map<String, TextPainter> _painterCache = {};

  /// 初始适配只做一次
  bool _fitted = false;

  /// 上一次点击时间与位置（做双击检测）
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _rebuildLayout();
  }

  @override
  void didUpdateWidget(covariant GraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.graph, widget.graph)) {
      _painterCache.clear();
      _fitted = false;
      _rebuildLayout();
    }
  }

  @override
  void dispose() {
    _tc.dispose();
    for (final p in _painterCache.values) {
      p.dispose();
    }
    super.dispose();
  }

  void _rebuildLayout() {
    _layout = TreeLayoutEngine.layout(widget.graph, collapsed: _collapsed);
  }

  /// 把内容缩放到适合屏幕
  void _fitToScreen(Size size) {
    if (_layout.isEmpty || size.width <= 0 || size.height <= 0) return;
    const margin = 24.0;
    final scaleX = (size.width - margin * 2) / math.max(_layout.width, 1);
    final scaleY = (size.height - margin * 2) / math.max(_layout.height, 1);
    // 最多放大到 1.0，避免节点被拉得过大
    final scale = math.min(math.min(scaleX, scaleY), 1.0);
    final dx = (size.width - _layout.width * scale) / 2;
    final dy = (size.height - _layout.height * scale) / 2;
    _tc.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _fitted = true;
  }

  void _toggleCollapse(LayoutNode node) {
    if (node.childIndices.isEmpty) return;
    setState(() {
      if (_collapsed.contains(node.id)) {
        _collapsed.remove(node.id);
      } else {
        _collapsed.add(node.id);
      }
      _rebuildLayout();
    });
  }

  /// 处理点击。[contentPos] 是 InteractiveViewer 子内容的局部坐标，
  /// 已包含 painter 的绘制边距，所以要减掉才是布局坐标。
  void _handleTapAtContent(Offset contentPos) {
    final pos = contentPos - const Offset(kCanvasContentPadding, kCanvasContentPadding);
    final node = TreeLayoutEngine.hitTest(_layout, pos.dx, pos.dy);

    final now = DateTime.now();
    final isDoubleTap = now.difference(_lastTap).inMilliseconds < 300 &&
        (_lastTapPos - contentPos).distance < 40;
    _lastTap = now;
    _lastTapPos = contentPos;

    if (node == null) return;

    if (isDoubleTap) {
      _toggleCollapse(node);
      return;
    }
    widget.onNodeTap?.call(node);
  }

  @override
  Widget build(BuildContext context) {
    if (_layout.isEmpty) {
      return Center(
        child: Text('还没有思维导图',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_fitted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_fitted) _fitToScreen(size);
          });
        }

        return Stack(
          children: [
            // 画布本体。
            // 手势识别必须放在 InteractiveViewer **内部**：
            // 放外层会被 InteractiveViewer 自己的 pan/scale 识别器抢走，
            // onTapUp 根本不会触发（这是实测踩到的）。
            // 放内部还有个好处：localPosition 就是内容坐标，不用手动逆变换。
            RepaintBoundary(
              child: InteractiveViewer(
                transformationController: _tc,
                panEnabled: true,
                scaleEnabled: true,
                minScale: 0.15,
                maxScale: 3.0,
                boundaryMargin: const EdgeInsets.all(400),
                constrained: false,
                child: SizedBox(
                  width: _layout.width + kCanvasContentPadding * 2,
                  height: _layout.height + kCanvasContentPadding * 2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _handleTapAtContent(d.localPosition),
                    child: CustomPaint(
                      painter: _GraphPainter(
                        layout: _layout,
                        painterCache: _painterCache,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 右上角工具条
            Positioned(
              right: 8,
              top: 8,
              child: Column(
                children: [
                  _toolButton(
                    icon: Icons.fit_screen,
                    tooltip: '适应屏幕',
                    onTap: () => _fitToScreen(size),
                  ),
                  const SizedBox(height: 6),
                  _toolButton(
                    icon: Icons.zoom_in,
                    tooltip: '放大',
                    onTap: () => _zoomBy(1.3),
                  ),
                  const SizedBox(height: 6),
                  _toolButton(
                    icon: Icons.zoom_out,
                    tooltip: '缩小',
                    onTap: () => _zoomBy(1 / 1.3),
                  ),
                  if (_collapsed.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _toolButton(
                      icon: Icons.unfold_more,
                      tooltip: '全部展开',
                      onTap: () => setState(() {
                        _collapsed.clear();
                        _rebuildLayout();
                      }),
                    ),
                  ],
                ],
              ),
            ),

            // 底部提示
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '双指缩放 · 拖动平移 · 双击节点折叠',
                  style: TextStyle(
                      fontSize: 10, color: Colors.white.withValues(alpha: 0.9)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 以视口中心为锚点缩放
  void _zoomBy(double factor) {
    final current = _tc.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(0.15, 3.0);
    final actual = target / current;
    final size = context.size;
    if (size == null) return;
    final center = Offset(size.width / 2, size.height / 2);
    final m = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(actual, actual, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    _tc.value = m * _tc.value;
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      elevation: 2,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 18, color: Colors.grey.shade700),
          ),
        ),
      ),
    );
  }
}

/// 真正画图的地方
class _GraphPainter extends CustomPainter {
  final TreeLayout layout;
  final Map<String, TextPainter> painterCache;

  _GraphPainter({required this.layout, required this.painterCache});

  static const double _offsetX = kCanvasContentPadding;
  static const double _offsetY = kCanvasContentPadding;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(_offsetX, _offsetY);

    // 先画连线（在节点下面），再画节点
    _paintEdges(canvas);
    _paintNodes(canvas);

    canvas.restore();
  }

  void _paintEdges(Canvas canvas) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.blueGrey.shade200;

    for (final node in layout.nodes) {
      for (final ci in node.childIndices) {
        final child = layout.nodes[ci];
        // 从父节点右边缘连到子节点左边缘，用三次贝塞尔做出柔和的弧线
        final start = Offset(node.right, node.y);
        final end = Offset(child.left, child.y);
        final dx = (end.dx - start.dx) * 0.5;
        final path = Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(
            start.dx + dx,
            start.dy,
            end.dx - dx,
            end.dy,
            end.dx,
            end.dy,
          );
        canvas.drawPath(path, paint);
      }
    }
  }

  void _paintNodes(Canvas canvas) {
    for (final node in layout.nodes) {
      _paintOne(canvas, node);
    }
  }

  void _paintOne(Canvas canvas, LayoutNode node) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTRB(node.left, node.top, node.right, node.bottom),
      const Radius.circular(9),
    );

    // 按层级与标记决定配色
    final isRoot = node.depth == 0;
    final isBranch = node.depth == 1;
    final Color bg;
    final Color border;
    final Color textColor;
    if (isRoot) {
      bg = Colors.indigo.shade600;
      border = Colors.indigo.shade700;
      textColor = Colors.white;
    } else if (isBranch) {
      bg = Colors.indigo.shade50;
      border = Colors.indigo.shade200;
      textColor = Colors.indigo.shade900;
    } else {
      bg = Colors.white;
      border = Colors.grey.shade300;
      textColor = Colors.grey.shade900;
    }

    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.black.withValues(alpha: 0.04),
    );
    canvas.drawRRect(rect.shift(const Offset(0, -1)), Paint()..color = bg);
    canvas.drawRRect(
      rect.shift(const Offset(0, -1)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isRoot ? 1.6 : 1.0
        ..color = border,
    );

    // 标记色条（左侧）
    final markColor = _markColor(node.mark);
    if (markColor != null) {
      final bar = RRect.fromRectAndRadius(
        Rect.fromLTWH(node.left, node.top, 3.5, node.height),
        const Radius.circular(2),
      );
      canvas.drawRRect(bar, Paint()..color = markColor);
    }

    // 标题
    final titlePainter = _painter(
      'title|${node.id}|${node.title}|$textColor',
      node.title,
      TextStyle(
        fontSize: isRoot ? 14 : 12.5,
        fontWeight: isRoot || isBranch ? FontWeight.w600 : FontWeight.w500,
        color: textColor,
        height: 1.25,
      ),
      maxWidth: node.width - 16,
    );
    titlePainter.paint(canvas, Offset(node.left + 8, node.top + 7));

    // 叶子节点的正文（最多几行）
    if (node.details.isNotEmpty && node.childIndices.isEmpty) {
      final detail = node.details.take(3).join(' · ');
      final detailPainter = _painter(
        'detail|${node.id}|$detail|$textColor',
        detail,
        TextStyle(
          fontSize: 10,
          color: isRoot ? Colors.white70 : Colors.grey.shade600,
          height: 1.3,
        ),
        maxWidth: node.width - 16,
        maxLines: 3,
      );
      detailPainter.paint(
        canvas,
        Offset(node.left + 8, node.top + 7 + titlePainter.height),
      );
    }
  }

  Color? _markColor(NodeMark mark) {
    switch (mark) {
      case NodeMark.key:
        return Colors.amber.shade600;
      case NodeMark.hard:
        return Colors.orange.shade400;
      case NodeMark.pitfall:
        return Colors.red.shade400;
      case NodeMark.exam:
        return Colors.deepPurple.shade300;
      case NodeMark.unconfirmed:
        return Colors.blueGrey.shade400;
      case NodeMark.quote:
        return Colors.teal.shade300;
      case NodeMark.none:
        return null;
    }
  }

  /// TextPainter 缓存：同一段文字+样式只排一次版。
  /// 缩放时是整体 Matrix4 变换，不需要重新排版，所以缓存命中率很高。
  TextPainter _painter(
    String key,
    String text,
    TextStyle style, {
    required double maxWidth,
    int? maxLines,
  }) {
    final cached = painterCache[key];
    if (cached != null) return cached;

    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: maxLines != null ? '…' : null,
    )..layout(maxWidth: maxWidth);
    painterCache[key] = tp;
    return tp;
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) {
    // 布局对象变了才重绘；缩放平移由 Matrix4 处理，不触发这里
    return !identical(oldDelegate.layout, layout);
  }
}