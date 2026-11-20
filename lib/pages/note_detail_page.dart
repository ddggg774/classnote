// lib/pages/note_detail_page.dart
// 笔记详情页：四个 Tab —— 原文（可编辑）、详细笔记（九段式 Markdown）、
// 思维导图、大纲（结构化的要点列表）。
// "生成总结"按钮调用 AI 服务，一次产出「详细笔记 + 思维导图结构」，存回数据库后分别渲染。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/mind_graph.dart';
import '../models/note.dart';
import '../models/study_note.dart';
import '../services/db_service.dart';
import '../services/ai_service.dart';
import '../services/mind_graph_exporter.dart';
import '../widgets/mind_graph_tree.dart';
import '../widgets/mind_map_widget.dart';

class NoteDetailPage extends StatefulWidget {
  final String noteId;
  const NoteDetailPage({super.key, required this.noteId});

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage>
    with SingleTickerProviderStateMixin {
  final DbService _db = DbService();
  final AiService _ai = AiService();
  final TextEditingController _transcriptController = TextEditingController();

  late TabController _tabController;
  final GlobalKey _captureKey = GlobalKey();
  final ScrollController _detailScroll = ScrollController();
  Note? _note;
  MindMapData? _mindMap;
  /// 3–5 级详细导图（主图+子图）
  MindGraph? _graph;
  /// 当前进入的二级分支；null 表示显示主图
  MindGraphNode? _activeBranch;
  /// 详细课堂笔记正文（九段式 Markdown）。为空表示还没有生成过详细笔记（老数据）。
  String _detailMarkdown = '';
  bool _summarizing = false;
  bool _exporting = false;
  bool _notFound = false;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    // 4 个 Tab：原文 / 详细笔记 / 思维导图 / 大纲
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        setState(() => _tabIndex = _tabController.index);
      }
    });
    _load();
  }

  /// 读取笔记，并尝试解析已有的总结。
  /// 找不到时明确置 _notFound，避免旧版那样永远转圈。
  Future<void> _load() async {
    final note = await _db.queryById(widget.noteId);
    if (!mounted) return;
    if (note == null) {
      setState(() => _notFound = true);
      return;
    }
    _transcriptController.text = note.transcript;
    // StudySummary.tryDecode 兼容三种历史形态：
    // ① 新格式（带 detail）；② 旧格式（只有 mindMap）；③ 坏数据（返回 null）
    final parsed = StudySummary.tryDecode(note.summaryJson);
    setState(() {
      _note = note;
      _mindMap = parsed?.mindMap;
      _graph = parsed?.graph;
      _activeBranch = null;
      _detailMarkdown = parsed?.detailMarkdown ?? '';
    });
  }

  /// 调用 AI 生成详细笔记（同时生成思维导图），结果写回数据库。
  /// 注意：总结用的是编辑框里的当前文本，所以必须把 transcript 一起存回去，
  /// 否则库里会出现「旧原文 + 基于新原文的总结」这种对不上的数据。
  Future<void> _generateSummary() async {
    if (_note == null || _summarizing) return;
    final currentTranscript = _transcriptController.text;
    setState(() => _summarizing = true);
    try {
      final result = await _ai.summarize(currentTranscript);
      final summaryJson = result.encode();
      final updated = _note!.copyWith(
        summaryJson: summaryJson,
        transcript: currentTranscript,
      );
      await _db.update(updated);

      if (!mounted) return;
      setState(() {
        _note = updated;
        _mindMap = result.mindMap;
        _graph = result.graph;
        _activeBranch = null;
        _detailMarkdown = result.detailMarkdown;
        _tabIndex = 1; // 跳到「详细笔记」，这是用户真正想看的东西
      });
      _tabController.animateTo(1);
      if (result.chunked) {
        _showSnack('课堂较长，已分块整理后再合并成完整笔记');
      }
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _summarizing = false);
    }
  }

  /// 保存用户手动修改后的原文
  Future<void> _saveTranscript() async {
    if (_note == null) return;
    final updated = _note!.copyWith(transcript: _transcriptController.text);
    await _db.update(updated);
    if (mounted) setState(() => _note = updated);
    _showSnack('原文已保存');
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _transcriptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    if (_notFound) {
      return Scaffold(
        appBar: AppBar(title: const Text('笔记详情')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.delete_sweep_outlined,
                    size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                const Text('这条笔记已经不在了'),
                const SizedBox(height: 8),
                Text('可能已在首页被删除',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('返回列表'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(note?.title ?? '笔记详情'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '原文'),
            Tab(text: '详细笔记'),
            Tab(text: '思维导图'),
            Tab(text: '大纲'),
          ],
        ),
      ),
      floatingActionButton: _summarizing
          ? null
          : FloatingActionButton.extended(
              onPressed: _generateSummary,
              icon: const Icon(Icons.auto_awesome),
              label: Text(_detailMarkdown.isEmpty ? '一键总结' : '重新总结'),
            ),
      // 关键：总结期间不再把整个 IndexedStack 换成 spinner。
      // 那样会清掉 Tab1 的编辑内容、Tab2/3 的滚动位置，用户每次总结都丢一次上下文。
      // 改成「保留页面 + 顶部线性进度 + 只读锁定」。
      body: note == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_summarizing)
                  const LinearProgressIndicator(minHeight: 3),
                if (_summarizing)
                  Container(
                    width: double.infinity,
                    color: Colors.indigo.shade50,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(
                      'AI 正在总结要点（约 10–30 秒，可用下方文字照常滚动查看）…',
                      style:
                          TextStyle(color: Colors.indigo.shade900, fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      _buildTranscriptTab(),
                      _buildDetailTab(),
                      _buildMindMapTab(),
                      _buildSummaryTab(),
                    ],
                  ),
                ),
                // PNG 导出需要 MindMapWidget 真实渲染，挂在这里的 Offstage 里
                _buildPngCaptureSource(),
              ],
            ),
    );
  }

  /// Tab 1：原文（可编辑 + 保存）
  Widget _buildTranscriptTab() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _transcriptController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              // 总结期间锁住编辑：避免「总结的是改到一半的文本」这种歧义
              readOnly: _summarizing,
              decoration: InputDecoration(
                hintText: '课堂原文，可直接修改',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _saveTranscript,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存原文'),
            ),
          ),
        ),
      ],
    );
  }

  /// Tab 2：文字版总结（要点列表）
  Widget _buildSummaryTab() {
    if (_mindMap == null) return _buildEmptyHint('还没有总结，点右下角「一键总结」生成');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_mindMap!.root,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ..._mindMap!.nodes.asMap().entries.map((entry) {
          final idx = entry.key + 1;
          final node = entry.value;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$idx. ${node.topic}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  ...node.children.map((c) => Padding(
                        padding: const EdgeInsets.only(left: 12, top: 2),
                        child: Text('• $c', style: const TextStyle(fontSize: 14, height: 1.5)),
                      )),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  /// Tab 2：详细笔记（九段式 Markdown，可复制/导出）
  Widget _buildDetailTab() {
    if (_detailMarkdown.isEmpty) {
      return _buildEmptyHint('还没有详细笔记，点右下角「一键总结」生成\n'
          '（会整理成知识点、例题、作业提示等九个部分）');
    }
    return Column(
      children: [
        Expanded(
          child: Scrollbar(
            controller: _detailScroll,
            child: SingleChildScrollView(
              controller: _detailScroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SelectableText(
                _detailMarkdown,
                style: const TextStyle(fontSize: 14.5, height: 1.65),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyDetail,
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: const Text('复制全文'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportDetailMarkdown,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('导出 .md'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 复制详细笔记全文（方便贴到自己的笔记软件里二次编辑）
  Future<void> _copyDetail() async {
    await Clipboard.setData(ClipboardData(text: _detailMarkdown));
    _showSnack('已复制全文');
  }

  /// 把详细笔记导出成 .md 文件并调起系统分享
  Future<void> _exportDetailMarkdown() async {
    if (_detailMarkdown.isEmpty || _exporting) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    try {
      final dir = await getTemporaryDirectory();
      final safeTitle =
          _note!.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/课堂笔记_$safeTitle.md');
      await file.writeAsString(_detailMarkdown);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/markdown')],
          text: '「${_note!.title}」详细课堂笔记',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _showSnack('导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Tab 3：思维导图（主图 + 子图）
  ///
  /// 交互：默认显示「主图」——课程主题 + 11 个一级分支；
  /// 点某个分支进入「子图」——该分支下 3–5 级的完整层级（可折叠）。
  /// 这样主图永远不拥挤，详细内容都在子图里。
  Widget _buildMindMapTab() {
    if (_graph == null || _graph!.branches.isEmpty) {
      return _buildEmptyHint('还没有思维导图，点右下角「一键总结」生成');
    }
    final graph = _graph!;
    final branch = _activeBranch;

    return Column(
      children: [
        // 子图时显示返回条
        if (branch != null)
          Container(
            width: double.infinity,
            color: Colors.indigo.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => _activeBranch = null),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('返回主图', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                Expanded(
                  child: Text(
                    branch.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.indigo.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: branch == null
              ? MindGraphOverview(
                  graph: graph,
                  onBranchTap: (b) => setState(() => _activeBranch = b),
                )
              : MindGraphSubtree(branch: branch),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : _showExportSheet,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share, size: 18),
                  label: const Text('导出导图'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : _exportMindMapPng,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('导出图片'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 选择导出格式（Markdown / Markmap / Mermaid / OPML / JSON）
  Future<void> _showExportSheet() async {
    final graph = _graph;
    if (graph == null) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Text('导出思维导图',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${graph.totalNodes} 节点 / ${graph.maxDepth} 级',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            ...MindGraphExporter.formats.map((f) => ListTile(
                  dense: true,
                  leading: Icon(_iconForFormat(f.key), size: 20),
                  title: Text(f.label, style: const TextStyle(fontSize: 14)),
                  subtitle: Text('.${f.ext}',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500)),
                  onTap: () => Navigator.pop(ctx, f.key),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _exportGraph(chosen);
  }

  static IconData _iconForFormat(String key) {
    switch (key) {
      case 'md':
        return Icons.article_outlined;
      case 'markmap':
        return Icons.language;
      case 'mermaid':
        return Icons.account_tree_outlined;
      case 'opml':
        return Icons.list_alt;
      case 'json':
        return Icons.data_object;
      default:
        return Icons.description_outlined;
    }
  }

  /// 把导图按指定格式落盘并调起系统分享
  Future<void> _exportGraph(String formatKey) async {
    final graph = _graph;
    if (graph == null || _exporting) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    try {
      final text = MindGraphExporter.render(graph, formatKey);
      final ext = MindGraphExporter.extOf(formatKey);
      final dir = await getTemporaryDirectory();
      final safeTitle =
          _note!.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/思维导图_$safeTitle.$ext');
      await file.writeAsString(text);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '「${_note!.title}」思维导图',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _showSnack('导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导出 PNG（用旧的 MindMapWidget 截长图，保留给需要图片的场景）
  Future<void> _exportMindMapPng() async {
    if (_mindMap == null || _exporting) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    try {
      final bytes = await MindMapWidget.exportPng(_captureKey);
      final dir = await getTemporaryDirectory();
      final safeTitle =
          _note!.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/导图_$safeTitle.png');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '「${_note!.title}」思维导图',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _showSnack('导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 隐藏的截图源：PNG 导出需要 MindMapWidget 真实渲染在树上，
  /// 放在 Offstage 里既不影响布局又保证 RepaintBoundary 可截图。
  Widget _buildPngCaptureSource() {
    if (_mindMap == null) return const SizedBox.shrink();
    return Offstage(
      offstage: true,
      child: SizedBox(
        width: 420,
        child: MindMapWidget(data: _mindMap!, captureKey: _captureKey),
      ),
    );
  }

  Widget _buildEmptyHint(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
