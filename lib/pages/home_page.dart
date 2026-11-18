// lib/pages/home_page.dart
// 首页：笔记列表。展示本地保存的所有课堂笔记，可新建、可删除。
import 'package:flutter/material.dart';

import '../models/note.dart';
import '../services/db_service.dart';
import 'record_page.dart';
import 'note_detail_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final DbService _db = DbService();
  List<Note> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  /// 从数据库刷新列表
  Future<void> _loadNotes() async {
    final notes = await _db.queryAll();
    if (mounted) {
      setState(() {
        _notes = notes;
        _loading = false;
      });
    }
  }

  /// 点击"新建课堂" -> 跳到记录页；返回后刷新列表
  Future<void> _goToRecord() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RecordPage()),
    );
    _loadNotes();
  }

  /// 删除笔记（带二次确认）
  Future<void> _deleteNote(Note note) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除「${note.title}」吗？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      await _db.delete(note.id);
      _loadNotes();
    }
  }

  @override
  Widget build(BuildContext context) {
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
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _notes.length,
                  itemBuilder: (context, index) => _buildNoteCard(_notes[index]),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _goToRecord,
        icon: const Icon(Icons.mic),
        label: const Text('新建课堂'),
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.menu_book_outlined, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text('还没有笔记', style: TextStyle(fontSize: 18, color: Colors.grey)),
          SizedBox(height: 8),
          Text('点右下角「新建课堂」开始记录吧', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildNoteCard(Note note) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: note.hasSummary ? Colors.teal.shade100 : Colors.indigo.shade100,
          child: Icon(
            note.hasSummary ? Icons.account_tree : Icons.description,
            color: note.hasSummary ? Colors.teal : Colors.indigo,
          ),
        ),
        title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_formatDate(note.createdAt)}  ·  ${_formatDuration(note.duration)}'
          '\n${note.transcript.replaceAll(RegExp(r'\s+'), ' ')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.grey),
          onPressed: () => _deleteNote(note),
        ),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
          );
          _loadNotes();
        },
      ),
    );
  }

  String _formatDate(DateTime dt) =>
      '${dt.month}月${dt.day}日 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}秒';
    return '${seconds ~/ 60}分${seconds % 60}秒';
  }
}
