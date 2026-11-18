// lib/pages/note_detail_page.dart
// 笔记详情页：三个 Tab —— 原文（可编辑）、AI 总结、思维导图。
// "生成总结"按钮调用 AI 服务，把结果存回数据库并渲染导图。
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/note.dart';
import '../services/db_service.dart';
import '../services/ai_service.dart';
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
  Note? _note;
  MindMapData? _mindMap;
  bool _summarizing = false;
  bool _exporting = false;
  bool _notFound = false;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
    MindMapData? parsed;
    if (note.hasSummary) {
      try {
        parsed = MindMapData.fromJson(jsonDecode(note.summaryJson!));
      } catch (_) {
        // 总结 JSON 损坏（版本升级/写入中断）时降级为「无总结」，不影响看原文
        parsed = null;
      }
    }
    setState(() {
      _note = note;
      _mindMap = parsed;
    });
  }

  /// 调用 AI 生成总结（同时生成思维导图），结果写回数据库。
  /// 注意：总结用的是编辑框里的当前文本，所以必须把 transcript 一起存回去，
  /// 否则库里会出现「旧原文 + 基于新原文的总结」这种对不上的数据。
  Future<void> _generateSummary() async {
    if (_note == null || _summarizing) return;
    final currentTranscript = _transcriptController.text;
    setState(() => _summarizing = true);
    try {
      final data = await _ai.summarize(currentTranscript);
      final summaryJson = jsonEncode(data.toJson());
      final updated = _note!.copyWith(
        summaryJson: summaryJson,
        transcript: currentTranscript,
      );
      await _db.update(updated);

      if (!mounted) return;
      setState(() {
        _note = updated;
        _mindMap = data;
        _tabIndex = 2; // 跳到思维导图 Tab
      });
      _tabController.animateTo(2);
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _summarizing = false);
    }
  }

  /// 导出思维导图为 PNG 图片，并通过系统分享面板保存/发送
  Future<void> _exportMindMap() async {
    if (_mindMap == null || _exporting) return;
    // 提前取好分享面板的弹出位置：后面有 await，之后再读 context 会踩
    // use_build_context_synchronously，而且在页面已销毁时会拿到无效对象。
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    try {
      final bytes = await MindMapWidget.exportPng(_captureKey);
      final dir = await getTemporaryDirectory();
      final safeTitle = _note!.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/导图_$safeTitle.png');
      await file.writeAsBytes(bytes);

      // iPad 上分享面板必须给出弹出位置，否则 share_plus 会抛异常
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
          tabs: const [
            Tab(text: '原文'),
            Tab(text: '总结'),
            Tab(text: '思维导图'),
          ],
        ),
      ),
      floatingActionButton: _summarizing
          ? null
          : FloatingActionButton.extended(
              onPressed: _generateSummary,
              icon: const Icon(Icons.auto_awesome),
              label: Text(_mindMap == null ? '一键总结' : '重新总结'),
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
                      _buildSummaryTab(),
                      _buildMindMapTab(),
                    ],
                  ),
                ),
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

  /// Tab 3：思维导图
  Widget _buildMindMapTab() {
    if (_mindMap == null) return _buildEmptyHint('还没有思维导图，点右下角「一键总结」生成');
    return Column(
      children: [
        Expanded(
          child: MindMapWidget(data: _mindMap!, captureKey: _captureKey),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton.icon(
              onPressed: _exporting ? null : _exportMindMap,
              icon: _exporting
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share),
              label: const Text('导出图片'),
            ),
          ),
        ),
      ],
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
