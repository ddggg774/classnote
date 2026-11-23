// lib/pages/textbook_excerpt_page.dart
// 教材摘录：给只有实体书的用户用的入口。
//
// 为什么不做「自动识别实体书」：
//   相机 + OCR 要加相机权限、图像预处理和一个视觉模型，属于独立一轮功能；
//   而这层真正需要的数据量很小——往往每章就那几句定义。先让用户把关键段落
//   抄/粘进来，质检的 evidence 立刻就有教材原文可用，不必等 OCR。
import 'package:material_ui/material_ui.dart';

import '../services/db_service.dart';

class TextbookExcerptPage extends StatefulWidget {
  const TextbookExcerptPage({super.key});

  @override
  State<TextbookExcerptPage> createState() => _TextbookExcerptPageState();
}

class _TextbookExcerptPageState extends State<TextbookExcerptPage> {
  final _db = DbService();
  final _courseCtrl = TextEditingController();
  final _chapterCtrl = TextEditingController();
  final _textCtrl = TextEditingController();

  List<Map<String, Object?>> _rows = const [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _courseCtrl.dispose();
    _chapterCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final course = _courseCtrl.text.trim();
    if (course.isEmpty) {
      setState(() {
        _rows = const [];
        _loading = false;
      });
      return;
    }
    final rows = await _db.listTextbookPassages(course);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final course = _courseCtrl.text.trim();
    final text = _textCtrl.text.trim();
    if (course.isEmpty) {
      _snack('先填课程名，例如「植物学」');
      return;
    }
    if (text.length < 10) {
      _snack('摘录太短，至少一句完整的话');
      return;
    }
    setState(() => _saving = true);
    try {
      await _db.addTextbookPassage(
        course: course,
        chapter: _chapterCtrl.text.trim(),
        text: text,
      );
      _textCtrl.clear();
      await _load();
      if (!mounted) return;
      _snack('已存入，下次质检会把它当依据');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条摘录？'),
        content: const Text('删除后，质检不再引用它。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _db.deleteTextbookPassage(id);
    await _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('教材摘录')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.indigo.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '只有实体书也能用：把关键的几句定义抄下来（或拍照后用系统识字粘贴进来），'
              '质检时会作为依据引用。不用整本录入，一章挑三五句最常考的即可。',
              style: TextStyle(
                  fontSize: 12.5, height: 1.5, color: Colors.indigo.shade900),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _courseCtrl,
            decoration: const InputDecoration(
              labelText: '课程',
              hintText: '植物学',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _load(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _chapterCtrl,
            decoration: const InputDecoration(
              labelText: '章节（可选）',
              hintText: '第四章 茎的变态',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _textCtrl,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '摘录原文',
              hintText: '把教材里的原句抄这里，一句一行也行',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(_saving ? '保存中…' : '保存摘录'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: _load,
                child: const Text('刷新列表'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text('已存摘录',
                  style:
                      TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text('${_rows.length} 条',
                  style:
                      TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('还没有摘录',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
            )
          else
            ..._rows.map((r) {
              final chapter = (r['chapter'] as String?) ?? '';
              final text = (r['text'] as String?) ?? '';
              final id = (r['id'] as String?) ?? '';
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text(
                    chapter.isEmpty ? '（未标章节）' : chapter,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  subtitle: Text(
                    text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _delete(id),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}