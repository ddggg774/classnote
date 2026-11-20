// lib/widgets/mind_graph_tree.dart
// 详细思维导图的树形浏览器（主图 + 子图两层视图）。
//
// 为什么是树形而不是放射状画布：
//   3–5 级 + 每节点带说明/关系/来源，在手机小屏上画放射导图必然挤成一团，
//   反而看不清。树形可折叠列表能完整读完，也方便复制。
//   要"图"的时候导出 Markmap HTML / Markdown 去 XMind 里画，比 App 内自绘更专业。
//
// 视觉编码（与 mind_graph.dart、提示词保持同一套）：
//   ★ 重点   ▲ 难点   ⚠ 易错   ◆ 考点   ❓ 待确认   「」老师原话
import 'package:material_ui/material_ui.dart';

import '../models/mind_graph.dart';

/// 主图：只显示课程主题 + 11 个一级分支，点击进入子图
class MindGraphOverview extends StatelessWidget {
  final MindGraph graph;
  final void Function(MindGraphNode branch) onBranchTap;

  const MindGraphOverview({
    super.key,
    required this.graph,
    required this.onBranchTap,
  });

  @override
  Widget build(BuildContext context) {
    final missing = graph.missingRequiredBranches;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 中心主题
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Colors.indigo, Colors.indigoAccent]),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Text(
                graph.root,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '${graph.branches.length} 个分支 · ${graph.totalNodes} 个节点 · '
                '最深 ${graph.maxDepth} 级',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ...graph.branches.asMap().entries.map((e) {
          final b = e.value;
          final isEmpty = b.children.isEmpty && b.details.isEmpty;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: isEmpty
                    ? Colors.grey.shade200
                    : Colors.indigo.shade50,
                child: Text(
                  '${e.key + 1}',
                  style: TextStyle(
                    fontSize: 13,
                    color: isEmpty ? Colors.grey : Colors.indigo,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Row(
                children: [
                  if (b.mark != NodeMark.none) ...[
                    Text(b.mark.symbol,
                        style: TextStyle(
                            color: _markColor(b.mark), fontSize: 13)),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      b.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isEmpty ? Colors.grey : null,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: Text(
                isEmpty
                    ? '未提及'
                    : '${b.totalCount - 1} 个子节点'
                        '${_detailCount(b) > 0 ? ' · ${_detailCount(b)} 条说明' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: isEmpty ? Colors.grey.shade500 : Colors.grey.shade600,
                ),
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              enabled: !isEmpty,
              onTap: isEmpty ? null : () => onBranchTap(b),
            ),
          );
        }),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Text(
              '以下分支本次未生成：${missing.join('、')}\n'
              '可点「重新总结」补全。',
              style: TextStyle(color: Colors.orange.shade900, fontSize: 12.5),
            ),
          ),
        ],
      ],
    );
  }

  static int _detailCount(MindGraphNode n) {
    var c = n.details.length;
    for (final child in n.children) {
      c += _detailCount(child);
    }
    return c;
  }

  static Color _markColor(NodeMark m) {
    switch (m) {
      case NodeMark.key:
        return Colors.orange.shade700;
      case NodeMark.hard:
        return Colors.deepPurple;
      case NodeMark.pitfall:
        return Colors.red.shade600;
      case NodeMark.exam:
        return Colors.blue.shade700;
      case NodeMark.unconfirmed:
        return Colors.amber.shade800;
      case NodeMark.quote:
        return Colors.teal;
      case NodeMark.none:
        return Colors.grey;
    }
  }
}

/// 子图：某个一级分支下的完整层级，用可折叠的缩进树展示
class MindGraphSubtree extends StatelessWidget {
  final MindGraphNode branch;

  const MindGraphSubtree({super.key, required this.branch});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: _buildNode(branch, 0),
    );
  }

  List<Widget> _buildNode(MindGraphNode node, int level) {
    final widgets = <Widget>[];

    widgets.add(Padding(
      padding: EdgeInsets.only(left: level * 14.0, top: level == 0 ? 0 : 2),
      child: _NodeTile(node: node, level: level),
    ));

    for (final child in node.children) {
      widgets.addAll(_buildNode(child, level + 1));
    }
    return widgets;
  }
}

class _NodeTile extends StatefulWidget {
  final MindGraphNode node;
  final int level;

  const _NodeTile({required this.node, required this.level});

  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile> {
  // 默认展开前两级，更深的级别折叠起来，避免一屏塞满
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    _expanded = widget.level < 2;
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final hasChildren = node.children.isNotEmpty;
    final color = _markColor(node.mark);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: hasChildren
              ? () => setState(() => _expanded = !_expanded)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 层级指示
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(
                    hasChildren
                        ? (_expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right)
                        : Icons.circle,
                    size: hasChildren ? 18 : 6,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (node.mark != NodeMark.none) ...[
                            Text(node.mark.symbol,
                                style: TextStyle(color: color, fontSize: 13)),
                            const SizedBox(width: 3),
                          ],
                          Expanded(
                            child: Text(
                              node.title,
                              style: TextStyle(
                                fontSize: widget.level == 0 ? 15 : 13.8,
                                fontWeight: widget.level == 0
                                    ? FontWeight.bold
                                    : FontWeight.w600,
                                height: 1.4,
                              ),
                            ),
                          ),
                          if (node.relation != null) ...[
                            const SizedBox(width: 6),
                            _RelationChip(relation: node.relation!),
                          ],
                        ],
                      ),
                      if (node.details.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        ...node.details.map((d) => Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '· $d',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.5,
                                  color: Colors.grey.shade800,
                                ),
                              ),
                            )),
                      ],
                      if (node.source != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.history,
                                size: 11, color: Colors.grey.shade500),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                node.source!,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade600,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasChildren && !_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 4),
            child: Text(
              '（已折叠 ${node.children.length} 个下级节点）',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ),
      ],
    );
  }

  static Color _markColor(NodeMark m) {
    switch (m) {
      case NodeMark.key:
        return Colors.orange.shade700;
      case NodeMark.hard:
        return Colors.deepPurple;
      case NodeMark.pitfall:
        return Colors.red.shade600;
      case NodeMark.exam:
        return Colors.blue.shade700;
      case NodeMark.unconfirmed:
        return Colors.amber.shade800;
      case NodeMark.quote:
        return Colors.teal;
      case NodeMark.none:
        return Colors.grey;
    }
  }
}

/// 关系标签：前提 / 推导 / 因果 / 对比 / 包含 / 易错 / 考试相关
class _RelationChip extends StatelessWidget {
  final String relation;
  const _RelationChip({required this.relation});

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(relation);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        relation,
        style: TextStyle(fontSize: 10, color: color, height: 1.3),
      ),
    );
  }

  static Color _colorFor(String r) {
    switch (r) {
      case '前提':
        return Colors.blueGrey;
      case '推导':
        return Colors.indigo;
      case '因果':
        return Colors.teal;
      case '对比':
        return Colors.purple;
      case '包含':
        return Colors.grey.shade600;
      case '易错':
        return Colors.red.shade600;
      case '考试相关':
        return Colors.blue.shade700;
      default:
        return Colors.grey.shade600;
    }
  }
}