// lib/pages/textbook_list_page.dart
// 教材管理入口：按课程分组列出所有教材，点进去录目录。
//
// 教材列表来自数据库（textbooks 表）。首次建库时会把 config.dart 里
// 那三本灌成种子，之后完全由用户维护——程序不再猜教材。

import 'package:material_ui/material_ui.dart';

import '../models/textbook.dart';
import '../services/textbook_service.dart';
import 'textbook_edit_page.dart';
import 'textbook_toc_page.dart';

class TextbookListPage extends StatefulWidget {
  const TextbookListPage({super.key});

  @override
  State<TextbookListPage> createState() => _TextbookListPageState();
}

class _TextbookListPageState extends State<TextbookListPage> {
  final TextbookService _service = TextbookService();

  List<Textbook> _textbooks = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _service.listAll();
    if (!mounted) return;
    setState(() {
      _textbooks = list;
      _loading = false;
    });
  }

  Map<String, List<Textbook>> get _groups {
    final out = <String, List<Textbook>>{};
    for (final t in _textbooks) {
      out.putIfAbsent(t.course, () => []).add(t);
    }
    return out;
  }

  Future<void> _openToc(Textbook textbook) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TextbookTocPage(textbook: textbook)),
    );
    await _load();
  }

  Future<void> _edit([Textbook? textbook]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => TextbookEditPage(textbook: textbook)),
    );
    if (changed == true) await _load();
  }

  Future<void> _delete(Textbook textbook) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除教材'),
        content: Text('删除「${textbook.displayTitle}」及其目录？\n'
            '已记下的笔记不受影响。'),
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
    await _service.delete(textbook.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(
        title: const Text('教材管理'),
        actions: [
          IconButton(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
            tooltip: '新建教材',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _textbooks.isEmpty
              ? _buildEmpty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      _buildNotice(),
                      for (final entry in groups.entries) ...[
                        _buildGroupHeader(entry.key, entry.value.length),
                        for (final t in entry.value) _buildTextbookTile(t),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _buildNotice() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '教材目录靠你录入或粘贴，程序不会自动生成章节号——'
        '编错一个「第五章」会一路污染术语表和总结。',
        style: TextStyle(
            fontSize: 11.5, color: Colors.blueGrey.shade700, height: 1.5),
      ),
    );
  }

  Widget _buildGroupHeader(String course, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(
        children: [
          Icon(Icons.school_outlined, size: 16, color: Colors.indigo.shade400),
          const SizedBox(width: 6),
          Text(course,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Text('$count 本',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _buildTextbookTile(Textbook t) {
    final publishedLine =
        [t.author.trim(), t.publisher.trim()].where((s) => s.isNotEmpty).join(' · ');
    final tocColor =
        t.hasToc ? Colors.teal.shade700 : Colors.orange.shade800;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(Icons.menu_book_outlined, color: Colors.indigo.shade300),
        title: Text(t.displayTitle, style: const TextStyle(fontSize: 14.5)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (publishedLine.isNotEmpty)
              Text(publishedLine,
                  style:
                      TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 2),
            Text(
              '目录：${t.tocSourceLabel}',
              style: TextStyle(fontSize: 11.5, color: tocColor),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'toc') _openToc(t);
            if (v == 'edit') _edit(t);
            if (v == 'delete') _delete(t);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'toc', child: Text('录入 / 查看目录')),
            PopupMenuItem(value: 'edit', child: Text('编辑教材信息')),
            PopupMenuItem(value: 'delete', child: Text('删除教材')),
          ],
        ),
        onTap: () => _openToc(t),
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
            Icon(Icons.library_books_outlined,
                size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('还没有教材',
                style: TextStyle(fontSize: 15, color: Colors.grey.shade700)),
            const SizedBox(height: 6),
            Text('新建一本，然后把目录粘进去。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('新建教材'),
            ),
          ],
        ),
      ),
    );
  }
}