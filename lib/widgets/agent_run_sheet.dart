// lib/widgets/agent_run_sheet.dart
// 「一键处理」的运行面板：实时显示 Agent 每一步在干什么。
//
// 【为什么必须做这个界面】
// Agent 跑一次要几十秒到几分钟（转写 + 纠错 + 总结 + 导图，串行）。
// 如果只给一个 spinner，用户会以为卡死，中途退出还会白花钱。
// 所以这里把 AgentStep 的每一步实时吐出来：做了什么、成功还是失败、耗时多少。
// 用户随时能看出"它在动"，失败了也能看到卡在哪一步。
//
// 【为什么允许中途取消】
// 步数上限 10，最坏情况跑满可能几分钟。取消不是"撤销已花的钱"，
// 而是止损——不让它继续往下烧。已完成的步骤结果仍然保留。
import 'package:material_ui/material_ui.dart';

import '../agent/agent_loop.dart';
import '../agent/classroom_agent.dart';
import '../models/summary_level.dart';

/// 一键处理的档位选项（含是否要导图）
class QuickRunOptions {
  final SummaryLevel level;
  final bool wantMindMap;

  const QuickRunOptions({
    this.level = SummaryLevel.normal,
    this.wantMindMap = true,
  });
}

class AgentRunSheet extends StatefulWidget {
  final ClassroomAgent agent;
  final ClassroomRequest request;

  const AgentRunSheet({
    super.key,
    required this.agent,
    required this.request,
  });

  @override
  State<AgentRunSheet> createState() => _AgentRunSheetState();
}

class _AgentRunSheetState extends State<AgentRunSheet> {
  final List<AgentStep> _steps = [];
  bool _running = true;
  bool _cancelled = false;
  ClassroomResult? _result;
  String? _error;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final result = await widget.agent.run(
        widget.request,
        onStep: (step) {
          if (!mounted) return;
          setState(() => _steps.add(step));
          // 自动滚到底，让用户总能看到最新一步
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.animateTo(
                _scroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _running = false;
        if (_cancelled) _error = '已取消（已完成的步骤结果保留）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 运行中禁止手势返回，避免误触丢掉进度显示
      canPop: !_running,
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        builder: (context, sheetScroll) {
          return Column(
            children: [
              // 顶部标题栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    if (_running)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        _error == null ? Icons.check_circle : Icons.info_outline,
                        size: 18,
                        color: _error == null
                            ? Colors.green.shade600
                            : Colors.orange.shade700,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _running
                            ? 'AI 正在处理（第 ${_steps.length} 步）…'
                            : (_error == null ? '处理完成' : _error!),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _error == null ? null : Colors.orange.shade900,
                        ),
                      ),
                    ),
                    if (_running)
                      TextButton(
                        onPressed: _cancel,
                        child: const Text('取消', style: TextStyle(fontSize: 13)),
                      )
                    else
                      TextButton(
                        onPressed: () => Navigator.pop(context, _result),
                        child: const Text('完成'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),

              // 步骤日志
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: _steps.length,
                  itemBuilder: (context, i) => _StepTile(step: _steps[i]),
                ),
              ),

              // 完成后显示结果摘要
              if (!_running && _result != null)
                _ResultSummary(result: _result!),
            ],
          );
        },
      ),
    );
  }

  void _cancel() {
    setState(() {
      _cancelled = true;
      _running = false;
      _error = '已取消。已完成的步骤结果仍会保留。';
    });
    // 无法真正中断进行中的 HTTP 请求，只能让界面先停下来。
    // 关掉页面本身不会浪费已经发出的这一次调用，但会阻止后续步骤继续。
    Navigator.pop(context, _result);
  }
}

/// 单步日志
class _StepTile extends StatelessWidget {
  final AgentStep step;
  const _StepTile({required this.step});

  @override
  Widget build(BuildContext context) {
    final ok = step.success;
    final color = ok ? Colors.green.shade700 : Colors.red.shade600;
    final label = _labelOf(step);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 15,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${step.elapsed.inMilliseconds}ms',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500),
                    ),
                  ],
                ),
                if (step.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      step.summary,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 把工具名翻成人话，用户不该看到 transcribe 这种内部名称
  static String _labelOf(AgentStep step) {
    if (step.kind == 'final') return '生成结论';
    if (step.kind == 'error') return '出错';
    switch (step.toolName) {
      case 'transcribe':
        return '语音转写';
      case 'run_correction_agent':
        return '术语纠错';
      case 'summarize':
        return '生成总结';
      case 'generate_mindmap':
        return '生成思维导图';
      default:
        return step.toolName ?? step.kind;
    }
  }
}

/// 结果摘要卡片
class _ResultSummary extends StatelessWidget {
  final ClassroomResult result;
  const _ResultSummary({required this.result});

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String text, Color color})>[];

    if (result.transcript != null) {
      items.add((
        icon: Icons.mic_none,
        text: '转写 ${result.transcript!.length} 字',
        color: Colors.indigo,
      ));
    }
    if (result.hasSummary) {
      items.add((
        icon: Icons.article_outlined,
        text: '总结 ${result.summary!.length} 字'
            '${result.level != null ? '（${result.level!.label}档）' : ''}',
        color: Colors.teal,
      ));
    }
    if (result.graph != null && result.graph!.branches.isNotEmpty) {
      items.add((
        icon: Icons.account_tree_outlined,
        text: '导图 ${result.graph!.branches.length} 分支 / '
            '${result.graph!.totalNodes} 节点',
        color: Colors.deepPurple,
      ));
    }
    if (result.pendingNotes.isNotEmpty) {
      items.add((
        icon: Icons.help_outline,
        text: '待确认 ${result.pendingNotes.length} 处',
        color: Colors.orange.shade800,
      ));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...items.map((it) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  children: [
                    Icon(it.icon, size: 14, color: it.color),
                    const SizedBox(width: 6),
                    Text(it.text,
                        style: TextStyle(fontSize: 12.5, color: it.color)),
                  ],
                ),
              )),
          if (result.pendingNotes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '待确认内容需要你回听核对：',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
            ),
            ...result.pendingNotes.take(3).map((n) => Padding(
                  padding: const EdgeInsets.only(top: 2, left: 20),
                  child: Text(
                    '· $n',
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade700),
                  ),
                )),
            if (result.pendingNotes.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 20),
                child: Text(
                  '…等共 ${result.pendingNotes.length} 处',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ),
          ],
        ],
      ),
    );
  }
}