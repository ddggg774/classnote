// test/graph_canvas_widget_test.dart
// 画布的 widget 级测试：验证「能真的画出来且不崩」。
//
// 布局算法有 26 个几何测试覆盖，但那些证明不了 widget 能渲染。
// 画布涉及 CustomPaint / InteractiveViewer / Matrix4 / TextPainter 缓存，
// 任何一处用错都只在渲染时报错（纯逻辑测试看不见）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/models/mind_graph.dart';
import 'package:classnote/services/tree_layout.dart';
import 'package:classnote/widgets/graph_canvas.dart';

MindGraph _graph({int branches = 3}) => MindGraph(
      root: '木兰科',
      branches: [
        for (var i = 0; i < branches; i++)
          MindGraphNode(
            id: 'b$i',
            title: '分支$i',
            mark: i == 0 ? NodeMark.key : NodeMark.none,
            children: [
              MindGraphNode(
                id: 'b$i-0',
                title: '子节点$i',
                details: const ['一条说明文字'],
                relation: '包含',
              ),
            ],
          ),
      ],
    );

void main() {
  testWidgets('能渲染出画布且不抛异常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: GraphCanvas(graph: _graph()),
          ),
        ),
      ),
    );
    // 首帧布局回调里会做 fitToScreen，需要再 pump 一次
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 画布本体（CustomPaint）与提示文字都在
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.textContaining('双指缩放'), findsOneWidget);
  });

  testWidgets('工具条按钮都在', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: GraphCanvas(graph: _graph()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(Icons.fit_screen), findsOneWidget);
    expect(find.byIcon(Icons.zoom_in), findsOneWidget);
    expect(find.byIcon(Icons.zoom_out), findsOneWidget);
  });

  testWidgets('点「适应屏幕」不崩', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: GraphCanvas(graph: _graph()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(Icons.fit_screen));
    await tester.pump();
    // 仍能正常渲染
    expect(find.textContaining('双指缩放'), findsOneWidget);
  });

  testWidgets('空图显示占位提示而不是崩', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: GraphCanvas(
              graph: MindGraph(root: '空', branches: []),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('还没有思维导图'), findsOneWidget);
  });

  testWidgets('点击节点会触发回调', (tester) async {
    LayoutNode? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: GraphCanvas(
              graph: _graph(branches: 2),
              onNodeTap: (n) => tapped = n,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 用布局算出某个节点的屏幕位置再点它
    final layout = TreeLayoutEngine.layout(_graph(branches: 2));
    final target = layout.nodes.firstWhere((n) => n.depth == 1);

    // 画布内部做了 fitToScreen，位置会有缩放偏移。
    // 这里不反推变换矩阵（脆弱），改为在画布中心附近扫点，
    // 只要点中了任意节点就说明命中链路是通的。
    final canvasRect = tester.getRect(find.byType(GraphCanvas));
    var hitAny = false;
    for (var dx = 0.05; dx < 1.0 && !hitAny; dx += 0.05) {
      for (var dy = 0.05; dy < 1.0 && !hitAny; dy += 0.05) {
        final pos = Offset(
          canvasRect.left + canvasRect.width * dx,
          canvasRect.top + canvasRect.height * dy,
        );
        tapped = null;
        await tester.tapAt(pos);
        await tester.pump(const Duration(milliseconds: 350));
        if (tapped != null) {
          hitAny = true;
        }
      }
    }
    expect(hitAny, isTrue,
        reason: '画布上应该至少有一个节点能被点中');
    if (tapped != null) {
      final t = tapped!;
      expect(t.title, isNotEmpty);
    }
    // 避免未使用变量告警
    expect(target.title, isNotEmpty);
  });

  testWidgets('节点很多的图也能渲染（性能烟测）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            // 11 分支 × 每支 3 子节点
            child: GraphCanvas(graph: _graph(branches: 11)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('双击折叠不崩', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: GraphCanvas(graph: _graph(branches: 3)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final canvasRect = tester.getRect(find.byType(GraphCanvas));
    // 在中心附近双击，无论命中与否都不应该崩
    await tester.tapAt(canvasRect.center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(canvasRect.center);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('双指缩放'), findsOneWidget);
  });
}