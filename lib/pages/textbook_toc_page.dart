// lib/pages/textbook_toc_page.dart
// 教材目录：章 → 节的折叠列表 + 两种录入方式（粘贴解析 / 逐条手动）。
//
// 【界面必须说清数据可信度】
// 目录来源（手动 / 粘贴 / 未录入）常驻显示。用户看一眼就知道这份目录
// 是「自己敲的」还是「从官网粘的」，而不是程序猜的——这是这个功能
// 最重要的一条纪律的界面体现。

import 'package:material_ui/material_ui.dart';

import '../models/textbook.dart';
import '../services/textbook_service.dart';
import '../services/toc_parser.dart';
import '../services/toc_structurer.dart';

class TextbookTocPage extends StatefulWidget {
  const TextbookTocPage({super.key, required this.textbook});

  final Textbook textbook;

  @override
  State<TextbookTocPage> createState() => _TextbookTocPageState();
}

class _TextbookTocPageState extends State<TextbookTocPage> {
  final TextbookService _service = TextbookService();

  late Textbook _textbook;
  List<Chapter> _chapters = const [];
  final Map<String, List<Section>> _sections = {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _textbook = widget.textbook;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final chapters = await _service.chaptersOf(_textbook.id);
    _sections.clear();
    for (final c in chapters) {
      _sections[c.id] = await _service.sectionsOf(c.id);
    }
    final fresh = await _service.byId(_textbook.id);
    if (!mounted) return;
    setState(() {
      _chapters = chapters;
      if (fresh != null) _textbook = fresh;
      _loading = false;
    });
  }

  int get _sectionTotal =>
      _sections.values.fold(0, (sum, list) => sum + list.length);

  // ───────────────────── 保存入口 ─────────────────────

  /// 所有编辑都走「读全量 → 改内存 → 覆盖写回」。
  /// 比增量合并好推理，也不会出现「删了一章留下孤儿节」。
  Future<void> _apply(
    void Function(List<TocChapter> chapters) mutate, {
    String source = Textbook.tocManual,
    String? successMessage,
  }) async {
    setState(() => _busy = true);
    try {
      final toc = await _service.tocOf(_textbook.id);
      final chapters = List<TocChapter>.from(toc.chapters);
      mutate(chapters);
      await _service.saveToc(
        _textbook.id,
        TocData(chapters: chapters),
        source: source,
      );
      await _load();
      if (successMessage != null && mounted) _showSnack(successMessage);
    } catch (e) {
      if (mounted) _showSnack('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ───────────────────── 粘贴解析 ─────────────────────

  Future<void> _pasteToc() async {
    final ctrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴目录'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            maxLines: 10,
            minLines: 6,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '第五章 被子植物\n  第一节 木兰科\n  第二节 蔷薇科\n'
                  '第六章 单子叶植物\n  第一节 禾本科',
              helperText: '从电子版目录、豆瓣读书或出版社官网复制过来即可',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('解析'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (raw == null || !mounted) return;
    if (raw.trim().isEmpty) {
      _showSnack('目录内容是空的');
      return;
    }
    await _previewAndImport(raw);
  }

  /// 预览 → 确认导入。正则结果为空时，才提供「用模型再整理」。
  /// 模型不是默认路径：它要花钱，而且必须过行级校验才敢用。
  Future<void> _previewAndImport(String raw) async {
    var current = TocParser.parse(raw);
    while (true) {
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(current.isEmpty ? '没有识别出章节' : '确认导入目录'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (current.isEmpty)
                  Text(
                    '这段文字里没有「第X章 / 第X节」这类结构。\n'
                    '可以改用手动录入，或者让模型帮忙重排一次。',
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade700, height: 1.5),
                  )
                else ...[
                  Text(
                    '${current.chapterCount} 章 · ${current.sectionCount} 节',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  ...current.chapters.take(8).map((c) => Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '${c.displayName}'
                          '${c.sections.isEmpty ? '' : '（${c.sections.length} 节）'}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      )),
                  if (current.chapters.length > 8)
                    Text('…… 还有 ${current.chapters.length - 8} 章',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                ],
                if (current.droppedLines.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '丢弃了 ${current.droppedLines.length} 行'
                          '（原文里找不到对应的章/节结构，不会写进目录）',
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade900),
                        ),
                        const SizedBox(height: 4),
                        ...current.droppedLines.take(3).map((l) => Text(
                              '· $l',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange.shade800),
                            )),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('取消'),
            ),
            if (current.isEmpty)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'model'),
                child: const Text('用模型再整理'),
              ),
            if (!current.isEmpty)
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'import'),
                child: const Text('导入'),
              ),
          ],
        ),
      );

      if (action == null || action == 'cancel') return;

      if (action == 'import') {
        setState(() => _busy = true);
        try {
          await _service.saveToc(
            _textbook.id,
            current,
            source: Textbook.tocPasted,
          );
          await _load();
          if (mounted) {
            _showSnack(
                '已导入 ${current.chapterCount} 章 ${current.sectionCount} 节');
          }
        } catch (e) {
          if (mounted) _showSnack('导入失败：$e');
        } finally {
          if (mounted) setState(() => _busy = false);
        }
        return;
      }

      if (action == 'model') {
        setState(() => _busy = true);
        try {
          final result = await TocStructurer().structure(rawText: raw);
          if (result == null || result.isEmpty) {
            if (mounted) {
              _showSnack('模型没有整理出可用的章节，已保留正则结果（空）');
            }
            return;
          }
          current = result;
        } catch (e) {
          if (mounted) {
            _showSnack(e.toString().replaceFirst('Exception: ', ''));
          }
          return;
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    }
  }

  // ───────────────────── 手动录入 ─────────────────────

  Future<void> _addChapter() async {
    final result = await _askNode(
      title: '添加一章',
      noLabel: '章号',
      noHint: '例如：第五章',
      titleLabel: '章名',
      titleHint: '例如：被子植物',
    );
    if (result == null) return;
    await _apply(
      (chapters) => chapters.add(TocChapter(
        no: result.no,
        title: result.title,
      )),
      successMessage: '已添加：${result.no} ${result.title}',
    );
  }

  Future<void> _addSection(int chapterIndex) async {
    if (chapterIndex >= _chapters.length) return;
    final chapter = _chapters[chapterIndex];
    final result = await _askNode(
      title: '添加一节',
      noLabel: '节号',
      noHint: '例如：第二节',
      titleLabel: '节名',
      titleHint: '例如：木兰科',
      parent: chapter.displayName,
    );
    if (result == null) return;
    await _apply(
      (chapters) {
        if (chapterIndex >= chapters.length) return;
        final c = chapters[chapterIndex];
        chapters[chapterIndex] = TocChapter(
          no: c.no,
          title: c.title,
          sections: [
            ...c.sections,
            TocSection(no: result.no, title: result.title),
          ],
        );
      },
      successMessage: '已添加：${result.no} ${result.title}',
    );
  }

  Future<void> _deleteChapter(int chapterIndex) async {
    if (chapterIndex >= _chapters.length) return;
    final chapter = _chapters[chapterIndex];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一章'),
        content: Text('删除「${chapter.displayName}」'
            '${chapter.no.isEmpty ? '' : '及它下面的节'}？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _apply(
      (chapters) {
        if (chapterIndex < chapters.length) chapters.removeAt(chapterIndex);
      },
      successMessage: '已删除「${chapter.displayName}」',
    );
  }

  Future<void> _deleteSection(int chapterIndex, int sectionIndex) async {
    if (chapterIndex >= _chapters.length) return;
    final chapter = _chapters[chapterIndex];
    final sections = _sections[chapter.id] ?? const [];
    if (sectionIndex >= sections.length) return;
    final section = sections[sectionIndex];
    await _apply(
      (chapters) {
        if (chapterIndex >= chapters.length) return;
        final c = chapters[chapterIndex];
        final list = List<TocSection>.from(c.sections);
        if (sectionIndex < list.length) list.removeAt(sectionIndex);
        chapters[chapterIndex] = TocChapter(
          no: c.no,
          title: c.title,
          sections: list,
        );
      },
      successMessage: '已删除「${section.displayName}」',
    );
  }

  Future<void> _clearToc() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空目录'),
        content: Text('清空这本教材已录入的 ${_chapters.length} 章目录？'
            '已经记下的笔记不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _service.clearToc(_textbook.id);
      await _load();
    } catch (e) {
      if (mounted) _showSnack('清空失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 章号 / 章名的输入对话框。节号允许留空（「附录」这类节点本来没有号）。
  Future<({String no, String title})?> _askNode({
    required String title,
    required String noLabel,
    required String noHint,
    required String titleLabel,
    required String titleHint,
    String? parent,
  }) async {
    final noCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final result = await showDialog<({String no, String title})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parent != null) ...[
              Text('属于：$parent',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: noCtrl,
              decoration: InputDecoration(
                labelText: '$noLabel（可留空）',
                hintText: noHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: titleCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: titleLabel,
                hintText: titleHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              (no: noCtrl.text.trim(), title: titleCtrl.text.trim()),
            ),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      noCtrl.dispose();
      titleCtrl.dispose();
    });
    if (result == null) return null;
    if (result.title.isEmpty) {
      _showSnack('$titleLabel不能为空');
      return null;
    }
    return result;
  }

  // ───────────────────── 界面 ─────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_textbook.displayTitle, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (v) {
              switch (v) {
                case 'paste':
                  _pasteToc();
                  break;
                case 'chapter':
                  _addChapter();
                  break;
                case 'clear':
                  _clearToc();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'paste', child: Text('粘贴目录文本')),
              PopupMenuItem(value: 'chapter', child: Text('手动添加一章')),
              PopupMenuItem(value: 'clear', child: Text('清空目录')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          _buildHeader(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _chapters.isEmpty
                    ? _buildEmpty()
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: _chapters.length,
                        itemBuilder: (_, i) => _buildChapterTile(i),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final (MaterialColor color, String text) = switch (_textbook.tocSource) {
      Textbook.tocManual => (Colors.indigo, '手动录入'),
      Textbook.tocPasted => (Colors.teal, '粘贴导入'),
      _ => (Colors.orange, '未录入目录'),
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(text,
                    style: TextStyle(fontSize: 11, color: color.shade700)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _chapters.isEmpty
                      ? '还没有目录'
                      : '${_chapters.length} 章 · $_sectionTotal 节',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '目录只来自你的录入或粘贴——章节号绝不会由程序生成。',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined,
                size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('还没有录入目录',
                style: TextStyle(fontSize: 15, color: Colors.grey.shade700)),
            const SizedBox(height: 6),
            Text(
              '录入之后，录音前就能直接选到「第五章 · 第二节」这种粒度，'
              '术语表和总结都会用上它。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _pasteToc,
              icon: const Icon(Icons.content_paste),
              label: const Text('粘贴目录文本'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _addChapter,
              icon: const Icon(Icons.add),
              label: const Text('手动添加一章'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChapterTile(int index) {
    final chapter = _chapters[index];
    final sections = _sections[chapter.id] ?? const <Section>[];
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: index == 0 && _chapters.length <= 3,
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: Colors.indigo.shade50,
          child: Text(
            '${index + 1}',
            style: TextStyle(fontSize: 12, color: Colors.indigo.shade700),
          ),
        ),
        title: Text(chapter.displayName,
            style: const TextStyle(fontSize: 14.5)),
        subtitle: Text(
          sections.isEmpty ? '没有节（可以直接选到这一章）' : '${sections.length} 节',
          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
        ),
        trailing: PopupMenuButton<String>(
          enabled: !_busy,
          onSelected: (v) {
            if (v == 'add') _addSection(index);
            if (v == 'delete') _deleteChapter(index);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'add', child: Text('在这一章加一节')),
            PopupMenuItem(value: 'delete', child: Text('删除这一章')),
          ],
        ),
        children: [
          for (var j = 0; j < sections.length; j++)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 44, right: 4),
              title: Text(sections[j].displayName,
                  style: const TextStyle(fontSize: 13.5)),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: '删除这一节',
                onPressed: _busy ? null : () => _deleteSection(index, j),
              ),
            ),
          if (sections.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '这本教材的目录只到章一级',
                  style:
                      TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}