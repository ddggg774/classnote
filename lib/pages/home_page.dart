// lib/pages/home_page.dart
// 首页：笔记列表。展示本地保存的所有课堂笔记，可新建、可删除。
// 顶部会把「未完成的草稿」单独提出来，方便崩溃/误退后继续记录。
import 'package:material_ui/material_ui.dart';

import '../models/note.dart';
import '../services/db_service.dart';
import 'record_page.dart';
import 'note_detail_page.dart';
import 'settings_page.dart';

/// 列表项用的轻量模型：只带列表要显示的字段 + 预计算好的摘要。
/// 不直接复用 Note，原因是两小时课堂的正文有三四万字，
/// 在 build 里对每条笔记做 replaceAll 正则会明显掉帧。
class _NoteItem {
  final Note note;
  final String preview;

  _NoteItem(this.note) : preview = _makePreview(note.transcript);

  static String _makePreview(String transcript) {
    // 只截前 120 字再压缩空白，正则的处理量从「整篇」降到「120 字」
    final head = transcript.length > 120 ? transcript.substring(0, 120) : transcript;
    return head.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final DbService _db = DbService();
  List<_NoteItem> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  /// 从数据库刷新列表
  Future<void> _loadNotes() async {
    // 启动时顺手清理一天前的空白草稿（用户点进录音页又立刻退出留下的）
    try {
      await _db.purgeEmptyDrafts();
    } catch (_) {}
    final notes = await _db.queryAll();
    if (!mounted) return;
    setState(() {
      _notes = notes.map((n) => _NoteItem(n)).toList();
      _loading = false;
    });
  }

  /// 点击"新建课堂" -> 跳到记录页；返回后刷新列表
  Future<void> _goToRecord() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RecordPage()),
    );
    await _loadNotes();
  }

  /// 继续编辑一条草稿
  Future<void> _continueDraft(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RecordPage(draftId: id)),
    );
    await _loadNotes();
  }

  /// 删除笔记（带二次确认）
  Future<void> _deleteNote(Note note) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除「${note.title}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      await _db.delete(note.id);
      await _loadNotes();
    }
  }

  @override
  Widget build(BuildContext context) {
    final drafts = _notes.where((i) => i.note.isDraft).toList();
    final done = _notes.where((i) => !i.note.isDraft).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的课堂笔记'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? _buildEmpty()
              : RefreshIndicator(
                  onRefresh: _loadNotes,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (drafts.isNotEmpty) ...[
                        _buildSectionTitle('未完成（可继续记录）', drafts.length),
                        ...drafts.map((i) => _buildNoteCard(i, isDraft: true)),
                        const SizedBox(height: 8),
                        if (done.isNotEmpty)
                          _buildSectionTitle('已完成笔记', done.length),
                      ],
                      ...done.map((i) => _buildNoteCard(i, isDraft: false)),
                    ],
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _goToRecord,
        icon: const Icon(Icons.mic),
        label: const Text('新建课堂'),
      ),
    );
  }

  Widget _buildSectionTitle(String text, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          Text(text,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700)),
          const SizedBox(width: 6),
          Text('$count',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.menu_book_outlined, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text('还没有笔记', style: TextStyle(fontSize: 18, color: Colors.grey)),
          SizedBox(height: 8),
          Text('点右下角「新建课堂」开始记录吧',
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildNoteCard(_NoteItem item, {required bool isDraft}) {
    final note = item.note;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isDraft
              ? Colors.orange.shade100
              : note.hasSummary
                  ? Colors.teal.shade100
                  : Colors.indigo.shade100,
          child: Icon(
            isDraft
                ? Icons.play_circle_outline
                : note.hasSummary
                    ? Icons.account_tree
                    : Icons.description,
            color: isDraft
                ? Colors.orange.shade800
                : note.hasSummary
                    ? Colors.teal
                    : Colors.indigo,
          ),
        ),
        title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          isDraft
              ? '${_formatDate(note.createdAt)}  ·  已录 ${_formatDuration(note.duration)}'
                  '  ·  ${item.preview.isEmpty ? '（还没有文字）' : item.preview}'
              : '${_formatDate(note.createdAt)}  ·  ${_formatDuration(note.duration)}'
                  '\n${item.preview}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.grey),
          onPressed: () => _deleteNote(note),
        ),
        onTap: () async {
          if (isDraft) {
            await _continueDraft(note.id);
          } else {
            await Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => NoteDetailPage(noteId: note.id)),
            );
            await _loadNotes();
          }
        },
      ),
    );
  }

  String _formatDate(DateTime dt) =>
      '${dt.month}月${dt.day}日 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds秒';
    return '${seconds ~/ 60}分${seconds % 60}秒';
  }
}
